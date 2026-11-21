# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationsLive do
  use MondekWeb, :live_view
  alias Mondek.{Monitoring, NotificationFilters}

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    NotificationDetail,
    NotificationNavigation,
    PreviewFilters,
    PreviewLayouts,
    ScalarFilterPicker
  }

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       filters: NotificationFilters.params(%{}),
       filter_picker: nil,
       now: Monitoring.now(),
       page_title: "Notifications"
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    local = URI.parse(uri)
    return_to = BrowserNavigation.return_path(params["return_to"])

    origin_filters =
      if return_to && URI.parse(return_to).path == "/notifications",
        do: URI.decode_query(URI.parse(return_to).query || ""),
        else: %{}

    filters = NotificationFilters.params(Map.merge(origin_filters, params))

    identity =
      case Ecto.UUID.cast(params["id"]) do
        {:ok, id} -> {"notification", id}
        _ -> nil
      end

    direct_full = String.ends_with?(local.path, "/full")
    initial = if direct_full, do: [], else: List.wrap(identity)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       return_to: return_to,
       back:
         if(params["id"] && return_to, do: return_to, else: NotificationNavigation.path(filters)),
       filter_picker: if(filters == socket.assigns.filters, do: socket.assigns.filter_picker),
       raw_params: params,
       host: local.path <> if(local.query, do: "?" <> local.query, else: ""),
       initial_trail: initial,
       investigation_root: if(direct_full, do: identity),
       full_page:
         (direct_full && !is_nil(identity)) ||
           !is_nil(InvestigationTrail.promoted(params, initial)),
       selection: InvestigationTrail.selection(params, initial),
       invalid_identity: params["id"] && is_nil(identity)
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("search", %{"search" => value}, socket),
    do: patch_filters(socket, %{"search" => ScalarFilterPicker.text(value)})

  def handle_event("filter_open", %{"field" => field}, socket) do
    case picker(field, "") do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply,
         assign(socket,
           filter_picker: %{
             draft
             | value:
                 if(socket.assigns.filters[field],
                   do:
                     ScalarFilterPicker.label(
                       NotificationFilters.choices(field),
                       socket.assigns.filters[field]
                     ),
                   else: ""
                 )
           }
         )}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket), do: {:noreply, ready(socket)}
  def handle_event("filter_close", _, socket), do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do:
        patch_filters(ready(socket), %{
          field => if(field == "notification_status", do: "all", else: "")
        })

  def handle_event("filter_remove", %{"field" => field}, socket) do
    if field == "search" || List.keymember?(NotificationFilters.fields(), field, 0),
      do:
        patch_filters(ready(socket), %{
          field => if(field == "notification_status", do: "all", else: "")
        }),
      else: {:noreply, socket}
  end

  def handle_event(
        event,
        %{"search" => value},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ["filter_query", "filter_first"] do
    draft = picker(field, value)

    case {event, draft.options} do
      {"filter_first", [option | _]} -> patch_filters(ready(socket), %{field => option.key})
      _ -> {:noreply, assign(socket, filter_picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_filters(ready(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp picker(field, value),
    do:
      ScalarFilterPicker.draft(
        NotificationFilters.fields(),
        &NotificationFilters.choices/1,
        field,
        value
      )

  defp ready(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp patch_filters(socket, changes) do
    current = socket.assigns.filters
    proposed = current |> Map.merge(changes) |> NotificationFilters.params()

    if Map.drop(proposed, ["notification_page"]) == Map.drop(current, ["notification_page"]) do
      {:noreply, socket}
    else
      filters = Map.delete(proposed, "notification_page")
      {:noreply, push_patch(socket, to: NotificationNavigation.path(filters))}
    end
  end

  defp refresh(socket) do
    now = Monitoring.now()
    snapshot = Monitoring.delivery_inspection(socket.assigns.filters, now)

    assign(socket,
      now: now,
      snapshot: snapshot,
      page: snapshot["notification_page"],
      fields: NotificationFilters.fields(),
      chips:
        ScalarFilterPicker.chips(
          NotificationFilters.fields(),
          socket.assigns.filters,
          &NotificationFilters.choices/1
        )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="notifications-shell"
      phx-hook="OverviewPanel"
      data-selection={@selection}
      data-panel-heading={
        InvestigationTrail.heading(
          @raw_params,
          if(@investigation_root, do: "notification-heading", else: "notifications-heading"),
          @initial_trail
        )
      }
    >
      <PreviewLayouts.navigation active={:notifications} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section :if={!@full_page} class="preview-list" aria-labelledby="notifications-heading">
          <header class="preview-heading">
            <h1 id="notifications-heading" class="pf-v6-c-title pf-m-2xl">Notifications</h1><span class="pf-v6-c-badge pf-m-read">{@snapshot[
              "notification_backlog"
            ]["total"] || 0} outstanding</span>
          </header>
          <p :if={@snapshot["delivery_enabled"] == false} id="notification-delivery-off">
            Notification delivery is off for this installation.
          </p>
          <div class="notification-matching-count preview-caption">
            {@page["total"]} matching notifications
          </div>
          <p class="notification-list-note">
            {ordering(@filters)} Receiver acceptance confirms transport; it does not prove a person read the message.
          </p>
          <div class="notification-filter-toolbar">
            <PreviewFilters.filter_picker
              picker={@filter_picker}
              chips={@chips}
              fields={@fields}
              search={@filters["search"]}
              remove={
                fn field ->
                  NotificationNavigation.path(
                    @filters
                    |> Map.put(field, if(field == "notification_status", do: "all", else: ""))
                    |> Map.delete("notification_page")
                  )
                end
              }
              clear_search={
                NotificationNavigation.path(
                  @filters
                  |> Map.delete("search")
                  |> Map.delete("notification_page")
                )
              }
              form_label="Filter notifications"
              label="Search notifications"
              placeholder="Search or filter notifications"
            />
          </div>
          <section class="preview-table-group" aria-label="Notification delivery list">
            <p :if={@snapshot["occurrences"] == []} id="notification-empty" class="preview-empty">
              No notifications match these filters.
            </p>
            <table
              :if={@snapshot["occurrences"] != []}
              class="pf-v6-c-table pf-m-compact preview-table notification-table"
              aria-label="Notifications"
            >
              <thead class="pf-v6-c-table__thead">
                <tr>
                  <th class="pf-v6-c-table__th" scope="col">Status</th><th
                    class="pf-v6-c-table__th"
                    scope="col"
                  >
                    Notification
                  </th><th class="pf-v6-c-table__th" scope="col">Event</th><th
                    class="pf-v6-c-table__th"
                    scope="col"
                  >
                    Channel
                  </th><th class="pf-v6-c-table__th" scope="col">Attempts</th><th
                    class="pf-v6-c-table__th"
                    scope="col"
                  >
                    Created
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={notice <- @snapshot["occurrences"]}
                  id={"notification-row-" <> notice["id"]}
                  data-overview-row
                >
                  <td class="pf-v6-c-table__td" data-label="Status">
                    <NotificationDetail.status value={notice["status"]} /><span
                      :if={notice["waiting_on_gates"]}
                      class="preview-caption notification-secondary"
                    >{MondekWeb.NotificationComponents.notification_gate_summary(notice)}</span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Notification">
                    <.link
                      patch={open_path(@host, notice["id"])}
                      class="preview-result-link"
                      data-overview-open
                    >{NotificationDetail.title(notice)}</.link><span class="preview-caption notification-secondary">{if notice[
                                                                                                                          "monitoring_incident_id"
                                                                                                                        ],
                                                                                                                        do:
                                                                                                                          "Monitoring loss",
                                                                                                                        else:
                                                                                                                          "Health incident"}<span :if={
                      get_in(notice, ["payload", "environment"])
                    }> · {get_in(notice, ["payload", "environment"])}</span></span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Event">
                    {NotificationDetail.event(notice["kind"])}
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Channel">
                    {if String.starts_with?(notice["destination"] || "", "mailto:"),
                      do: "Email",
                      else: "Webhook"}
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Attempts">
                    {notice["attempt_count"] || 0}
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Created">
                    <time
                      datetime={notice["inserted_at"]}
                      title={MondekWeb.EvidencePresentation.time(notice["inserted_at"])}
                    >{MondekWeb.EvidencePresentation.age(notice["inserted_at"], @now)}</time>
                  </td>
                </tr>
              </tbody>
            </table>
            <MondekWeb.PreviewPagination.pagination
              page={@page["page"]}
              size={@page["page_size"]}
              total={@page["total"]}
              label="Notification pages"
              url={
                fn page ->
                  NotificationNavigation.path(Map.put(@filters, "notification_page", page))
                end
              }
            />
          </section>
        </section>
        <section :if={@invalid_identity} class="preview-list">
          <header class="preview-heading">
            <h1 class="pf-v6-c-title pf-m-2xl">Notification not found</h1>
          </header><p class="preview-empty">This notification is not in retained history.</p>
        </section>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@host}
          params={@raw_params}
          now={@now}
          root={@investigation_root}
          initial={@initial_trail}
          context="notifications"
          back={@back}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp ordering(%{"notification_status" => status}) when status in ~w(all delivered superseded),
    do: "Newest first."

  defp ordering(_), do: "Exhausted retries first, then retrying and queued work. Oldest first."

  defp open_path(host, id) do
    trail = InvestigationTrail.resolve(URI.decode_query(URI.parse(host).query || ""))

    case InvestigationTrail.open(trail, {"notification", id}) do
      {:ok, next} ->
        InvestigationTrail.path(
          host,
          if(List.last(trail) == {"notification", id}, do: Enum.drop(trail, -1), else: next)
        )

      _ ->
        host
    end
  end
end

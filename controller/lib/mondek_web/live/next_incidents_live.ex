# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextIncidentsLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias Mondek.{Maintenance, Monitoring, MonitoringLoss}
  alias MondekWeb.{NotificationRetry, PreviewIncidentSections}

  @types [{"all", "All types"}, {"health", "Health failure"}, {"loss", "Monitoring loss"}]
  @groupings [
    {"top", "Top-level incidents"},
    {"all", "Any grouping"},
    {"shared", "Shared incidents"},
    {"standalone", "Standalone health incidents"},
    {"member", "Members of shared incidents"}
  ]
  @statuses [{"open", "Open"}, {"closed", "Closed"}, {"all", "Any status"}]
  @severities [
    {"all", "Any severity"},
    {"CRIT", "Critical"},
    {"WARN", "Warning"},
    {"UNKNOWN", "Unknown"}
  ]
  @acknowledgements [
    {"all", "Any acknowledgement"},
    {"unacknowledged", "Unacknowledged"},
    {"acknowledged", "Acknowledged"}
  ]
  @opened [
    {"all", "Any time"},
    {"24h", "Last 24 hours"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"}
  ]
  @delivery_statuses [
    {"all", "All notifications"},
    {"unresolved", "Unresolved"},
    {"pending", "Pending"},
    {"retrying", "Retrying"},
    {"delivering", "Delivering"},
    {"exhausted", "Exhausted"},
    {"delivered", "Delivered"},
    {"superseded", "Superseded"}
  ]
  @filter_fields [
    {"grouping", "Grouping", "server"},
    {"status", "Status", "info"},
    {"type", "Type", "grid"},
    {"severity", "Severity", "pulse"},
    {"acknowledgement", "Acknowledgement", "shield"},
    {"opened", "Opened", "clock"}
  ]

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)
    {:ok, assign(socket, page_title: "Incidents preview")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      if socket.assigns[:id] != params["id"] || !Map.has_key?(socket.assigns, :control_review) do
        assign(socket,
          control_review: nil,
          control_draft: %{},
          control_replacing: false,
          control_feedback: nil,
          delivery_feedback: nil,
          retry_drafts: %{}
        )
      else
        socket
      end

    {:noreply,
     socket
     |> assign(
       filters: filters(params),
       filter_picker: nil,
       id: params["id"],
       full_page: String.ends_with?(URI.parse(uri).path, "/full"),
       detail_filters: detail_filters(params)
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event(
        "filter_incident_detail",
        %{"notification_status" => value},
        %{assigns: %{incident: %{}, kind: kind, id: id}} = socket
      ) do
    query =
      socket.assigns.filters
      |> Map.merge(socket.assigns.detail_filters)
      |> Map.merge(%{
        "notification_status" => choice(value, @delivery_statuses),
        "notification_page" => "1"
      })

    {:noreply, push_patch(socket, to: path(kind, id, query, socket.assigns.full_page))}
  end

  def handle_event("search", %{"search" => search}, socket) do
    patch_filters(socket, %{"search" => search})
  end

  def handle_event("filter_open", %{"field" => field}, socket)
      when field in ["type", "status", "severity", "acknowledgement", "opened", "grouping"] do
    value = socket.assigns.filters[field]
    label = if value == "all", do: "", else: option_label(field, value)
    {:noreply, assign(socket, filter_picker: %{picker(field, "") | value: label})}
  end

  def handle_event("filter_close", %{"reopen" => true}, socket),
    do: {:noreply, filter_ready(socket)}

  def handle_event("filter_close", _, socket),
    do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do: patch_filters(filter_ready(socket), %{field => "all"})

  def handle_event(
        event,
        %{"search" => search},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ["filter_query", "filter_first"] and is_binary(search) do
    draft = picker(field, search)

    case {event, draft.options} do
      {"filter_first", [option | _]} ->
        patch_filters(filter_ready(socket), %{field => option.key})

      _ ->
        {:noreply, assign(socket, filter_picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_filters(filter_ready(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(
        "review_control",
        _,
        %{assigns: %{incident: %{"status" => "open"} = incident}} = socket
      ) do
    {:noreply,
     assign(socket, control_review: acknowledgement_revision(incident), control_feedback: nil)}
  end

  def handle_event(
        "toggle_acknowledgement_replacement",
        _,
        %{assigns: %{incident: %{} = incident, control_replacing: replacing}} = socket
      ) do
    if Monitoring.acknowledgement_active?(incident) do
      {:noreply,
       assign(socket, control_replacing: !replacing, control_draft: %{}, control_feedback: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "edit_acknowledgement",
        params,
        %{assigns: %{control_review: %{}}} = socket
      ) do
    {:noreply, assign(socket, control_draft: acknowledgement_draft(params))}
  end

  def handle_event(
        "save_acknowledgement",
        params,
        %{assigns: %{control_review: %{} = review, id: id, kind: kind, live_action: action}} =
          socket
      )
      when action in [:health, :loss] do
    draft = acknowledgement_draft(params)
    socket = assign(socket, control_draft: draft)
    note = Map.get(params, "note", "")

    note =
      if is_binary(note) && String.valid?(note) && String.trim(note) == "",
        do: "No note provided.",
        else: note

    result =
      with {:ok, options} <- acknowledgement_options(review, draft) do
        apply_acknowledgement(kind, id, options, note)
      end

    acknowledgement_result(socket, result, "Acknowledgement saved.")
  end

  def handle_event(
        "end_acknowledgement",
        _,
        %{
          assigns: %{
            control_review: %{} = review,
            id: id,
            kind: kind,
            live_action: action,
            incident: %{} = incident
          }
        } = socket
      )
      when action in [:health, :loss] do
    if Monitoring.acknowledgement_active?(incident) do
      result =
        apply_acknowledgement(kind, id, Map.put(review, "mode", "end"), "Ended by operator.")

      acknowledgement_result(socket, result, "Acknowledgement ended.")
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "retry_delivery",
        %{"_id" => id, "reason" => reason},
        %{assigns: %{live_action: action, detail: %{} = detail}} = socket
      )
      when action in [:health, :loss] do
    occurrences = detail["occurrences"] || []
    drafts = NotificationRetry.keep_draft(socket.assigns.retry_drafts, occurrences, id, reason)

    if Enum.any?(occurrences, &(&1["id"] == id && &1["can_retry"])) do
      case Monitoring.retry_notification(id, reason) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             retry_drafts: Map.delete(drafts, id),
             delivery_feedback: {:ok, NotificationRetry.success_message()}
           )
           |> refresh()}

        {:error, error} ->
          {:noreply,
           socket
           |> assign(
             retry_drafts: drafts,
             delivery_feedback: {:error, NotificationRetry.error_message(error)}
           )
           |> refresh()}
      end
    else
      {:noreply,
       assign(socket,
         delivery_feedback: {:error, "This notification is no longer eligible for a retry."}
       )}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp apply_acknowledgement("health", id, options, note),
    do: Monitoring.acknowledge(id, options, note)

  defp apply_acknowledgement("loss", id, options, note),
    do: MonitoringLoss.acknowledge(id, options, note)

  defp acknowledgement_result(socket, result, message) do
    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           control_review: nil,
           control_draft: %{},
           control_replacing: false,
           control_feedback: {:ok, message}
         )
         |> refresh()}

      {:error, :stale} ->
        {:noreply,
         socket
         |> assign(
           control_feedback: {:error, "The incident changed. Review it again before saving."}
         )
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         assign(socket, control_feedback: {:error, NotificationRetry.error_message(reason)})}
    end
  end

  defp acknowledgement_revision(incident) do
    %{
      "revision" => incident["acknowledgement_revision"],
      "attention_revision" => incident["attention_revision"]
    }
  end

  defp acknowledgement_draft(params) do
    params
    |> Map.take(~w(mode amount unit expires_at note))
    |> Map.filter(fn {_, value} ->
      is_binary(value) and byte_size(value) <= 2_000 and String.valid?(value)
    end)
  end

  defp acknowledgement_options(review, %{"mode" => mode})
       when mode == "until_incident_ends",
       do: {:ok, Map.put(review, "mode", mode)}

  defp acknowledgement_options(review, %{"mode" => "duration"} = draft) do
    units = %{"minutes" => 60, "hours" => 3600, "days" => 86_400}

    with {amount, ""} when amount > 0 <- Integer.parse(draft["amount"] || ""),
         seconds_per_unit when is_integer(seconds_per_unit) <- units[draft["unit"]] do
      {:ok, Map.merge(review, %{"mode" => "duration", "seconds" => amount * seconds_per_unit})}
    else
      _ -> {:error, {:invalid, "Enter a positive whole number and choose a unit."}}
    end
  end

  defp acknowledgement_options(review, %{"mode" => "until"} = draft) do
    value = draft["expires_at"] || ""
    value = if byte_size(value) == 16, do: value <> ":00", else: value

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, Map.merge(review, %{"mode" => "until", "expires_at" => DateTime.to_iso8601(utc)})}
    else
      _ -> {:error, {:invalid, "Enter a future date and time in UTC."}}
    end
  end

  defp acknowledgement_options(_, _),
    do: {:error, {:invalid, "Choose when the acknowledgement should end."}}

  defp patch_filters(socket, changes) do
    next = socket.assigns.filters |> Map.merge(changes) |> Map.delete("page") |> filters()
    {:noreply, push_patch(socket, to: list_path(next))}
  end

  defp filter_ready(socket) do
    socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})
  end

  defp picker(field, value) do
    value = if String.valid?(value), do: String.slice(value, 0, 200), else: ""
    query = value |> String.trim() |> String.downcase()

    options =
      for {key, label} <- choices(field),
          key != "all",
          String.contains?(String.downcase(label), query),
          do: %{key: key, label: label, kind: ""}

    {^field, title, _} = List.keyfind(@filter_fields, field, 0)
    %{field: field, title: title, value: value, options: options}
  end

  defp choices("type"), do: @types
  defp choices("grouping"), do: @groupings
  defp choices("status"), do: @statuses
  defp choices("severity"), do: @severities
  defp choices("acknowledgement"), do: @acknowledgements
  defp choices("opened"), do: @opened

  defp option_label(field, key), do: List.keyfind(choices(field), key, 0) |> elem(1)

  defp chips(filters) do
    for {field, name, _icon} <- @filter_fields,
        key = filters[field],
        key != "all",
        do: %{field: field, name: name, label: option_label(field, key)}
  end

  defp filters(params) do
    search = Mondek.OverviewFilters.params(params)["search"]

    %{
      "type" => choice(params["type"], @types),
      "grouping" => choice(params["grouping"], @groupings),
      "status" => choice(params["status"], @statuses),
      "severity" => choice(params["severity"], @severities),
      "acknowledgement" => choice(params["acknowledgement"], @acknowledgements),
      "opened" => choice(params["opened"], @opened),
      "page" => number(params["page"])
    }
    |> then(fn filters -> if search, do: Map.put(filters, "search", search), else: filters end)
  end

  defp choice(value, choices) do
    if List.keymember?(choices, value, 0), do: value, else: elem(hd(choices), 0)
  end

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> Integer.to_string(n)
      _ -> "1"
    end
  end

  defp number(_), do: "1"

  def path(kind, id, filters \\ %{}, full_page \\ false) when kind in ["health", "loss"] do
    with_query(
      "/next/incidents/" <>
        kind <>
        "/" <>
        URI.encode(id, &URI.char_unreserved?/1) <>
        if(full_page, do: "/full", else: ""),
      filters
    )
  end

  def return_path(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.authority == nil && uri.fragment == nil &&
         is_binary(uri.path) &&
         Regex.match?(~r"\A/next/incidents/(health|loss)/[0-9a-f-]{36}(?:/full)?\z", uri.path) do
      params = URI.decode_query(uri.query || "")
      with_query(uri.path, Map.merge(filters(params), detail_filters(params)))
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil

  defp detail_filters(params) do
    %{
      "member_page" => number(params["member_page"]),
      "notification_page" => number(params["notification_page"]),
      "healthy_page" => number(params["healthy_page"]),
      "contributors" =>
        if(params["contributors"] in ~w(all open history uncovered),
          do: params["contributors"],
          else: "default"
        ),
      "notification_status" => choice(params["notification_status"], @delivery_statuses)
    }
  end

  defp list_path(filters), do: with_query("/next/incidents", filters)

  defp with_query(path, params) do
    query =
      params
      |> Enum.reject(fn {key, value} ->
        {key, value} in [
          {"type", "all"},
          {"grouping", "top"},
          {"status", "open"},
          {"severity", "all"},
          {"acknowledgement", "all"},
          {"opened", "all"},
          {"page", "1"},
          {"member_page", "1"},
          {"notification_page", "1"},
          {"healthy_page", "1"},
          {"contributors", "default"},
          {"notification_status", "all"}
        ]
      end)
      |> URI.encode_query()

    if query == "", do: path, else: path <> "?" <> query
  end

  defp refresh(socket) do
    now = Monitoring.now()
    socket = if socket.assigns.full_page, do: socket, else: refresh_listing(socket, now)
    refresh_detail(socket, now)
  end

  defp refresh_listing(%{assigns: %{filters: filters}} = socket, now) do
    severity = filters["severity"]
    health_only? = severity != "all" || filters["grouping"] not in ["top", "all"]
    type = if filters["type"] == "all" && health_only?, do: "health", else: filters["type"]

    domain =
      filters
      |> Map.put("page", if(type == "all", do: "1", else: filters["page"]))
      |> Map.put("page_size", "25")
      |> Map.put("health", severity)
      |> Map.put("priority_order", true)
      |> Map.put("opened_since", opened_since(now, filters["opened"]))

    health = if type != "loss", do: Monitoring.list_incidents(domain, now)
    loss = if type != "health" && !health_only?, do: MonitoringLoss.list(domain, now)
    health_rows = if health, do: Enum.map(health.items, &row("health", &1, now)), else: []
    loss_rows = if loss, do: Enum.map(loss["items"], &row("loss", &1, now)), else: []

    rows =
      if type == "all" do
        Enum.sort_by(health_rows ++ loss_rows, fn row ->
          {row.status != "open", row.acknowledged, priority(row), row.opened_at, row.id}
        end)
      else
        health_rows ++ loss_rows
      end

    page =
      case type do
        "health" ->
          %{page: health.page, size: health.page_size, total: health.total}

        "loss" when not is_nil(loss) ->
          %{page: loss["page"], size: loss["page_size"], total: loss["total"]}

        _ ->
          nil
      end

    assign(socket,
      now: now,
      filter_fields: @filter_fields,
      rows: rows,
      page: page,
      totals: %{"health" => health && health.total, "loss" => loss && loss["total"]},
      shown: %{"health" => length(health_rows), "loss" => length(loss_rows)}
    )
  end

  defp refresh_detail(%{assigns: %{live_action: :index}} = socket, _now), do: socket

  defp refresh_detail(socket, now) do
    %{live_action: action, id: id, detail_filters: filters} = socket.assigns

    {kind, detail, incident} =
      case action do
        :health ->
          detail =
            Monitoring.incident_detail(id, now, %{
              "page" => filters["member_page"],
              "state" => filters["contributors"],
              "contradiction_page" => filters["healthy_page"],
              "notification_status" => filters["notification_status"],
              "notification_page" => filters["notification_page"]
            })

          {"health", detail, detail && detail["incident"]}

        :loss ->
          detail = MonitoringLoss.detail(id, now, %{"members_page" => filters["member_page"]})
          {"loss", detail, detail}
      end

    review =
      socket.assigns.control_review ||
        if incident && incident["status"] == "open", do: acknowledgement_revision(incident)

    assign(socket,
      now: now,
      kind: kind,
      detail: detail,
      incident: incident,
      maintenance_windows: active_maintenance(kind, incident, now),
      control_review: review
    )
  end

  defp active_maintenance("health", %{"status" => "open"} = incident, now) do
    windows =
      cond do
        id = incident["stream_id"] -> Maintenance.for_stream(id, now)
        id = incident["assignment_id"] -> Maintenance.for_assignment(id, now)
        true -> []
      end

    Enum.filter(windows, &(&1["status"] == "active"))
  end

  defp active_maintenance(_, _, _), do: []

  defp opened_since(now, "24h"), do: DateTime.add(now, -1, :day)
  defp opened_since(now, "7d"), do: DateTime.add(now, -7, :day)
  defp opened_since(now, "30d"), do: DateTime.add(now, -30, :day)
  defp opened_since(_, _), do: nil

  defp priority(%{health: "CRIT"}), do: 0
  defp priority(%{kind: "loss"}), do: 1
  defp priority(%{health: "WARN"}), do: 2
  defp priority(_), do: 3

  defp row(kind, incident, now) do
    %{
      kind: kind,
      id: incident["id"],
      title: title(kind, incident),
      context: context(incident),
      contribution_count: incident["contribution_count"],
      health: incident["health"],
      status: incident["status"],
      opened_at: incident["opened_at"],
      acknowledged: Monitoring.acknowledgement_active?(incident, now)
    }
  end

  defp title("loss", %{"scope_kind" => "coverage"}), do: "No runner selected"
  defp title("loss", incident), do: incident["label"] || "Measurements missing"

  defp title("health", incident),
    do:
      incident["label"] || incident["check_label"] || incident["result_label"] ||
        "Health incident"

  defp context(incident) do
    [
      if(incident["target"], do: target_label(incident["target"])),
      incident["environment_label"] || incident["environment"],
      incident["runner_label"],
      if(incident["scope_kind"] == "coverage", do: incident["source_id"]),
      if(incident["member_count"], do: count(incident["member_count"], "affected result")),
      if(incident["condition_incident_id"], do: "Shared incident member")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp count(1, noun), do: "1 " <> noun
  defp count(n, noun), do: "#{n} #{noun}s"
  defp type_label(kind), do: List.keyfind(@types, kind, 0) |> elem(1)

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="incidents-preview"
      phx-hook="OverviewPanel"
      data-selection={if @id, do: "#{@live_action}-#{@id}-#{@full_page}"}
      data-panel-heading="incidents-heading"
    >
      <MondekWeb.PreviewLayouts.navigation active={:incidents} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <.listing :if={!@full_page} {assigns} />
        <.detail :if={@live_action != :index} {assigns} />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp listing(assigns) do
    ~H"""
    <section class="preview-list" aria-labelledby="incidents-heading">
      <header class="preview-heading">
        <h1 id="incidents-heading" class="pf-v6-c-title pf-m-2xl">Incidents</h1>
      </header>
      <div class="preview-incident-search">
        <MondekWeb.PreviewFilters.filter_picker
          picker={@filter_picker}
          chips={chips(@filters)}
          fields={@filter_fields}
          search={@filters["search"]}
          remove={fn field -> list_path(Map.merge(@filters, %{field => "all", "page" => "1"})) end}
          clear_search={list_path(@filters |> Map.delete("search") |> Map.put("page", "1"))}
          form_label="Filter incidents"
          label="Search incidents"
          placeholder="Search or filter incidents"
        />
      </div>
      <p class="preview-incident-order preview-caption">
        Open first, then unacknowledged. Critical → monitoring loss → warning → unknown. Oldest first within each group.
      </p>
      <div class="preview-table-group">
        <p :if={@rows == []} class="preview-empty">No incidents match these filters.</p>
        <table
          :if={@rows != []}
          class="pf-v6-c-table pf-m-compact preview-table preview-incident-table"
          aria-label="Incidents"
        >
          <thead class="pf-v6-c-table__thead">
            <tr class="pf-v6-c-table__tr">
              <th scope="col" class="pf-v6-c-table__th">Severity</th>
              <th scope="col" class="pf-v6-c-table__th">Incident</th>
              <th scope="col" class="pf-v6-c-table__th">Type</th>
              <th scope="col" class="pf-v6-c-table__th">Status</th>
              <th scope="col" class="pf-v6-c-table__th">Opened</th>
            </tr>
          </thead>
          <tbody class="pf-v6-c-table__tbody">
            <tr
              :for={row <- @rows}
              class={[
                "pf-v6-c-table__tr",
                @id == row.id && to_string(@live_action) == row.kind && "preview-selected"
              ]}
              data-overview-row
              id={"preview-incident-" <> row.kind <> "-" <> row.id}
            >
              <td class="pf-v6-c-table__td" data-label="Severity">
                <.severity health={row.health} />
              </td>
              <td class="pf-v6-c-table__td" data-label="Incident">
                <.link
                  patch={
                    if @id == row.id && to_string(@live_action) == row.kind,
                      do: list_path(@filters),
                      else: path(row.kind, row.id, @filters)
                  }
                  id={"open-incident-" <> row.kind <> "-" <> row.id}
                  data-overview-open
                  class="preview-result-link"
                >{row.title}</.link>
                <.shared_incident_badge :if={row.contribution_count} count={row.contribution_count} />
                <span :if={row.context != ""} class="preview-caption">{row.context}</span>
              </td>
              <td class="pf-v6-c-table__td" data-label="Type">{type_label(row.kind)}</td>
              <td class="pf-v6-c-table__td" data-label="Status">
                <.incident_state
                  status={row.status}
                  acknowledged={row.acknowledged}
                />
              </td>
              <td class="pf-v6-c-table__td" data-label="Opened">
                <time datetime={row.opened_at} title={time(row.opened_at)}>{age(row.opened_at, @now)}</time>
              </td>
            </tr>
          </tbody>
        </table>
        <nav :if={@page} class="preview-pager" aria-label="Incident pages">
          <.page_links
            page={@page.page}
            size={@page.size}
            total={@page.total}
            url={fn p -> list_path(Map.put(@filters, "page", to_string(p))) end}
          />
        </nav>
        <div :if={!@page && @rows != []} class="preview-pager">
          <span :for={kind <- ~w(health loss)}>
            {@shown[kind]} of {@totals[kind]} {if kind == "health",
              do: "health incidents",
              else: "monitoring loss incidents"}
            <.link
              :if={@shown[kind] < @totals[kind]}
              patch={list_path(Map.put(@filters, "type", kind))}
            >View all</.link>
          </span>
        </div>
      </div>
    </section>
    """
  end

  defp detail(assigns) do
    assigns =
      assign(assigns,
        back: list_path(assigns.filters),
        current:
          path(
            assigns.kind,
            assigns.id,
            Map.merge(assigns.filters, assigns.detail_filters),
            assigns.full_page
          ),
        title: detail_title(assigns.kind, assigns.detail, assigns.incident),
        delivery_statuses: @delivery_statuses
      )

    ~H"""
    <section
      id={if @full_page, do: "incident-page", else: "overview-panel"}
      class={[
        "preview-incident-panel pf-v6-c-card",
        if(@full_page, do: "preview-incident-page", else: "preview-panel")
      ]}
      role={if !@full_page, do: "dialog"}
      aria-modal={if !@full_page, do: "false"}
      aria-labelledby="incident-heading"
    >
      <div class="pf-v6-c-card__body">
        <div class="preview-panel-tools">
          <.link patch={@back} data-overview-close={!@full_page} class="pf-v6-c-button pf-m-link">← Back to incidents</.link>
          <.link
            :if={@incident && !@full_page}
            patch={path(@kind, @id, Map.merge(@filters, @detail_filters), true)}
            class="pf-v6-c-button pf-m-link"
          >Open as page</.link>
        </div>
        <header class="preview-incident-intro">
          <p :if={@incident && !@detail["contributions"]} class="preview-caption">
            {type_label(@kind)}<span :if={@incident["scope_kind"] == "coverage"}> · {@incident[
              "source_id"
            ]}</span>
          </p>
          <h1 :if={@full_page} id="incident-heading" tabindex="-1" class="pf-v6-c-title pf-m-2xl">
            {@title}
          </h1>
          <h2 :if={!@full_page} id="incident-heading" tabindex="-1" class="pf-v6-c-title pf-m-2xl">
            {@title}
          </h2>
          <div :if={@incident} class="preview-incident-meta">
            <.shared_incident_badge
              :if={@detail["contributions"]}
              count={@detail["counts"]["total"]}
            />
            <.severity :if={@incident["health"]} health={@incident["health"]} />
            <.incident_state
              status={@incident["status"]}
              acknowledged={Monitoring.acknowledgement_active?(@incident, @now)}
            />
          </div>
          <dl :if={@incident} class="preview-incident-facts">
            <div>
              <dt>Opened</dt>
              <dd><time datetime={@incident["opened_at"]}>{time(@incident["opened_at"])}</time></dd>
            </div>
            <div :if={@incident["closed_at"]}>
              <dt>Ended</dt>
              <dd><time datetime={@incident["closed_at"]}>{time(@incident["closed_at"])}</time></dd>
            </div>
            <div :if={@incident["member_count"]}>
              <dt>Affected results</dt><dd>{@incident["member_count"]}</dd>
            </div>
          </dl>
        </header>
        <p :if={!@incident} class="preview-empty">
          This incident may have been removed by retention.
        </p>
        <.health_evidence
          :if={@incident && @kind == "health"}
          detail={@detail}
          current={@current}
        />
        <.loss_evidence :if={@incident && @kind == "loss"} detail={@detail} current={@current} />
        <PreviewIncidentSections.sections
          :if={@incident}
          incident={@incident}
          detail={@detail}
          kind={@kind}
          now={@now}
          review={@control_review}
          draft={@control_draft}
          replacing={@control_replacing}
          feedback={@control_feedback}
          delivery_feedback={@delivery_feedback}
          retry_drafts={@retry_drafts}
          maintenance_windows={@maintenance_windows}
          current={@current}
        >
          <:delivery_filter>
            <.detail_filter
              :if={@detail["notification_page"]}
              field="notification_status"
              label="Delivery status"
              choices={@delivery_statuses}
              value={@detail_filters["notification_status"]}
            />
          </:delivery_filter>
          <:delivery_pagination>
            <.detail_pages
              :if={@detail["notification_page"]}
              listing={@detail["notification_page"]}
              current={@current}
              param="notification_page"
              label="Notification pages"
            />
          </:delivery_pagination>
        </PreviewIncidentSections.sections>
      </div>
    </section>
    """
  end

  defp detail_title(_, _, nil), do: "Incident unavailable"
  defp detail_title("loss", _, incident), do: title("loss", incident)

  defp detail_title("health", detail, incident),
    do:
      incident["label"] || get_in(detail, ["assignment", "label"]) ||
        get_in(detail, ["stream", "label"]) || "Health incident"

  defp health_evidence(assigns) do
    detail = assigns.detail
    incident = detail["incident"]

    firing = Enum.find(detail["occurrences"] || [], &(&1["kind"] == "firing"))
    evidence_by_id = Map.new(detail["evidence"] || [], &{&1["id"], &1})

    evidence =
      Enum.find_value(
        [
          incident["latest_observation_id"],
          incident["opening_observation_id"],
          get_in(firing, ["payload", "observation_id"])
        ],
        &Map.get(evidence_by_id, &1)
      )

    measured =
      Enum.find(
        get_in(evidence || %{}, ["payload", "results"]) || [],
        &(&1["key"] == incident["result_key"])
      )

    assign(assigns,
      incident: incident,
      measured: measured,
      measured_at: (measured && measured["source_at"]) || (evidence && evidence["evaluated_at"])
    )
    |> render_health_evidence()
  end

  defp render_health_evidence(assigns) do
    ~H"""
    <section class="preview-table-group preview-incident-section">
      <h3 class="preview-section-heading">
        {if @detail["contributions"], do: "Contributing results", else: "Recorded failure"}
      </h3>
      <table
        :if={!@detail["contributions"]}
        class="preview-incident-fact-table"
        aria-label="Recorded failure"
      >
        <tbody>
          <tr>
            <th scope="row">Finding</th>
            <td class="preview-incident-finding">
              <.severity :if={@measured && @measured["health"]} health={@measured["health"]} />
              {if @measured,
                do: @measured["summary"],
                else: "The recorded measurement is unavailable."}
            </td>
          </tr>
          <tr :if={@detail["stream"]}>
            <th scope="row">Target</th><td>{target_label(@detail["stream"]["target"])}</td>
          </tr>
          <tr :if={@detail["stream"]}>
            <th scope="row">Environment</th>
            <td>
              {@detail["stream"]["environment_label"] || @detail["stream"]["environment"] ||
                "Unscoped"}
            </td>
          </tr>
          <tr :if={@measured && @measured_at}>
            <th scope="row">Measured</th>
            <td><time datetime={@measured_at}>{time(@measured_at)}</time></td>
          </tr>
          <tr :if={@measured && @measured["details"] not in [nil, ""]}>
            <th scope="row">Check details</th><td>
              <pre class="preview-findings">{@measured["details"]}</pre>
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={!@detail["contributions"] && @incident["stream_id"]} class="preview-recorded-actions">
        <a href={evidence_path(:result, @incident["stream_id"], @current)}>Open current result evidence →</a>
      </div>
      <div :if={@incident["condition_incident_id"]} class="preview-recorded-actions">
        <.link patch={related_incident_path(@current, @incident["condition_incident_id"])}>
          Open shared incident and its notifications
        </.link>
      </div>
      <table
        :if={
          @detail["contributions"] &&
            (@incident["status"] == "open" || (@incident["impacts"] || []) != [])
        }
        class="preview-incident-fact-table"
        aria-label="Shared incident summary"
      >
        <tbody>
          <tr :if={(@incident["impacts"] || []) != []}>
            <th scope="row">Impacts</th>
            <td>{Enum.map_join(@incident["impacts"], ", ", &(&1["label"] || &1["key"]))}</td>
          </tr>
          <tr :if={@incident["status"] == "open"}>
            <th scope="row">Failure notifications</th>
            <td>
              <p>
                Unpaused for {@detail["counts"]["uncovered"]} of {@detail["counts"]["open"]} failing results
              </p>
              <.link
                :if={
                  @detail["contribution_page"]["state"] != "uncovered" &&
                    @detail["counts"]["uncovered"] > 0
                }
                patch={detail_path(@current, %{"contributors" => "uncovered", "member_page" => "1"})}
              >Show results with unpaused notifications</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <div
        :if={
          @detail["contributions"] && @incident["status"] == "open" &&
            (@detail["contribution_page"]["state"] != "open" ||
               @detail["counts"]["recovered"] + @detail["counts"]["withdrawn"] > 0)
        }
        class="preview-recorded-actions"
      >
        <.link
          :if={@detail["contribution_page"]["state"] != "open"}
          patch={detail_path(@current, %{"contributors" => "default", "member_page" => "1"})}
        >Show active contributors</.link>
        <.link
          :if={@detail["contribution_page"]["state"] == "open"}
          patch={detail_path(@current, %{"contributors" => "history", "member_page" => "1"})}
        >Show historical contributors</.link>
      </div>
      <p :if={@detail["contributions"] == []} class="preview-recorded-actions">
        No contributing results match this view.
      </p>
      <table
        :if={@detail["contributions"] not in [nil, []]}
        class="preview-incident-fact-table preview-contributor-table"
        aria-label="Contributing results"
      >
        <thead>
          <tr>
            <th scope="col">Result</th><th scope="col">Incident details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={contribution <- @detail["contributions"]}>
            <th scope="row">
              <.link patch={related_incident_path(@current, contribution["incident"]["id"])}>
                {get_in(contribution, ["stream", "label"]) ||
                  get_in(contribution, ["assignment", "label"])}
              </.link>
              <div :if={contribution["incident"]["stream_id"]} class="preview-caption">
                <a href={evidence_path(:result, contribution["incident"]["stream_id"], @current)}>
                  Current result evidence
                </a>
              </div>
            </th>
            <td class="preview-incident-nested-facts">
              <table aria-label="Contributor details">
                <tbody>
                  <tr>
                    <th scope="row">Last failure</th>
                    <td>
                      <.severity health={contribution["last_failure_health"]} />
                      <p :if={contribution["measured_result"]}>
                        {contribution["measured_result"]["summary"]}
                      </p>
                    </td>
                  </tr>
                  <tr>
                    <th scope="row">State</th>
                    <td>
                      <span class={[
                        "pf-v6-c-label",
                        contribution_state_color(contribution["contribution_state"])
                      ]}>
                        <span class="pf-v6-c-label__content">{badge_text(
                          contribution["contribution_state"]
                        )}</span>
                      </span>
                    </td>
                  </tr>
                  <tr :if={
                    contribution["incident"]["status"] == "open" &&
                      (contribution["coverage"]["uncovered"] ||
                         contribution["coverage"]["shared_acknowledgement"] ||
                         contribution["coverage"]["individual_acknowledgement"] ||
                         contribution["coverage"]["maintenance_windows"] not in [nil, []])
                  }>
                    <th scope="row">Notifications</th>
                    <td>
                      <p :if={contribution["coverage"]["uncovered"]}>Not paused</p>
                      <p :if={contribution["coverage"]["shared_acknowledgement"]}>
                        Paused by shared acknowledgement
                      </p>
                      <p :if={contribution["coverage"]["individual_acknowledgement"]}>
                        Paused by individual acknowledgement
                      </p>
                      <p :for={window <- contribution["coverage"]["maintenance_windows"] || []}>
                        Paused for maintenance:
                        <.link href={"/maintenance/" <> window["id"]}>{window["name"] ||
                          window["reason"] || "View maintenance"}</.link>
                        <span class="preview-caption"> · Ends {time(window["ends_at"])}</span>
                      </p>
                    </td>
                  </tr>
                </tbody>
              </table>
            </td>
          </tr>
        </tbody>
      </table>
      <.detail_pages
        :if={@detail["contribution_page"]}
        listing={@detail["contribution_page"]}
        current={@current}
        param="member_page"
        label="Contributing result pages"
      />
      <details
        :if={(get_in(@detail, ["contradiction_page", "total"]) || 0) > 0}
        id={"preview-confirmed-healthy-" <> @incident["id"]}
        class="preview-incident-history"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary>Last confirmed healthy results ({@detail["contradiction_page"]["total"]})</summary>
        <div class="preview-incident-history-content">
          <p class="preview-incident-evidence">
            These results share the same condition. Their last confirmed measurements were healthy, but collection may now be stale or unavailable.
          </p>
          <table class="preview-incident-fact-table" aria-label="Last confirmed healthy results">
            <tbody>
              <tr :for={stream <- @detail["contradictions"]}>
                <th scope="row">
                  <.link href={evidence_path(:result, stream["id"], @current)}>{stream["label"]}</.link>
                </th>
                <td>{get_in(stream, ["current", "summary"])}</td>
              </tr>
            </tbody>
          </table>
          <.detail_pages
            listing={@detail["contradiction_page"]}
            current={@current}
            param="healthy_page"
            label="Last confirmed healthy result pages"
          />
        </div>
      </details>
    </section>
    """
  end

  defp loss_evidence(assigns) do
    ~H"""
    <section class="preview-table-group preview-incident-section">
      <h3 class="preview-section-heading">
        {if @detail["status"] == "open", do: "Affected results", else: "Last affected results"}
      </h3>
      <p :if={@detail["status"] == "open"} class="preview-incident-evidence">
        {if @detail["scope_kind"] == "coverage",
          do:
            "The monitoring project expects these results. Review how runners are selected for them.",
          else:
            "Mondek is missing current measurements for these results. Check the collection or runner evidence below."}
      </p>
      <p :if={@detail["status"] == "closed"} class="preview-incident-evidence">
        {if @detail["closure_reason"] == "monitoring_restored",
          do: "Monitoring was restored.",
          else: "This monitoring loss incident ended."}
      </p>
      <p :if={@detail["members"]["items"] == []} class="preview-incident-evidence">
        No affected result details are available.
      </p>
      <div :for={member <- @detail["members"]["items"]} class="preview-incident-evidence">
        <h4>{member["label"] || target_label(member["target"])}</h4>
        <p>
          {loss_reason(member["knowledge"])}
          <span :if={member["since_at"]}>· Since {time(member["since_at"])}</span>
        </p>
        <p class="preview-caption">
          {target_label(member["target"])} · {member["environment"] || "Unscoped"}
        </p>
        <a :if={member["stream_id"]} href={evidence_path(:result, member["stream_id"], @current)}>Open current result evidence</a>
        <a
          :if={!member["stream_id"] && member["coverage_id"]}
          href={evidence_path(:expected, member["coverage_id"], @current)}
        >Review expected monitoring</a>
      </div>
      <p :if={@detail["members"]["truncated"]} class="preview-incident-evidence">
        {length(@detail["members"]["items"])} of {@detail["member_count"]} affected results retained here.
      </p>
      <.detail_pages
        listing={@detail["members"]}
        current={@current}
        param="member_page"
        label="Affected result pages"
      />
    </section>
    """
  end

  defp related_incident_path(current, id) do
    params = URI.decode_query(URI.parse(current).query || "")
    path("health", id, filters(params), String.ends_with?(URI.parse(current).path, "/full"))
  end

  defp detail_path(current, changes) do
    uri = URI.parse(current)
    with_query(uri.path, Map.merge(URI.decode_query(uri.query || ""), changes))
  end

  defp detail_filter(assigns) do
    ~H"""
    <form
      id={"preview-filter-detail-" <> @field}
      phx-change="filter_incident_detail"
      phx-auto-recover="ignore"
      class="preview-recorded-actions preview-detail-filter"
    >
      <label for={"preview-detail-" <> @field}>{@label}</label>
      <select id={"preview-detail-" <> @field} name={@field}>
        <option :for={{value, label} <- @choices} value={value} selected={@value == value}>
          {label}
        </option>
      </select>
    </form>
    """
  end

  defp detail_pages(assigns) do
    ~H"""
    <nav
      :if={@listing["total"] > @listing["page_size"]}
      class="preview-pager"
      aria-label={@label}
    >
      <.page_links
        page={@listing["page"]}
        size={@listing["page_size"]}
        total={@listing["total"]}
        url={
          fn p ->
            detail_path(@current, %{@param => to_string(p)})
          end
        }
      />
    </nav>
    """
  end

  defp page_links(assigns) do
    assigns = assign(assigns, :pages, max(1, ceil(assigns.total / assigns.size)))

    ~H"""
    <span>Page {@page} of {@pages} · {@total} total</span>
    <.link :if={@page > 1} patch={@url.(@page - 1)}>Previous</.link>
    <.link :if={@page < @pages} patch={@url.(@page + 1)}>Next</.link>
    """
  end

  defp shared_incident_badge(assigns) do
    ~H"""
    <span class="pf-v6-c-label pf-m-blue">
      <span class="pf-v6-c-label__content">
        Shared incident · {count(@count, "member")}
      </span>
    </span>
    """
  end

  defp contribution_state_color("open"), do: "pf-m-blue"
  defp contribution_state_color("recovered"), do: "pf-m-green"
  defp contribution_state_color(_), do: nil

  defp severity(assigns) do
    ~H"""
    <span
      :if={@health}
      class={["pf-v6-c-label", @health == "CRIT" && "pf-m-red", @health == "WARN" && "pf-m-orange"]}
    >
      <span class="pf-v6-c-label__content">{badge_text(@health)}</span>
    </span>
    <span :if={!@health} class="preview-caption" title="No measured severity">—</span>
    """
  end

  defp incident_state(assigns) do
    ~H"""
    <span class="preview-incident-state">
      <span>{if @status == "open", do: "Open", else: "Closed"}</span>
      <span :if={@acknowledged} class="preview-caption">Acknowledged</span>
    </span>
    """
  end

  defp loss_reason("unavailable"), do: "Collection unavailable"
  defp loss_reason("stale"), do: "Measurement overdue"
  defp loss_reason("control_contact_overdue"), do: "Runner contact overdue"
  defp loss_reason("no_selected_runner"), do: "No selected runner"
  defp loss_reason("awaiting_new_measurement"), do: "Awaiting a new measurement"
  defp loss_reason("awaiting_coverage_measurement"), do: "Awaiting a coverage measurement"
  defp loss_reason(_), do: "Measurement unavailable"

  defp evidence_path(kind, id, current),
    do: MondekWeb.NextOverviewLive.path(%{"incident_return" => current}, kind, id)
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnersLive do
  use MondekWeb, :live_view
  alias Mondek.{Monitoring, RunnerFleet}

  alias MondekWeb.{
    InvestigationStack,
    InvestigationTrail,
    PreviewFilters,
    PreviewLayouts,
    RunnerDetail,
    ScalarFilterPicker
  }

  @fields [
    {"contact", "Contact", "pulse"},
    {"collection", "Collection", "check"},
    {"source_id", "Source", "code"}
  ]
  @contacts [
    {"all", "Any contact"},
    {"recent", "Recent contact"},
    {"overdue", "Contact overdue"},
    {"never", "Never contacted"}
  ]
  @collections [
    {"all", "Any collection state"},
    {"issues", "Measurement gaps"},
    {"fresh", "All results fresh"},
    {"empty", "No active results"}
  ]
  @sorts [
    {"attention", "Needs attention first"},
    {"name", "Runner name"},
    {"last_contact", "Latest contact first"}
  ]

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       page_title: "Runners",
       filters: %{},
       listing: %{},
       filter_picker: nil,
       now: Monitoring.now()
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    origin = URI.parse(uri)
    filters = RunnerFleet.normalize(params)

    identity =
      case Ecto.UUID.cast(params["id"]) do
        {:ok, id} -> {"runner", id}
        _ -> nil
      end

    direct_full = String.ends_with?(origin.path, "/full")
    root = if direct_full, do: identity
    initial = if !direct_full, do: List.wrap(identity), else: []
    full_page = !is_nil(root) || !is_nil(InvestigationTrail.promoted(params, initial))
    local = origin.path <> if(origin.query, do: "?" <> origin.query, else: "")
    picker = if filters == socket.assigns.filters, do: socket.assigns.filter_picker

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_picker: picker,
       selected_id: params["id"],
       missing_identity: params["id"] && is_nil(identity),
       initial_trail: initial,
       investigation_root: root,
       investigation_params: params,
       investigation_host: local,
       full_page: full_page,
       controller_url:
         URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port}),
       investigation_selection: InvestigationTrail.selection(params, initial)
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket),
    do: patch_filters(socket, %{"search" => ScalarFilterPicker.text(search)})

  def handle_event("sort", %{"sort" => sort}, socket) do
    if sort == socket.assigns.filters["sort"],
      do: {:noreply, socket},
      else: patch_filters(socket, %{"sort" => sort})
  end

  def handle_event("filter_open", %{"field" => field}, socket) do
    case picker(field, "") do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply,
         assign(socket,
           filter_picker: %{draft | value: selected_label(socket.assigns.filters, field)}
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
      do: patch_filters(ready(socket), %{field => if(field == "source_id", do: "", else: "all")})

  def handle_event("filter_remove", %{"field" => field}, socket)
      when field in ~w(contact collection source_id search),
      do: patch_filters(ready(socket), %{field => ""})

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

  defp patch_filters(socket, changes) do
    next =
      socket.assigns.filters
      |> Map.merge(changes)
      |> Map.delete("page")
      |> RunnerFleet.normalize()

    {:noreply, push_patch(socket, to: path(next))}
  end

  defp ready(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp picker(field, value),
    do: ScalarFilterPicker.draft(@fields, &choices(&1, value), field, value, empty_values(field))

  defp choices("contact", _), do: @contacts
  defp choices("collection", _), do: @collections
  defp choices("source_id", query), do: Enum.map(RunnerFleet.source_options(query), &{&1, &1})

  defp selected_label(filters, field),
    do:
      if(filters[field] in empty_values(field),
        do: "",
        else: ScalarFilterPicker.label(choices(field, ""), filters[field])
      )

  defp chips(filters),
    do: ScalarFilterPicker.chips(@fields, filters, &choices(&1, ""), &empty_values/1)

  defp empty_values("source_id"), do: [nil, ""]
  defp empty_values(_), do: [nil, "", "all"]

  defp refresh(socket) do
    now = Monitoring.now()
    listing = RunnerFleet.list(socket.assigns.filters, now)

    assign(socket,
      now: now,
      listing: listing,
      filters: listing["filters"],
      fields: @fields,
      sorts: @sorts,
      chips: chips(listing["filters"])
    )
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, counts: assigns.listing["counts"] || %{})

    ~H"""
    <div
      class="preview-shell"
      id="runners-shell"
      phx-hook="OverviewPanel"
      data-selection={@investigation_selection}
      data-panel-heading={
        if @full_page,
          do:
            InvestigationTrail.heading(
              @investigation_params,
              if(@investigation_root, do: "runner-heading", else: "runners-heading"),
              @initial_trail
            ),
          else: "runners-heading"
      }
    >
      <PreviewLayouts.navigation active={:runners} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section :if={!@full_page} class="preview-list" aria-labelledby="runners-heading">
          <header class="preview-heading">
            <h1 id="runners-heading" class="pf-v6-c-title pf-m-2xl">Runners</h1><.link
              navigate="/guide"
              class="pf-v6-c-button pf-m-secondary"
            >Set up a runner</.link>
          </header>
          <div id="runner-fleet-summary" class="runner-summary" aria-label="Overall runner fleet">
            <span><strong>{@counts["total"] || 0}</strong> registered</span><span><strong>{@counts[
              "recent"
            ] || 0}</strong>
            recent contact</span><span><strong>{@counts["overdue"] || 0}</strong> contact overdue</span><span><strong>{@counts[
              "issues"
            ] || 0}</strong>
            with measurement gaps</span>
          </div>
          <p class="runner-section-note">
            Installation-wide counts. Contact confirms communication; fresh results confirm collection.
          </p>
          <div class="runner-filter-toolbar">
            <PreviewFilters.filter_picker
              picker={@filter_picker}
              chips={@chips}
              fields={@fields}
              search={@filters["search"]}
              remove={
                fn field ->
                  path(
                    Map.put(@filters, field, if(field == "source_id", do: "", else: "all"))
                    |> Map.delete("page")
                  )
                end
              }
              clear_search={path(Map.put(@filters, "search", "") |> Map.delete("page"))}
              form_label="Filter runners"
              label="Search runners"
              placeholder="Search or filter runners"
            />
          </div>
          <div class="runner-list-order">
            <form id="runner-sort-form" phx-change="sort" phx-submit="sort">
              <label for="runner-sort">Sort by</label><select id="runner-sort" name="sort"><option
                :for={{value, label} <- @sorts}
                value={value}
                selected={@filters["sort"] == value}
              >
                {label}
              </option></select>
            </form><span class="preview-caption">{@listing["total"]} matching · {@counts["total"] || 0} registered</span>
          </div>
          <section class="preview-table-group runner-inventory" aria-label="Runner fleet">
            <div :if={@listing["items"] == []} id="runner-list-empty" class="preview-empty">
              <h2>
                {if @counts["total"] == 0, do: "No runners registered", else: "No matching runners"}
              </h2><p>
                {if @counts["total"] == 0,
                  do:
                    "Start a runner with a monitoring project and a persistent state directory. Published checks appear automatically.",
                  else: "Try another search or remove a filter."}
              </p><.link :if={@counts["total"] == 0} navigate="/guide">Set up your first runner</.link>
            </div>
            <table
              :if={@listing["items"] != []}
              id="runner-list"
              class="pf-v6-c-table pf-m-compact preview-table runner-table"
              aria-label="Registered runners"
            >
              <thead class="pf-v6-c-table__thead">
                <tr>
                  <th class="pf-v6-c-table__th" scope="col">Runner / execution context</th><th
                    class="pf-v6-c-table__th"
                    scope="col"
                  >
                    Controller contact
                  </th><th class="pf-v6-c-table__th" scope="col">Collection</th><th
                    class="pf-v6-c-table__th"
                    scope="col"
                  >
                    Inventory
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={runner <- @listing["items"]}
                  id={"runner-row-" <> runner["id"]}
                  data-overview-row
                >
                  <td class="pf-v6-c-table__td" data-label="Runner">
                    <.link
                      patch={runner_path(@investigation_host, @initial_trail, runner["id"])}
                      class="preview-result-link"
                      data-overview-open
                      aria-label={(runner["label"] || "Unnamed runner") <> " · " <> runner["id"]}
                    >{runner["label"] || "Unnamed runner"}</.link><span class="preview-caption runner-secondary">{RunnerDetail.execution_context(
                      runner
                    )} ·
                    <span class="fleet-identity" title={runner["id"]}>{String.slice(
                      runner["id"],
                      0,
                      8
                    )}</span></span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Controller contact">
                    <RunnerDetail.contact_badge value={runner["contact_status"]} /><span class="preview-caption runner-secondary"><time
                      :if={runner["last_seen_at"]}
                      datetime={runner["last_seen_at"]}
                    >{MondekWeb.EvidencePresentation.age(runner["last_seen_at"], @now)}</time><span :if={
                      !runner["last_seen_at"]
                    }>Not recorded</span></span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Collection">
                    <RunnerDetail.collection_badge value={runner["collection_status"]} /><span class="preview-caption runner-secondary">{runner[
                      "coverage"
                    ]["fresh"]} / {runner["coverage"]["active"]} results fresh</span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Inventory">
                    {runner["check_count"]} scheduled checks<span class="preview-caption runner-secondary">{RunnerDetail.source_summary(
                      runner
                    )}</span>
                  </td>
                </tr>
              </tbody>
            </table>
            <div id="runner-pagination">
              <MondekWeb.PreviewPagination.pagination
                page={@listing["page"]}
                size={@listing["page_size"]}
                total={@listing["total"]}
                label="Runner pages"
                url={fn page -> path(Map.put(@filters, "page", page)) end}
              />
            </div>
          </section>
        </section>
        <section :if={@missing_identity} class="preview-list">
          <header class="preview-heading">
            <h1 class="pf-v6-c-title pf-m-2xl">Runner not found</h1>
          </header><p class="preview-empty">This installation identity is not registered.</p>
        </section>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={@investigation_root}
          initial={@initial_trail}
          context="runners"
          back={path(@filters)}
          controller_url={@controller_url}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp runner_path(host, initial, id) do
    params = URI.decode_query(URI.parse(host).query || "")
    trail = InvestigationTrail.resolve(params, initial)
    identity = {"runner", id}

    next =
      if List.last(trail) == identity do
        Enum.drop(trail, -1)
      else
        case InvestigationTrail.open(trail, identity) do
          {:ok, entries} -> entries
          {:error, _} -> trail
        end
      end

    InvestigationTrail.path(host, next)
  end

  defdelegate path(filters), to: MondekWeb.RunnerNavigation
  defdelegate detail_path(id, return_to \\ nil), to: MondekWeb.RunnerNavigation
  defdelegate return_path(value), to: MondekWeb.BrowserNavigation
end

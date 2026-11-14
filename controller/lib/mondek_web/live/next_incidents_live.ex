# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextIncidentsLive do
  use MondekWeb, :live_view

  import MondekWeb.PreviewIncidentDetail,
    only: [severity: 1, incident_state: 1, shared_incident_badge: 1]

  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, target_label: 1]
  alias Mondek.{Monitoring, MonitoringLoss}

  alias MondekWeb.{InvestigationStack, InvestigationTrail}

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
  @filter_fields [
    {"grouping", "Grouping", "server"},
    {"status", "Status", "info"},
    {"type", "Type", "grid"},
    {"severity", "Severity", "pulse"},
    {"acknowledgement", "Acknowledgement", "shield"},
    {"opened", "Opened", "clock"},
    {"runner_id", "Runner", "terminal"}
  ]

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)
    {:ok, assign(socket, page_title: "Incidents")}
  end

  @impl true
  def handle_params(params, uri, socket) do
    host =
      URI.parse(uri).path <> if(URI.parse(uri).query, do: "?" <> URI.parse(uri).query, else: "")

    direct_full = String.ends_with?(URI.parse(uri).path, "/full")
    identity = InvestigationTrail.identity({to_string(socket.assigns.live_action), params["id"]})
    root = if direct_full, do: identity
    initial = if !direct_full && identity, do: [identity], else: []

    {:noreply,
     socket
     |> assign(
       filters: filters(params),
       filter_picker: nil,
       full_page: direct_full || !is_nil(InvestigationTrail.promoted(params, initial)),
       incident_root: root,
       initial_trail: initial,
       investigation_params: params,
       investigation_host: host,
       id: params["id"],
       kind: to_string(socket.assigns.live_action),
       investigation_selection: InvestigationTrail.selection(params, initial)
     )
     |> refresh()}
  end

  def incident_layer_path(host, kind, id) do
    uri = URI.parse(host)
    params = URI.decode_query(uri.query || "")
    initial = InvestigationTrail.initial(uri.path)
    trail = InvestigationTrail.resolve(params, initial)

    case InvestigationTrail.open(trail, {kind, id}, InvestigationTrail.root(uri.path)) do
      {:ok, trail} -> InvestigationTrail.path(host, trail)
      _ -> path(kind, id, %{}, true)
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    patch_filters(socket, %{"search" => search})
  end

  def handle_event("filter_open", %{"field" => field}, socket)
      when field in [
             "type",
             "status",
             "severity",
             "acknowledgement",
             "opened",
             "grouping",
             "runner_id"
           ] do
    value = socket.assigns.filters[field]
    label = if value in [nil, "", "all"], do: "", else: option_label(field, value)
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
      do:
        patch_filters(filter_ready(socket), %{
          field => if(field == "runner_id", do: "", else: "all")
        })

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

  def handle_event(_, _, socket), do: {:noreply, socket}

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
      for {key, label} <- picker_choices(field, value),
          key not in [nil, "", "all"],
          String.contains?(String.downcase(label), query),
          do: %{key: key, label: label, kind: ""}

    {^field, title, _} = List.keyfind(@filter_fields, field, 0)
    %{field: field, title: title, value: value, options: options}
  end

  defp picker_choices("runner_id", query),
    do: Enum.map(Mondek.ObserverFilters.options("runner_id", query), &{&1.key, &1.label})

  defp picker_choices(field, _query), do: choices(field)
  defp choices("runner_id"), do: picker_choices("runner_id", "")

  defp choices("type"), do: @types
  defp choices("grouping"), do: @groupings
  defp choices("status"), do: @statuses
  defp choices("severity"), do: @severities
  defp choices("acknowledgement"), do: @acknowledgements
  defp choices("opened"), do: @opened

  defp option_label("runner_id", key) do
    case Mondek.ObserverFilters.options("runner_id", "", {key, ""}) do
      [option] -> option.label
      [] -> key
    end
  end

  defp option_label(field, key), do: List.keyfind(choices(field), key, 0) |> elem(1)

  defp chips(filters) do
    for {field, name, _icon} <- @filter_fields,
        key = filters[field],
        key not in [nil, "", "all"],
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
    |> Map.merge(Map.take(Mondek.ObserverFilters.params(params), ["runner_id"]))
    |> Map.put("return_to", MondekWeb.BrowserNavigation.return_path(params["return_to"]))
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
      "/incidents/" <>
        kind <>
        "/" <>
        URI.encode(id, &URI.char_unreserved?/1) <>
        if(full_page, do: "/full", else: ""),
      filters
    )
  end

  defdelegate return_path(value), to: MondekWeb.BrowserNavigation

  defp list_path(filters), do: with_query("/incidents", filters)

  defp with_query(path, params) do
    query =
      params
      |> Enum.reject(fn {key, value} ->
        is_nil(value) ||
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
    if socket.assigns.full_page, do: assign(socket, now: now), else: refresh_listing(socket, now)
  end

  def open_summary(now) do
    listing = incident_listing(filters(%{}), now)
    %{rows: Enum.take(listing.rows, 4), total: listing.totals["health"] + listing.totals["loss"]}
  end

  defp refresh_listing(%{assigns: %{filters: filters}} = socket, now) do
    assign(
      socket,
      Map.merge(incident_listing(filters, now), %{now: now, filter_fields: @filter_fields})
    )
  end

  defp incident_listing(filters, now) do
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

    %{
      rows: rows,
      page: page,
      totals: %{"health" => health && health.total, "loss" => loss && loss["total"]},
      shown: %{"health" => length(health_rows), "loss" => length(loss_rows)}
    }
  end

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
      data-selection={@investigation_selection}
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "incidents-heading")}
    >
      <MondekWeb.PreviewLayouts.navigation active={:incidents} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <.listing :if={!@full_page} {assigns} />
        <section
          :if={
            @full_page && !@incident_root &&
              !InvestigationTrail.promoted(@investigation_params, @initial_trail)
          }
          class="preview-list"
        >
          <header class="preview-heading">
            <h1 id="incidents-heading" tabindex="-1">Incident unavailable</h1>
          </header>
          <p class="preview-empty">This incident identity is not available.</p>
          <div class="preview-recorded-actions">
            <.link navigate="/incidents">Browse incidents</.link>
          </div>
        </section>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={@incident_root}
          initial={@initial_trail}
          context={if @incident_root, do: {:incident_page, @incident_root}, else: :incidents}
          back={list_path(@filters)}
        />
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
        <.link
          :if={@filters["return_to"]}
          navigate={@filters["return_to"]}
          class="pf-v6-c-button pf-m-link"
        >Back to previous view</.link>
      </header>
      <div class="preview-incident-search">
        <MondekWeb.PreviewFilters.filter_picker
          picker={@filter_picker}
          chips={chips(@filters)}
          fields={@filter_fields}
          search={@filters["search"]}
          remove={
            fn field ->
              list_path(
                Map.merge(@filters, %{
                  field => if(field == "runner_id", do: "", else: "all"),
                  "page" => "1"
                })
              )
            end
          }
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
        <MondekWeb.PreviewPagination.pagination
          :if={@page}
          page={@page.page}
          size={@page.size}
          total={@page.total}
          label="Incident pages"
          url={fn p -> list_path(Map.put(@filters, "page", to_string(p))) end}
        />
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
end

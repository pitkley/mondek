# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextIncidentsLive do
  use MondekWeb, :live_view

  import MondekWeb.PreviewIncidentDetail,
    only: [severity: 1, incident_state: 1, shared_incident_badge: 1]

  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, target_label: 1]
  alias Mondek.{Maintenance, Monitoring, MonitoringLoss}

  alias MondekWeb.{
    PreviewNavigation,
    PreviewIncidentControls,
    PanelStack,
    PreviewDetail,
    PreviewIncidentDetail
  }

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
    full_page = String.ends_with?(URI.parse(uri).path, "/full")
    root = if full_page, do: {to_string(socket.assigns.live_action), params["id"]}

    {:noreply,
     socket
     |> assign(
       filters: filters(params),
       filter_picker: nil,
       full_page: full_page,
       incident_root: root
     )
     |> setup_detail(
       params,
       if(root, do: path(elem(root, 0), elem(root, 1), filters(params), true))
     )
     |> refresh()}
  end

  def setup_detail(socket, params, host_path) do
    root = socket.assigns[:incident_root]
    selection = if host_path, do: parse_incident(params["incident"])
    {kind, id} = selection || root || {to_string(socket.assigns.live_action), params["id"]}
    detail_filters = detail_filters(params)
    full_detail = root != nil && selection == nil && detail_filters["result"] == nil

    socket =
      if {socket.assigns[:kind], socket.assigns[:id]} != {kind, id} ||
           !Map.has_key?(socket.assigns, :control_review) do
        reset_detail_controls(socket)
      else
        socket
      end

    assign(socket,
      id: id,
      kind: kind,
      incident_host: host_path,
      incident_selection: selection,
      full_detail: full_detail,
      detail_filters: detail_filters
    )
  end

  defp parse_incident(value) when is_binary(value) do
    with [kind, id] when kind in ["health", "loss"] <- String.split(value, ":", parts: 2),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {kind, id}
    else
      _ -> nil
    end
  end

  defp parse_incident(_), do: nil

  defp reset_detail_controls(socket) do
    assign(socket,
      control_review: nil,
      control_draft: %{},
      control_replacing: false,
      control_feedback: nil,
      delivery_feedback: nil,
      retry_drafts: %{}
    )
  end

  def incident_layer_path(host, kind, id),
    do: detail_path(host, %{"incident" => "#{kind}:#{id}"})

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event(
        "filter_incident_detail",
        %{"notification_status" => value},
        %{assigns: %{incident: %{}}} = socket
      ) do
    {:noreply, push_patch(socket, to: delivery_filter_path(socket.assigns, value))}
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
      ),
      do:
        {:noreply,
         assign(socket,
           control_review: PreviewIncidentControls.revision(incident),
           control_feedback: nil
         )}

  def handle_event(
        "toggle_acknowledgement_replacement",
        _,
        %{assigns: %{incident: %{} = incident, control_replacing: replacing}} = socket
      ) do
    if Monitoring.acknowledgement_active?(incident),
      do:
        {:noreply,
         assign(socket, control_replacing: !replacing, control_draft: %{}, control_feedback: nil)},
      else: {:noreply, socket}
  end

  def handle_event("edit_acknowledgement", params, %{assigns: %{control_review: %{}}} = socket),
    do: {:noreply, assign(socket, control_draft: PreviewIncidentControls.draft(params))}

  def handle_event(
        "save_acknowledgement",
        params,
        %{assigns: %{control_review: %{} = review, id: id, kind: kind}} = socket
      ),
      do: apply_control_result(socket, PreviewIncidentControls.save(kind, id, review, params))

  def handle_event(
        "end_acknowledgement",
        _,
        %{assigns: %{control_review: %{} = review, id: id, kind: kind, incident: %{} = incident}} =
          socket
      ),
      do: apply_control_result(socket, PreviewIncidentControls.finish(kind, id, review, incident))

  def handle_event(
        "retry_delivery",
        %{"_id" => id, "reason" => reason},
        %{assigns: %{detail: %{} = detail}} = socket
      ),
      do:
        apply_control_result(
          socket,
          PreviewIncidentControls.retry(detail, socket.assigns.retry_drafts, id, reason)
        )

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp apply_control_result(socket, {changes, refresh?}) do
    socket = assign(socket, changes)
    {:noreply, if(refresh?, do: refresh_detail(socket, Monitoring.now()), else: socket)}
  end

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
         is_binary(uri.path) do
      params = URI.decode_query(uri.query || "")
      selection = if parse_incident(params["incident"]), do: params["incident"]
      detail = Map.put(detail_filters(params), "incident", selection)

      cond do
        String.starts_with?(uri.path, "/next/maintenance/") ->
          MondekWeb.MaintenanceLive.preview_return_path(uri.path, params)

        Regex.match?(~r"\A/next/(?:coverage|expected)/[a-f0-9]{64}(?:/full)?\z", uri.path) ->
          filter_module =
            if String.starts_with?(uri.path, "/next/coverage/"),
              do: Mondek.CoverageFilters,
              else: Mondek.OverviewFilters

          runner_page = params["runner_page"]

          query =
            if is_binary(runner_page) && Regex.match?(~r"\A[1-9][0-9]{0,6}\z", runner_page),
              do: %{"runner_page" => runner_page},
              else: %{}

          query = Map.put(query, "observer_result", valid_result_id(params["observer_result"]))
          with_query(uri.path, Map.merge(filter_module.params(params), query))

        result_host?(uri.path) && selection ->
          filter_module =
            if String.starts_with?(uri.path, "/next/checks"),
              do: Mondek.ChecksFilters,
              else: Mondek.OverviewFilters

          with_query(uri.path, Map.merge(filter_module.params(params), detail))

        Regex.match?(~r"\A/next/incidents/(health|loss)/[0-9a-f-]{36}(?:/full)?\z", uri.path) ->
          with_query(uri.path, Map.merge(filters(params), detail))

        true ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil

  defp detail_filters(params) do
    %{
      "result" => valid_result_id(params["result"]),
      "from_shared" => if(params["from_shared"] == "1", do: "1"),
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

  defp valid_result_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp list_path(filters), do: with_query("/next/incidents", filters)

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
    socket = if socket.assigns.full_page, do: socket, else: refresh_listing(socket, now)

    socket
    |> refresh_detail(now)
    |> refresh_root(now)
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

  def refresh_detail(%{assigns: %{kind: kind, id: id}} = socket, now)
      when kind in ["health", "loss"] and is_binary(id) do
    filters = socket.assigns.detail_filters
    {detail, incident} = load_detail(kind, id, now, filters)

    review =
      socket.assigns.control_review ||
        if incident && incident["status"] == "open",
          do: PreviewIncidentControls.revision(incident)

    assign(socket,
      now: now,
      kind: kind,
      detail: detail,
      incident: incident,
      maintenance_windows: active_maintenance(kind, incident, now),
      result_panel:
        if(filters["result"],
          do: MondekWeb.PreviewResult.load(filters["result"], now)
        ),
      control_review: review
    )
    |> load_shared_rear_detail()
  end

  def refresh_detail(socket, _now), do: assign(socket, incident: nil, detail: nil)

  defp load_detail("health", id, now, filters) do
    detail = health_detail(id, now, filters)
    {detail, detail && detail["incident"]}
  end

  defp load_detail("loss", id, now, filters) do
    detail = MonitoringLoss.detail(id, now, %{"members_page" => filters["member_page"]})
    {detail, detail}
  end

  defp refresh_root(%{assigns: %{incident_root: {kind, id}, full_detail: false}} = socket, now) do
    assigns = socket.assigns
    filters = Map.drop(assigns.detail_filters, ~w(result from_shared))
    {detail, incident} = load_detail(kind, id, now, filters)

    root =
      assigns
      |> rear_panel(kind, detail, incident, assigns.incident_host, [])
      |> assign(
        full_page: true,
        full_detail: true,
        incident_selection: nil,
        detail_filters: filters,
        result_panel: nil,
        maintenance_windows: active_maintenance(kind, incident, now)
      )

    assign(socket, :root_panel, root)
  end

  defp refresh_root(socket, _now), do: assign(socket, :root_panel, nil)

  defp health_detail(id, now, filters) do
    Monitoring.incident_detail(id, now, %{
      "page" => filters["member_page"],
      "state" => filters["contributors"],
      "contradiction_page" => filters["healthy_page"],
      "notification_status" => filters["notification_status"],
      "notification_page" => filters["notification_page"]
    })
  end

  defp load_shared_rear_detail(socket) do
    detail =
      with %{
             full_detail: false,
             kind: "health",
             incident: %{"condition_incident_id" => id},
             detail_filters: %{"from_shared" => "1"} = filters,
             now: now
           } <- socket.assigns,
           true <- is_binary(id) do
        health_detail(id, now, filters)
      else
        _ -> nil
      end

    assign(socket, :shared_rear_detail, detail)
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
      data-selection={if @id && !@full_detail, do: "#{@kind}-#{@id}-#{@detail_filters["result"]}"}
      data-panel-heading={if @full_page, do: "incident-heading", else: "incidents-heading"}
    >
      <MondekWeb.PreviewLayouts.navigation active={:incidents} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <.listing :if={!@full_page} {assigns} />
        <div :if={@full_page} id="incident-page-background" inert={!@full_detail}>
          <.detail {if @full_detail, do: assigns, else: @root_panel} full_page={true} />
        </div>
        <.detail
          :if={@id && !@full_detail}
          {assigns}
          full_page={false}
          id_prefix={if @full_page, do: "overlay-", else: ""}
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

  def delivery_filter_path(assigns, value) do
    detail_path(current_detail_path(assigns), %{
      "notification_status" => choice(value, @delivery_statuses),
      "notification_page" => "1"
    })
  end

  defp current_detail_path(%{incident_host: host} = assigns) when is_binary(host) do
    selection = assigns.incident_selection

    detail_path(
      host,
      Map.put(
        assigns.detail_filters,
        "incident",
        selection && Enum.join(Tuple.to_list(selection), ":")
      )
    )
  end

  defp current_detail_path(assigns) do
    path(assigns.kind, assigns.id, Map.merge(assigns.filters, assigns.detail_filters))
  end

  defp detail_back_path(%{full_page: true} = assigns), do: list_path(assigns.filters)

  defp detail_back_path(%{incident_root: {_, _}} = assigns) do
    detail_path(current_detail_path(assigns), %{
      "incident" => nil,
      "result" => nil,
      "from_shared" => nil
    })
  end

  defp detail_back_path(assigns), do: assigns.incident_host || list_path(assigns.filters)

  def detail(assigns) do
    assigns =
      assigns
      |> assign_new(:id_prefix, fn -> "" end)
      |> assign(
        back: detail_back_path(assigns),
        current: current_detail_path(assigns),
        title: detail_title(assigns.kind, assigns.detail, assigns.incident),
        delivery_statuses: @delivery_statuses
      )

    assigns =
      assigns
      |> assign_new(:host_fallback, fn -> [] end)
      |> assign(:ancestors, Map.get(assigns, :host_ancestors, []) ++ panel_ancestors(assigns))

    host_target =
      assigns[:host_target] ||
        if !assigns.full_page && assigns[:incident_root] do
          {kind, id} = assigns.incident_root
          %{identity: {kind, id}, path: assigns.back}
        end

    assigns = assign(assigns, :earlier_targets, List.wrap(host_target) ++ assigns.ancestors)

    ~H"""
    <MondekWeb.PanelStack.rear_cards
      entries={@ancestors}
      card_class="preview-incident-panel pf-v6-c-card"
    >
      <:fallback :let={ancestor}>
        <%= if Map.has_key?(ancestor, :panel) do %>
          <div class="pf-v6-c-card__body">
            <.incident_panel_tools {ancestor.panel} />
            <.incident_panel_body {ancestor.panel} />
          </div>
        <% else %>
          {render_slot(@host_fallback, ancestor)}
        <% end %>
      </:fallback>
    </MondekWeb.PanelStack.rear_cards>
    <PreviewDetail.surface
      id={if @full_page, do: "incident-page", else: "overview-panel"}
      dialog={!@full_page}
      path={if !@full_page, do: @current}
      heading_id={
        if @detail_filters["result"] && !@full_page,
          do: "overview-panel-title",
          else: @id_prefix <> "incident-heading"
      }
    >
      <.incident_panel_tools {assigns} />
      <%= if @detail_filters["result"] && !@full_page do %>
        <MondekWeb.PreviewResultDetail.detail
          :if={@result_panel}
          panel={@result_panel}
          now={@now}
          configuration_path={"/checks/" <> @result_panel.selected["id"] <> "?" <> URI.encode_query(%{"return_to" => @current})}
          incident_path={fn id -> incident_destination(@current, @earlier_targets, id, false) end}
          full_result_path={full_result_path(@current, @detail_filters["result"])}
          peer_path={fn id -> result_layer_path(@current, @earlier_targets, id) end}
        />
        <h2 :if={!@result_panel} id="overview-panel-title" tabindex="-1">Result unavailable</h2>
      <% else %>
        <.incident_panel_body {assigns} />
      <% end %>
    </PreviewDetail.surface>
    """
  end

  defp full_result_path(current, id) do
    PreviewNavigation.path(
      %{"incident_return" => detail_path(current, %{"result" => nil})},
      :result_page,
      id
    )
  end

  defp incident_panel_tools(assigns) do
    ~H"""
    <div class="preview-panel-tools">
      <.link
        patch={if @ancestors == [], do: @back, else: List.last(@ancestors).path}
        data-overview-close={!@full_page}
        class="pf-v6-c-button pf-m-link"
      >← {cond do
        @ancestors != [] -> "Back one level"
        @back == list_path(@filters) -> "Back to incidents"
        true -> "Back"
      end}</.link>
      <nav :if={@ancestors != []} class="preview-panel-stack" aria-label="Investigation trail">
        <.link :for={ancestor <- @ancestors} patch={ancestor.path}>
          <strong>{ancestor.kind}</strong>
          <span>{ancestor.title}</span>
        </.link>
      </nav>
      <.link
        :if={!@full_page && @detail_filters["result"]}
        navigate={full_result_path(@current, @detail_filters["result"])}
        class="pf-v6-c-button pf-m-link"
      >Open as page</.link>
      <.link
        :if={@incident && !@full_page && !@detail_filters["result"]}
        patch={
          if @incident_host && !assigns[:incident_root],
            do: nil,
            else: path(@kind, @id, Map.merge(@filters, @detail_filters), true)
        }
        navigate={
          if @incident_host && !assigns[:incident_root], do: path(@kind, @id, @detail_filters, true)
        }
        class="pf-v6-c-button pf-m-link"
      >Open as page</.link>
    </div>
    """
  end

  defp incident_panel_body(assigns) do
    ~H"""
    <PreviewIncidentDetail.body
      incident={@incident}
      detail={@detail}
      kind={@kind}
      title={@title}
      type_label={type_label(@kind)}
      now={@now}
      current={@current}
      id_prefix={@id_prefix}
      full_page={@full_page}
      control_review={@control_review}
      control_draft={@control_draft}
      control_replacing={@control_replacing}
      control_feedback={@control_feedback}
      delivery_feedback={@delivery_feedback}
      retry_drafts={@retry_drafts}
      maintenance_windows={@maintenance_windows}
      detail_filters={@detail_filters}
      delivery_statuses={@delivery_statuses}
      result_path={fn id -> result_layer_path(@current, @earlier_targets, id) end}
      incident_path={
        fn id, shared? -> incident_destination(@current, @earlier_targets, id, shared?) end
      }
      expected_path={fn id -> evidence_path(:expected, id, @current) end}
      filter_path={fn changes -> detail_path(@current, changes) end}
      page_path={fn param, page -> detail_path(@current, %{param => to_string(page)}) end}
    />
    """
  end

  defp rear_panel(assigns, kind, detail, incident, current, ancestors) do
    assign(assigns,
      kind: kind,
      detail: detail,
      incident: incident,
      current: current,
      id: incident && incident["id"],
      title: detail_title(kind, detail, incident),
      detail_filters: detail_filters(URI.decode_query(URI.parse(current).query || "")),
      ancestors: ancestors,
      earlier_targets: ancestors,
      control_review:
        if(incident && incident["status"] == "open",
          do: PreviewIncidentControls.revision(incident)
        ),
      control_draft: %{},
      control_replacing: false,
      control_feedback: nil,
      delivery_feedback: nil,
      retry_drafts: %{},
      maintenance_windows:
        if(incident == assigns.incident, do: assigns.maintenance_windows, else: [])
    )
  end

  defp panel_ancestors(%{full_page: true}), do: []

  defp panel_ancestors(assigns) do
    parent_id = get_in(assigns.incident, ["condition_incident_id"])

    shared =
      if parent_id && assigns[:incident_root] != {"health", parent_id} &&
           assigns.detail_filters["from_shared"] == "1" do
        detail = assigns.shared_rear_detail
        incident = detail && detail["incident"]

        current =
          detail_path(
            related_incident_path(assigns.current, parent_id),
            Map.drop(assigns.detail_filters, ~w(result from_shared))
          )

        panel = rear_panel(assigns, "health", detail, incident, current, [])

        [
          %{
            kind: "Shared incident",
            identity: {"health", parent_id},
            title: panel.title,
            path: current,
            panel: panel
          }
        ]
      else
        []
      end

    if assigns.detail_filters["result"] &&
         !(assigns[:incident_root] && !assigns.incident_selection) do
      shared ++
        [
          %{
            kind:
              if(get_in(assigns.detail, ["contributions"]),
                do: "Shared incident",
                else: "Incident"
              ),
            identity: {assigns.kind, assigns.id},
            title: assigns.title,
            path: detail_path(assigns.current, %{"result" => nil}),
            panel:
              rear_panel(
                assigns,
                assigns.kind,
                assigns.detail,
                assigns.incident,
                detail_path(assigns.current, %{"result" => nil}),
                shared
              )
          }
        ]
    else
      shared
    end
  end

  defp detail_title(_, _, nil), do: "Incident unavailable"
  defp detail_title("loss", _, incident), do: title("loss", incident)

  defp detail_title("health", detail, incident),
    do:
      incident["label"] || get_in(detail, ["assignment", "label"]) ||
        get_in(detail, ["stream", "label"]) || "Health incident"

  defp result_layer_path(current, earlier, id),
    do: PanelStack.destination(earlier, {:result, id}, detail_path(current, %{"result" => id}))

  defp incident_destination(current, earlier, id, from_shared?),
    do:
      PanelStack.destination(
        earlier,
        {"health", id},
        related_incident_path(current, id, from_shared?)
      )

  defp related_incident_path(current, id, from_shared? \\ false) do
    uri = URI.parse(current)
    params = URI.decode_query(uri.query || "")

    parent =
      if String.starts_with?(uri.path, "/next/incidents/") && String.ends_with?(uri.path, "/full"),
        do: List.last(Enum.drop(String.split(uri.path, "/"), -1))

    changes = %{"result" => nil, "from_shared" => if(from_shared?, do: "1")}

    if result_host?(uri.path) || parent do
      selection = if id != parent, do: "health:#{id}"
      detail_path(current, Map.put(changes, "incident", selection))
    else
      query =
        if from_shared?,
          do: Map.merge(filters(params), detail_filters(params)),
          else: filters(params)

      path("health", id, Map.merge(query, changes))
    end
  end

  defp result_host?(path) do
    path == "/next" ||
      Regex.match?(~r"\A/next/(?:checks|results)/[a-f0-9-]{36}(?:/full)?\z", path)
  end

  defp detail_path(current, changes) do
    uri = URI.parse(current)
    with_query(uri.path, Map.merge(URI.decode_query(uri.query || ""), changes))
  end

  defp evidence_path(kind, id, current),
    do: MondekWeb.PreviewNavigation.path(%{"incident_return" => current}, kind, id)
end

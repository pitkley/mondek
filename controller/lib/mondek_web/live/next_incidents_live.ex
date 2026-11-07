# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextIncidentsLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias Mondek.{Monitoring, MonitoringLoss}

  @types [{"all", "All types"}, {"health", "Health failure"}, {"loss", "Monitoring loss"}]
  @statuses [{"open", "Open"}, {"closed", "Closed"}, {"all", "Any status"}]
  @filter_fields [{"status", "Status", "check"}, {"type", "Type", "pulse"}]

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)
    {:ok, assign(socket, page_title: "Incidents preview")}
  end

  @impl true
  def handle_params(params, _, socket) do
    {:noreply,
     socket
     |> assign(
       filters: filters(params),
       filter_picker: nil,
       id: params["id"],
       member_page: number(params["member_page"])
     )
     |> refresh()}
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
      when field in ["type", "status"] do
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
      for {key, label} <- choices(field),
          key != "all",
          String.contains?(String.downcase(label), query),
          do: %{key: key, label: label, kind: ""}

    {^field, title, _} = List.keyfind(@filter_fields, field, 0)
    %{field: field, title: title, value: value, options: options}
  end

  defp choices("type"), do: @types
  defp choices("status"), do: @statuses

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
      "status" => choice(params["status"], @statuses),
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

  def path(kind, id, filters \\ %{}) when kind in ["health", "loss"] do
    with_query(
      "/next/incidents/" <> kind <> "/" <> URI.encode(id, &URI.char_unreserved?/1),
      filters
    )
  end

  def return_path(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.authority == nil && uri.fragment == nil &&
         is_binary(uri.path) &&
         Regex.match?(~r"\A/next/incidents/(health|loss)/[0-9a-f-]{36}\z", uri.path) do
      params = URI.decode_query(uri.query || "")
      with_query(uri.path, Map.put(filters(params), "member_page", number(params["member_page"])))
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil

  defp list_path(filters), do: with_query("/next/incidents", filters)

  defp with_query(path, params) do
    query =
      params
      |> Enum.reject(fn {key, value} ->
        {key, value} in [{"type", "all"}, {"status", "open"}, {"page", "1"}, {"member_page", "1"}]
      end)
      |> URI.encode_query()

    if query == "", do: path, else: path <> "?" <> query
  end

  defp refresh(%{assigns: %{live_action: :index, filters: filters}} = socket) do
    now = Monitoring.now()
    type = filters["type"]

    domain =
      filters
      |> Map.put("page", if(type == "all", do: "1", else: filters["page"]))
      |> Map.put("page_size", "25")

    health = if type != "loss", do: Monitoring.list_incidents(domain, now)
    loss = if type != "health", do: MonitoringLoss.list(domain, now)
    health_rows = if health, do: Enum.map(health.items, &row("health", &1, now)), else: []
    loss_rows = if loss, do: Enum.map(loss["items"], &row("loss", &1, now)), else: []

    rows =
      if type == "all" do
        Enum.sort_by(health_rows ++ loss_rows, fn row ->
          {row.status != "open", row.acknowledged, row.opened_at, row.kind, row.id}
        end)
      else
        health_rows ++ loss_rows
      end

    page =
      case type do
        "health" -> %{page: health.page, size: health.page_size, total: health.total}
        "loss" -> %{page: loss["page"], size: loss["page_size"], total: loss["total"]}
        "all" -> nil
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

  defp refresh(socket) do
    %{live_action: action, id: id, member_page: page} = socket.assigns
    now = Monitoring.now()

    {kind, detail, incident} =
      case action do
        :health ->
          detail = Monitoring.incident_detail(id, now, %{"page" => page})
          {"health", detail, detail && detail["incident"]}

        :loss ->
          detail = MonitoringLoss.detail(id, now, %{"members_page" => page})
          {"loss", detail, detail}
      end

    assign(socket, now: now, kind: kind, detail: detail, incident: incident)
  end

  defp row(kind, incident, now) do
    %{
      kind: kind,
      id: incident["id"],
      title: title(kind, incident),
      context: context(incident),
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
      if(incident["member_count"], do: count(incident["member_count"], "affected result"))
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
    <div class="preview-shell" id="incidents-preview">
      <MondekWeb.PreviewLayouts.navigation active={:incidents} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <.listing :if={@live_action == :index} {assigns} />
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
      <div class="preview-table-group">
        <p :if={@rows == []} class="preview-empty">No incidents match these filters.</p>
        <table
          :if={@rows != []}
          class="pf-v6-c-table pf-m-compact preview-table"
          aria-label="Incidents"
        >
          <thead class="pf-v6-c-table__thead">
            <tr class="pf-v6-c-table__tr">
              <th scope="col" class="pf-v6-c-table__th">Incident</th>
              <th scope="col" class="pf-v6-c-table__th">Type</th>
              <th scope="col" class="pf-v6-c-table__th">Status</th>
              <th scope="col" class="pf-v6-c-table__th">Opened</th>
            </tr>
          </thead>
          <tbody class="pf-v6-c-table__tbody">
            <tr
              :for={row <- @rows}
              class="pf-v6-c-table__tr"
              id={"preview-incident-" <> row.kind <> "-" <> row.id}
            >
              <td class="pf-v6-c-table__td" data-label="Incident">
                <.link patch={path(row.kind, row.id, @filters)} class="preview-result-link">{row.title}</.link>
                <span :if={row.context != ""} class="preview-caption">{row.context}</span>
              </td>
              <td class="pf-v6-c-table__td" data-label="Type">{type_label(row.kind)}</td>
              <td class="pf-v6-c-table__td" data-label="Status">
                <.incident_state
                  health={row.health}
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
            Map.put(assigns.filters, "member_page", assigns.member_page)
          ),
        title: detail_title(assigns.kind, assigns.detail, assigns.incident)
      )

    ~H"""
    <section class="preview-list" aria-labelledby="incident-heading">
      <header class="preview-incident-intro">
        <.link patch={@back}>← Back to incidents</.link>
        <p :if={@incident} class="preview-caption">
          {type_label(@kind)}<span :if={@incident["scope_kind"] == "coverage"}> · {@incident[
            "source_id"
          ]}</span>
        </p>
        <h1 id="incident-heading" class="pf-v6-c-title pf-m-2xl">{@title}</h1>
        <div :if={@incident} class="preview-incident-meta">
          <.incident_state
            health={@incident["health"]}
            status={@incident["status"]}
            acknowledged={Monitoring.acknowledgement_active?(@incident, @now)}
          />
          <span>Opened <time datetime={@incident["opened_at"]}>{time(@incident["opened_at"])}</time></span>
          <span :if={@incident["closed_at"]}>Ended
          <time datetime={@incident["closed_at"]}>{time(@incident["closed_at"])}</time></span>
        </div>
      </header>
      <p :if={!@incident} class="preview-empty">This incident may have been removed by retention.</p>
      <.health_evidence :if={@incident && @kind == "health"} detail={@detail} current={@current} />
      <.loss_evidence :if={@incident && @kind == "loss"} detail={@detail} current={@current} />
      <footer :if={@incident} class="preview-incident-footer">
        <a href={legacy_path(@kind, @id, @current)}>Open existing incident controls and history</a>
      </footer>
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
    <section class="preview-table-group">
      <h2 class="preview-section-heading">
        {if @detail["contributions"], do: "Contributing results", else: "Recorded failure"}
      </h2>
      <div :if={!@detail["contributions"]} class="preview-incident-evidence">
        <p :if={@detail["stream"]}>
          {target_label(@detail["stream"]["target"])} · {@detail["stream"]["environment_label"] ||
            @detail["stream"]["environment"] || "Unscoped"}
        </p>
        <p :if={@measured}>{@measured["summary"]}</p>
        <p :if={!@measured}>The recorded measurement details are unavailable.</p>
        <p :if={@measured && @measured_at} class="preview-caption">
          Measured {time(@measured_at)}
        </p>
        <details :if={@measured && @measured["details"] not in [nil, ""]}>
          <summary>Recorded measurement details</summary>
          <pre class="preview-findings">{@measured["details"]}</pre>
        </details>
        <a
          :if={@incident["stream_id"]}
          href={evidence_path(:result, @incident["stream_id"], @current)}
        >Open current result evidence</a>
      </div>
      <div :for={contribution <- @detail["contributions"] || []} class="preview-incident-evidence">
        <h3>
          {get_in(contribution, ["stream", "label"]) || get_in(contribution, ["assignment", "label"])}
        </h3>
        <p>
          {badge_text(contribution["last_failure_health"])} · {badge_text(
            contribution["contribution_state"]
          )}
        </p>
        <p :if={contribution["measured_result"]}>{contribution["measured_result"]["summary"]}</p>
        <a
          :if={contribution["incident"]["stream_id"]}
          href={evidence_path(:result, contribution["incident"]["stream_id"], @current)}
        >Open current result evidence</a>
      </div>
      <.member_pages
        :if={@detail["contribution_page"]}
        listing={@detail["contribution_page"]}
        current={@current}
      />
    </section>
    """
  end

  defp loss_evidence(assigns) do
    ~H"""
    <section class="preview-table-group">
      <h2 class="preview-section-heading">
        {if @detail["status"] == "open", do: "Affected results", else: "Last affected results"}
      </h2>
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
        <h3>{member["label"] || target_label(member["target"])}</h3>
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
      <.member_pages listing={@detail["members"]} current={@current} />
    </section>
    """
  end

  defp member_pages(assigns) do
    ~H"""
    <nav
      :if={@listing["total"] > @listing["page_size"]}
      class="preview-pager"
      aria-label="Affected result pages"
    >
      <.page_links
        page={@listing["page"]}
        size={@listing["page_size"]}
        total={@listing["total"]}
        url={
          fn p ->
            uri = URI.parse(@current)

            with_query(
              uri.path,
              Map.put(URI.decode_query(uri.query || ""), "member_page", to_string(p))
            )
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

  defp incident_state(assigns) do
    ~H"""
    <span class="preview-incident-state">
      <span
        :if={@health && @status == "open"}
        class={["pf-v6-c-label", @health == "CRIT" && "pf-m-red", @health == "WARN" && "pf-m-orange"]}
      >
        <span class="pf-v6-c-label__content">{badge_text(@health)}</span>
      </span>
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

  defp legacy_path("health", id, current),
    do: with_query("/incidents/" <> id, %{"return_to" => current})

  defp legacy_path("loss", id, _), do: "/monitoring-incidents/" <> id
end

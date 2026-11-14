# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias Mondek.{ChecksFilters, Coverage, CoverageFilters, Inspection, Monitoring, OverviewFilters}
  alias MondekWeb.{NextIncidentsLive, PreviewCoverage, PreviewDetail, PreviewIncidentControls}

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       filters: %{},
       selected_id: nil,
       panel: nil,
       filter_picker: nil,
       filter_chips: []
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {list_action, filter_module} =
      case socket.assigns.live_action do
        action when action in [:checks, :checks_result, :checks_result_page] ->
          {:checks, ChecksFilters}

        action when action in [:coverage, :coverage_result, :coverage_diagnostic] ->
          {:coverage, CoverageFilters}

        _ ->
          {:index, OverviewFilters}
      end

    filters = filter_module.params(params)
    incident_return = NextIncidentsLive.return_path(params["incident_return"])

    chips =
      for {field, name} <- filter_module.fields(),
          {key, _kind} = selection <- List.wrap(filter_module.selected(filters, field)) do
        label =
          case filter_module.options(field, "", selection) do
            [option] -> option.label
            [] -> key
          end

        %{field: field, name: name, label: label}
      end

    {:noreply,
     socket
     |> assign(
       coverage_full:
         socket.assigns.live_action in [:expected, :coverage_result, :coverage_diagnostic] &&
           String.ends_with?(URI.parse(uri).path, "/full"),
       filters: filters,
       filter_module: filter_module,
       list_action: list_action,
       selected_id: params["id"],
       runner_page: page_param(params["runner_page"]),
       observer_result: uuid_param(params["observer_result"]),
       incident_return: incident_return,
       filter_chips: chips,
       filter_picker: nil
     )
     |> NextIncidentsLive.setup_detail(
       params,
       if socket.assigns.live_action != :expected do
         path(
           Map.put(filters, "incident_return", incident_return),
           socket.assigns.live_action,
           params["id"]
         )
       end
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("search", params, socket) do
    search = if is_binary(params["search"]), do: String.slice(params["search"], 0, 200), else: ""
    # Form recovery after reconnect must preserve a bookmarked panel and page.
    if search == (socket.assigns.filters["search"] || "") do
      {:noreply, socket}
    else
      filter_module = socket.assigns.filter_module

      filters =
        socket.assigns.filters
        |> filter_module.reset_pages()
        |> Map.put("search", search)
        |> filter_module.params()

      {:noreply, push_patch(socket, to: path(filters, socket.assigns.list_action), replace: true)}
    end
  end

  def handle_event("filter_open", params, socket) do
    field = params["field"]

    filter_module = socket.assigns.filter_module

    if List.keymember?(filter_module.fields(), field, 0) do
      chip = Enum.find(socket.assigns.filter_chips, &(&1.field == field))
      draft = %{picker(filter_module, field, "") | value: if(chip, do: chip.label, else: "")}
      {:noreply, assign(socket, filter_picker: draft)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter_remove_edit", _, socket) do
    case socket.assigns.filter_picker do
      %{field: field} ->
        filter_module = socket.assigns.filter_module

        filters =
          socket.assigns.filters
          |> filter_module.remove(field)
          |> filter_module.reset_pages()

        {:noreply,
         socket
         |> push_patch(to: path(filters, socket.assigns.list_action))
         |> show_filter_choices()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket),
    do: {:noreply, show_filter_choices(socket)}

  def handle_event("filter_close", _, socket),
    do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(event, %{"search" => query}, socket)
      when event in ["filter_query", "filter_first"] and is_binary(query) do
    case socket.assigns.filter_picker do
      nil ->
        {:noreply, socket}

      %{field: field} ->
        draft =
          picker(
            socket.assigns.filter_module,
            field,
            String.slice(String.replace(query, <<0>>, ""), 0, 200)
          )

        case {event, draft.options} do
          {"filter_first", [option | _]} -> choose_filter(socket, field, option)
          _ -> {:noreply, assign(socket, filter_picker: draft)}
        end
    end
  end

  def handle_event("filter_select", %{"key" => key, "kind" => kind}, socket) do
    with %{field: field, options: options} <- socket.assigns.filter_picker,
         option when not is_nil(option) <-
           Enum.find(options, &(&1.key == key and &1.kind == kind)) do
      choose_filter(socket, field, option)
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(event, _, socket)
      when event in ["filter_query", "filter_first", "filter_select"],
      do: {:noreply, socket}

  def handle_event(event, _, %{assigns: %{incident_selection: nil}} = socket)
      when event in ~w(filter_incident_detail review_control toggle_acknowledgement_replacement
                       edit_acknowledgement save_acknowledgement end_acknowledgement retry_delivery),
      do: {:noreply, socket}

  def handle_event(
        "filter_incident_detail",
        %{"notification_status" => value},
        %{assigns: %{incident: %{}}} = socket
      ) do
    {:noreply,
     push_patch(socket, to: NextIncidentsLive.delivery_filter_path(socket.assigns, value))}
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

    {:noreply,
     if(refresh?, do: NextIncidentsLive.refresh_detail(socket, Monitoring.now()), else: socket)}
  end

  defp choose_filter(socket, field, option) do
    filter_module = socket.assigns.filter_module

    filters =
      socket.assigns.filters
      |> filter_module.put(field, {option.key, option.kind})
      |> filter_module.reset_pages()

    {:noreply,
     socket |> push_patch(to: path(filters, socket.assigns.list_action)) |> show_filter_choices()}
  end

  defp show_filter_choices(socket) do
    socket
    |> assign(filter_picker: nil)
    |> push_event("preview-filter-ready", %{})
  end

  defp picker(filter_module, field, query) do
    %{
      field: field,
      title: Map.new(filter_module.fields())[field],
      value: query,
      options: filter_module.options(field, query)
    }
  end

  defp refresh(%{assigns: %{live_action: action} = assigns} = socket)
       when action in [:result_page, :checks_result_page] do
    now = Monitoring.now()
    panel = MondekWeb.PreviewResult.load(assigns.selected_id, now) || %{kind: :not_found}
    filters = Map.put(assigns.filters, "incident_return", assigns.incident_return)

    socket
    |> NextIncidentsLive.refresh_detail(now)
    |> assign(
      now: now,
      panel: panel,
      page_title:
        if(panel.kind == :result, do: result_title(panel.selected), else: "Result unavailable"),
      list_path: path(assigns.filters, assigns.list_action),
      current_path: path(filters, action, assigns.selected_id)
    )
  end

  defp refresh(%{assigns: %{list_action: :checks} = assigns} = socket) do
    now = Monitoring.now()

    panel =
      if assigns.live_action == :checks_result,
        do: MondekWeb.PreviewResult.load(assigns.selected_id, now) || %{kind: :not_found}

    socket
    |> NextIncidentsLive.refresh_detail(now)
    |> assign(
      now: now,
      panel: panel,
      checks: Inspection.preview_checks(assigns.filters, now),
      list_path: path(assigns.filters, :checks),
      current_path:
        path(
          Map.put(assigns.filters, "incident_return", assigns.incident_return),
          assigns.live_action,
          assigns.selected_id
        ),
      page_title: "Checks"
    )
  end

  defp refresh(%{assigns: %{list_action: :coverage} = assigns} = socket) do
    now = Monitoring.now()
    filters = assigns.filters

    panel =
      case assigns.live_action do
        :coverage_diagnostic ->
          case Coverage.diagnostic(assigns.selected_id, now) do
            nil -> %{kind: :not_found}
            item -> %{kind: :coverage_diagnostic, item: item}
          end

        :coverage_result ->
          load_coverage_panel(assigns, now)

        :coverage ->
          nil
      end

    assign(socket,
      now: now,
      panel: panel,
      coverage: Coverage.scopes(filters, now),
      runner_diagnostics: Coverage.diagnostics(%{}, now),
      list_path: path(filters, :coverage),
      current_path: coverage_path(assigns),
      page_title: "Coverage"
    )
  end

  defp refresh(socket) do
    now = Monitoring.now()
    filters = socket.assigns.filters
    overview = Inspection.overview_results(filters, now)

    missing =
      Coverage.scopes(
        Map.merge(filters, %{"status" => "missing", "page" => filters["expected_page"] || "1"}),
        now
      )

    declarations = Coverage.summary(%{}, now)
    snapshot = Monitoring.overview(now)

    panel =
      case socket.assigns.live_action do
        :result ->
          MondekWeb.PreviewResult.load(socket.assigns.selected_id, now) || %{kind: :not_found}

        :expected ->
          load_coverage_panel(socket.assigns, now)

        _ ->
          nil
      end

    socket = NextIncidentsLive.refresh_detail(socket, now)

    assign(socket,
      now: now,
      overview: overview,
      missing: missing,
      declarations: declarations,
      snapshot: snapshot,
      open_incidents: MondekWeb.NextIncidentsLive.open_summary(now),
      panel: panel,
      page_title: "Overview preview",
      list_path: path(filters),
      current_path:
        if(socket.assigns.live_action == :expected,
          do: coverage_path(socket.assigns),
          else:
            path(
              Map.put(filters, "incident_return", socket.assigns.incident_return),
              socket.assigns.live_action,
              socket.assigns.selected_id
            )
        )
    )
  end

  defp load_coverage_panel(assigns, now) do
    case Coverage.scope(assigns.selected_id, now) do
      nil ->
        %{kind: :not_found}

      scope ->
        observers = Coverage.observers(scope["id"], %{"page" => assigns.runner_page}, now)

        result =
          if Enum.any?(
               observers["items"],
               &(&1["stream_id"] && &1["stream_id"] == assigns.observer_result)
             ),
             do: MondekWeb.PreviewResult.load(assigns.observer_result, now)

        %{kind: :expected, scope: scope, observers: observers, result: result}
    end
  end

  defp coverage_path(assigns, extra \\ %{}) do
    assigns.filters
    |> Map.put("incident_return", assigns.incident_return)
    |> Map.put("runner_page", assigns.runner_page)
    |> Map.merge(extra)
    |> path(assigns.live_action, assigns.selected_id, assigns.coverage_full)
  end

  defp page_param(value) when is_binary(value) and byte_size(value) <= 7 do
    case Integer.parse(value) do
      {number, ""} when number > 1 -> Integer.to_string(number)
      _ -> nil
    end
  end

  defp page_param(_), do: nil

  defp uuid_param(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  def path(filters, action \\ :index, id \\ nil, full \\ false) do
    MondekWeb.PreviewNavigation.path(filters, action, id, full)
  end

  @impl true
  def render(%{live_action: action} = assigns)
      when action in [:result_page, :checks_result_page] do
    ~H"""
    <div
      id="result-page-preview"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-selection={overlay_selection(assigns)}
      data-panel-heading="full-result-heading"
      data-panel-background="#preview-result-page"
    >
      <MondekWeb.PreviewLayouts.navigation
        active={if @list_action == :checks, do: :checks, else: :overview}
        overview_path={if @list_action == :checks, do: "/next", else: @list_path}
      />
      <main id="main-content" class="preview-main" tabindex="-1">
        <article
          id="preview-result-page"
          class="preview-incident-panel preview-incident-page pf-v6-c-card"
          inert={@incident_selection != nil}
        >
          <div class="pf-v6-c-card__body">
            <div class="preview-panel-tools">
              <.link navigate={@incident_return || @list_path} class="pf-v6-c-button pf-m-link">
                ← Back to {return_label(@incident_return, @list_action)}
              </.link>
            </div>
            <.result_panel
              :if={@panel.kind == :result}
              panel={@panel}
              now={@now}
              current_path={@current_path}
              filters={@filters}
              incident_return={@incident_return}
              full_page={true}
              heading_id="full-result-heading"
              id_prefix="full-"
              list_action={@list_action}
            />
            <h1 :if={@panel.kind == :not_found}>Result unavailable</h1>
          </div>
        </article>
        <NextIncidentsLive.detail
          :if={@incident_selection}
          {assigns}
          full_page={false}
          id_prefix="overlay-"
          host_target={%{identity: {:result, @selected_id}, path: @current_path}}
        />
      </main>
    </div>
    """
  end

  def render(%{coverage_full: true} = assigns) do
    ~H"""
    <div
      id="coverage-detail-page"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-panel-heading="coverage-page-heading"
      data-panel-background="#coverage-page-body"
      data-selection={overlay_selection(assigns)}
    >
      <MondekWeb.PreviewLayouts.navigation active={
        if @list_action == :coverage, do: :coverage, else: :overview
      } />
      <main id="main-content" class="preview-main" tabindex="-1">
        <article
          id="coverage-page-body"
          class="preview-incident-panel preview-incident-page pf-v6-c-card"
          inert={@panel.kind == :expected && @panel.result != nil}
        >
          <div class="pf-v6-c-card__body">
            <div class="preview-panel-tools">
              <.link patch={@list_path} class="pf-v6-c-button pf-m-link">
                ← Back to {if @list_action == :coverage, do: "coverage", else: "overview"}
              </.link>
              <.link
                patch={coverage_path(assigns |> assign(:coverage_full, false))}
                class="pf-v6-c-button pf-m-link"
              >
                Open fly-over
              </.link>
            </div>
            <.coverage_detail_body {assigns} heading_id="coverage-page-heading" />
          </div>
        </article>
        <.coverage_overlay {assigns} />
      </main>
    </div>
    """
  end

  def render(%{list_action: :coverage} = assigns) do
    summary = assigns.coverage["summary"]

    assigns =
      assign(assigns,
        incomplete_catalogue:
          summary["unsupported_publishers"] > 0 || summary["unconfirmed_publishers"] > 0,
        attention: assigns.filters["status"] == "attention"
      )

    ~H"""
    <div
      id="coverage-preview"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-panel-heading="coverage-heading"
      data-selection={overlay_selection(assigns)}
    >
      <MondekWeb.PreviewLayouts.navigation active={:coverage} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section class="preview-list" aria-labelledby="coverage-heading">
          <header class="preview-results-header">
            <h1 id="coverage-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">Coverage</h1>
            <.result_filters {assigns} />
          </header>
          <p class="preview-coverage-intro">
            See which results your monitoring projects declare and whether runners are sending current measurements.
          </p>
          <section class="preview-table-group" aria-labelledby="coverage-results-heading">
            <div class="preview-section-heading preview-coverage-heading">
              <h2 id="coverage-results-heading" class="pf-v6-c-title pf-m-md">Declared results</h2>
              <span class="pf-v6-c-badge pf-m-read">{count_label(@coverage["total"], "result")}</span>
            </div>
            <PreviewCoverage.list
              :if={@coverage["items"] != []}
              items={@coverage["items"]}
              selected_id={if @live_action == :coverage_result, do: @selected_id}
              open={
                fn id ->
                  if id == @selected_id, do: @list_path, else: path(@filters, :coverage_result, id)
                end
              }
            />
            <p :if={@coverage["items"] == []} class="preview-empty">
              {cond do
                @filters["search"] || @filters["environment"] || @filters["target_key"] ->
                  "No declared results match these filters."

                @attention ->
                  "No gaps found among declared results."

                true ->
                  "No results have been declared yet."
              end}
            </p>
            <MondekWeb.PreviewPagination.pagination
              page={@coverage["page"]}
              size={@coverage["page_size"]}
              total={@coverage["total"]}
              label="Declared result pages"
              url={fn page -> path(Map.put(@filters, "page", to_string(page)), :coverage) end}
            />
          </section>
          <div :if={@incomplete_catalogue} class="preview-coverage-audit">
            <p>
              Some runners have not confirmed which checks they should run.
            </p>
            <a href="/coverage/publishers">Review runner declarations</a>
          </div>
          <PreviewCoverage.runner_diagnostics
            listing={@runner_diagnostics}
            selected_id={if @live_action == :coverage_diagnostic, do: @selected_id}
            open={
              fn id ->
                if @live_action == :coverage_diagnostic && id == @selected_id,
                  do: @list_path,
                  else: path(@filters, :coverage_diagnostic, id)
              end
            }
          />
        </section>
        <.coverage_overlay {assigns} />
        <div class="preview-connection" role="status">Connection interrupted. Reconnecting…</div>
      </main>
    </div>
    """
  end

  def render(%{list_action: :checks} = assigns) do
    ~H"""
    <div
      id="checks-preview"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-panel-heading="checks-heading"
      data-selection={overlay_selection(assigns)}
    >
      <MondekWeb.PreviewLayouts.navigation active={:checks} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section class="preview-list" aria-labelledby="checks-heading">
          <header class="preview-results-header">
            <h1 id="checks-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">Checks</h1>
            <.result_filters {assigns} />
          </header>
          <section class="preview-table-group" aria-labelledby="checks-results-heading">
            <div class="preview-section-heading">
              <h2 id="checks-results-heading" class="pf-v6-c-title pf-m-md">Results</h2>
              <span class="pf-v6-c-badge pf-m-read">{count_label(@checks.total, "result")}</span>
            </div>
            <.result_table
              :if={@checks.items != []}
              id="preview-check-results"
              listing={@checks}
              filters={@filters}
              panel={@panel}
              now={@now}
              list_action={:checks}
              label="Check results"
            />
            <p :if={@checks.items == []} class="preview-empty">
              {if @filters == %{},
                do: "No active check results yet.",
                else: "No check results match these filters."}
              <.link
                :if={@filters != %{}}
                patch={path(%{}, :checks)}
              >Clear filters</.link>
            </p>
            <.pager
              :if={@checks.total > @checks.page_size}
              listing={@checks}
              filters={@filters}
              key="page"
              label="Check results"
              list_action={:checks}
            />
          </section>
        </section>
        <.evidence_overlay {assigns} />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="overview-preview"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-updated-at={Monitoring.iso(@now)}
      data-selection={overlay_selection(assigns)}
      data-panel-background=".preview-overview-card, .preview-list"
    >
      <MondekWeb.PreviewLayouts.navigation active={:overview} overview_path={@list_path} />
      <main
        id="main-content"
        class={["preview-main", @panel && "preview-has-selection"]}
        tabindex="-1"
      >
        <section
          id="preview-overview-card"
          class="preview-overview-card"
          aria-labelledby="overview-heading"
        >
          <div class="preview-heading">
            <h1 id="overview-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">Overview</h1>
            <span class="preview-caption">Updated
            <time datetime={Monitoring.iso(@now)}>{Calendar.strftime(@now, "%H:%M:%S UTC")}</time></span>
          </div>
          <section id="preview-summary" class="preview-summary" aria-label="Installation summary">
            <div>
              <h2 class="preview-summary-label">Last measured health</h2>
              <div class="preview-counts">
                <span><strong>{@overview.health.critical}</strong> Critical</span>
                <span><strong>{@overview.health.warning}</strong> Warning</span>
                <span><strong>{@overview.health.healthy}</strong> Healthy</span>
                <span><strong>{@overview.health.not_measured}</strong> Not measured</span>
                <span :if={@overview.health.unknown > 0}><strong>{@overview.health.unknown}</strong>
                Unknown</span>
              </div>
            </div>
            <div>
              <h2 class="preview-summary-label">Monitoring</h2>
              <div class="preview-counts">
                <span><strong>{@snapshot["coverage"]["fresh"]} / {@snapshot["coverage"]["active"]}</strong>
                observations fresh</span>
                <span><strong>{@declarations["observed"]} / {@declarations["scopes"]}</strong>
                declared results fully observed</span>
              </div>
              <a
                :if={
                  (@declarations["unsupported_publishers"] || 0) > 0 ||
                    (@declarations["unconfirmed_publishers"] || 0) > 0 ||
                    (@declarations["unbound_declarations"] || 0) > 0
                }
                href="/next/coverage"
                class="preview-caption"
              >Some declarations need review</a>
            </div>
          </section>
        </section>
        <section
          id="preview-open-incidents"
          class="preview-overview-card"
          aria-labelledby="overview-incidents-heading"
        >
          <div class="preview-heading preview-overview-incident-heading">
            <h2
              id="overview-incidents-heading"
              class="pf-v6-c-title pf-m-xl preview-overview-incident-title"
            >
              Open incidents <span class="pf-v6-c-badge pf-m-read">{@open_incidents.total}</span>
            </h2>
            <.link navigate="/next/incidents">View all incidents</.link>
          </div>
          <p :if={@open_incidents.rows == []} class="preview-empty">No open incidents.</p>
          <div :if={@open_incidents.rows != []} class="preview-table-group">
            <table
              class="pf-v6-c-table preview-table preview-overview-incidents-table"
              aria-labelledby="overview-incidents-heading"
            >
              <thead class="pf-v6-c-table__thead">
                <tr>
                  <th scope="col" class="pf-v6-c-table__th">Severity</th>
                  <th scope="col" class="pf-v6-c-table__th">Incident</th>
                  <th scope="col" class="pf-v6-c-table__th">Scope</th>
                  <th scope="col" class="pf-v6-c-table__th">Opened</th>
                  <th scope="col" class="pf-v6-c-table__th">Acknowledgement</th>
                </tr>
              </thead>
              <tbody class="pf-v6-c-table__tbody">
                <tr
                  :for={row <- @open_incidents.rows}
                  class={[
                    "pf-v6-c-table__tr",
                    @incident_selection == {row.kind, row.id} && "preview-selected"
                  ]}
                  data-overview-row
                >
                  <td class="pf-v6-c-table__td">
                    <.state :if={row.health} value={row.health} />
                    <span :if={!row.health} class="preview-caption" title="Monitoring loss">Loss</span>
                  </td>
                  <td class="pf-v6-c-table__td">
                    <.link
                      id={"overview-incident-#{row.kind}-#{row.id}"}
                      patch={
                        if @incident_selection == {row.kind, row.id},
                          do: @list_path,
                          else: NextIncidentsLive.incident_layer_path(@list_path, row.kind, row.id)
                      }
                      data-overview-open
                      class="preview-result-link"
                    >{row.title}</.link>
                    <span :if={row.contribution_count} class="preview-caption">
                      · {count_label(row.contribution_count, "affected result")}
                    </span>
                  </td>
                  <td class="pf-v6-c-table__td preview-caption">
                    {if row.context == "", do: "—", else: row.context}
                  </td>
                  <td class="pf-v6-c-table__td">
                    <time datetime={row.opened_at} title={time(row.opened_at)}>{age(
                      row.opened_at,
                      @now
                    )}</time>
                  </td>
                  <td class="pf-v6-c-table__td">
                    {if row.acknowledged, do: "Acknowledged", else: "Unacknowledged"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
        <div class="preview-workspace">
          <section class="preview-list" aria-labelledby="preview-results-heading">
            <header class="preview-results-header">
              <h2 id="preview-results-heading" class="pf-v6-c-title pf-m-2xl">Results</h2>
              <.result_filters {assigns} />
            </header>
            <section class="preview-table-group" aria-labelledby="preview-attention-heading">
              <div class="preview-section-heading">
                <h3 id="preview-attention-heading" class="pf-v6-c-title pf-m-md">Needs attention</h3><span class="pf-v6-c-badge pf-m-read">{count_label(
                  @overview.attention.total,
                  "result"
                )}</span>
              </div>
              <p
                :if={@snapshot["coverage"]["active"] == 0 && @declarations["scopes"] == 0}
                class="preview-empty"
                id="preview-onboarding"
              >
                No active results or resolved declarations yet. <a href="/guide">Connect a runner</a>
                or <a href="/coverage">review monitoring declarations</a>.
              </p>
              <p
                :if={
                  @overview.attention.total == 0 &&
                    (@snapshot["coverage"]["active"] > 0 || @declarations["scopes"] > 0)
                }
                class="preview-empty"
                id="preview-no-attention"
              >
                {if Enum.all?(~w(search environment target_key), &is_nil(@filters[&1])),
                  do: "No results currently need attention.",
                  else: "No results needing attention match your filters."}
              </p>
              <.result_table
                :if={@overview.attention.items != []}
                listing={@overview.attention}
                filters={@filters}
                panel={@panel}
                now={@now}
                id="preview-attention"
              />
              <.pager
                :if={@overview.attention.total > @overview.attention.page_size}
                listing={@overview.attention}
                filters={@filters}
                key="page"
                label="Results needing attention"
              />
            </section>
            <section
              :if={@declarations["missing"] > 0 || @missing["total"] > 0}
              id="preview-unobserved"
              class="preview-expected preview-table-group"
              aria-labelledby="preview-unobserved-heading"
            >
              <div class="preview-section-heading">
                <h3 id="preview-unobserved-heading" class="pf-v6-c-title pf-m-md">
                  Declared results with no selected runner
                </h3>
                <span class="pf-v6-c-badge pf-m-read">{count_label(
                  @missing["total"],
                  "monitoring gap"
                )}</span>
              </div>
              <p :if={@missing["total"] == 0} class="preview-empty">
                No monitoring gaps match your filters.
              </p>
              <table
                :if={@missing["total"] > 0}
                class="pf-v6-c-table pf-m-compact preview-table"
                aria-label="Declared results with no selected runner"
              >
                <thead class="pf-v6-c-table__thead">
                  <tr class="pf-v6-c-table__tr">
                    <th class="pf-v6-c-table__th">Target and result</th><th class="pf-v6-c-table__th">
                      Monitoring
                    </th>
                  </tr>
                </thead>
                <tbody class="pf-v6-c-table__tbody">
                  <tr
                    :for={scope <- @missing["items"]}
                    class={[
                      "pf-v6-c-table__tr",
                      @panel && @panel.kind == :expected && @panel.scope["id"] == scope["id"] &&
                        "preview-selected"
                    ]}
                    data-overview-row
                  >
                    <td class="pf-v6-c-table__td" data-label="Target and result">
                      <div class="preview-identity">
                        <.link
                          id={"open-expected-" <> scope["id"]}
                          patch={
                            if @panel && @panel.kind == :expected && @panel.scope["id"] == scope["id"],
                              do: @list_path,
                              else: path(@filters, :expected, scope["id"])
                          }
                          data-overview-open
                          class="preview-result-link"
                        >{target_label(scope["target"])}<span>{scope_title(scope)}</span></.link><p class="preview-caption preview-result-context">
                          {scope["environment_label"] || scope["environment"] || "Unscoped"} · {scope[
                            "source_id"
                          ]}
                        </p>
                      </div>
                    </td>
                    <td class="pf-v6-c-table__td" data-label="Monitoring">
                      <div class="preview-measurement">
                        <.state value="missing" /><p class="preview-caption preview-measurement-summary">
                          No measurement to inspect
                        </p>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
              <.pager
                :if={@missing["total"] > 0}
                listing={%{total: @missing["total"], page: @missing["page"], page_size: 25}}
                filters={@filters}
                key="expected_page"
                label="Unobserved declarations"
              />
            </section>
            <section
              id="preview-healthy"
              class="preview-healthy preview-table-group"
              aria-labelledby="preview-healthy-heading"
            >
              <div class="preview-section-heading">
                <h3 id="preview-healthy-heading" class="pf-v6-c-title pf-m-md">
                  Current and healthy
                </h3><span class="pf-v6-c-badge pf-m-read">{count_label(
                  @overview.healthy.total,
                  "result"
                )}</span>
              </div>
              <.result_table
                :if={@overview.healthy.items != []}
                listing={@overview.healthy}
                filters={@filters}
                panel={@panel}
                now={@now}
                id="preview-healthy-results"
              />
              <p :if={@overview.healthy.total == 0} class="preview-empty">
                No current, healthy results{if @filters["search"] not in [nil, ""],
                  do: " match your search"}.
              </p>
              <.pager
                :if={@overview.healthy.total > @overview.healthy.page_size}
                listing={@overview.healthy}
                filters={@filters}
                key="healthy_page"
                label="Healthy results"
              />
            </section>
          </section>
          <.evidence_overlay {assigns} />
        </div>
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp result_filters(assigns) do
    ~H"""
    <MondekWeb.PreviewFilters.filter_picker
      picker={@filter_picker}
      chips={@filter_chips}
      fields={
        Enum.map(@filter_module.fields(), fn {key, label} -> {key, label, filter_icon(key)} end)
      }
      search={@filters["search"]}
      remove={
        fn field ->
          path(@filters |> @filter_module.remove(field) |> @filter_module.reset_pages(), @list_action)
        end
      }
      clear_search={
        path(@filters |> Map.delete("search") |> @filter_module.reset_pages(), @list_action)
      }
      form_label={if @list_action == :coverage, do: "Filter declared results", else: "Filter results"}
      label="Search results and targets"
      placeholder="Search or filter results"
    />
    """
  end

  defp filter_icon("environment"), do: "globe"
  defp filter_icon("target"), do: "map-pin"
  defp filter_icon("group"), do: "grid"
  defp filter_icon("health"), do: "pulse"
  defp filter_icon("freshness"), do: "clock"
  defp filter_icon("status"), do: "server"

  defp result_action(:checks, true), do: :checks_result_page
  defp result_action(:checks, false), do: :checks_result
  defp result_action(_, true), do: :result_page
  defp result_action(_, false), do: :result

  defp overlay_selection(%{incident_selection: {kind, id}, detail_filters: filters}),
    do: "#{kind}-#{id}-#{filters["result"]}"

  defp overlay_selection(%{panel: %{kind: :expected, result: %{selected: result}}}),
    do: "coverage-result-#{result["id"]}"

  defp overlay_selection(%{coverage_full: true}), do: nil

  defp overlay_selection(%{live_action: action, selected_id: id, panel: panel})
       when action in [:result, :checks_result, :expected, :coverage_result, :coverage_diagnostic],
       do: if(panel, do: path(%{}, action, id))

  defp overlay_selection(_), do: nil

  defp evidence_overlay(assigns) do
    ancestors =
      if assigns.incident_selection && assigns.panel && assigns.panel.kind == :result do
        [
          %{
            kind: "Check result",
            identity: {:result, assigns.selected_id},
            title: result_title(assigns.panel.selected),
            path: assigns.current_path
          }
        ]
      else
        []
      end

    assigns = assign(assigns, :host_ancestors, ancestors)

    ~H"""
    <NextIncidentsLive.detail
      :if={@incident_selection}
      {assigns}
      full_page={false}
      host_ancestors={@host_ancestors}
    >
      <:host_fallback>
        <.result_drawer_body {assigns} />
      </:host_fallback>
    </NextIncidentsLive.detail>
    <.coverage_overlay :if={@panel && @panel.kind == :expected} {assigns} />
    <.result_drawer :if={!@incident_selection && (!@panel || @panel.kind != :expected)} {assigns} />
    """
  end

  defp coverage_overlay(assigns) do
    result = if assigns.panel && assigns.panel.kind == :expected, do: assigns.panel.result

    assigns =
      assign(assigns,
        coverage_result: result,
        coverage_ancestors:
          if(result,
            do: [
              %{
                kind: "Declared result",
                title: PreviewCoverage.title(assigns.panel.scope),
                path: assigns.current_path
              }
            ],
            else: []
          )
      )

    ~H"""
    <MondekWeb.PanelStack.rear_cards
      entries={if @coverage_full, do: [], else: @coverage_ancestors}
      card_class="preview-incident-panel pf-v6-c-card"
    >
      <:fallback>
        <.result_drawer_body {assigns} />
      </:fallback>
    </MondekWeb.PanelStack.rear_cards>
    <PreviewDetail.surface
      :if={@coverage_result}
      path={coverage_path(assigns, %{"observer_result" => @coverage_result.selected["id"]})}
    >
      <div class="preview-panel-tools">
        <.link patch={@current_path} data-overview-close class="pf-v6-c-button pf-m-link">← Back one level</.link>
        <.link
          navigate={coverage_full_result_path(@coverage_result.selected["id"], @current_path)}
          class="pf-v6-c-button pf-m-link"
        >Open as page</.link>
      </div>
      <MondekWeb.PreviewResultDetail.detail
        configuration_path={"/checks/" <> @coverage_result.selected["id"] <> "?" <> URI.encode_query(%{"return_to" => coverage_path(assigns, %{"observer_result" => @coverage_result.selected["id"]})})}
        panel={@coverage_result}
        now={@now}
        incident_path={
          fn id ->
            @coverage_result.selected["id"]
            |> coverage_check_path(
              coverage_path(assigns, %{"observer_result" => @coverage_result.selected["id"]})
            )
            |> NextIncidentsLive.incident_layer_path("health", id)
          end
        }
        peer_path={
          fn id ->
            if Enum.any?(@panel.observers["items"], &(&1["stream_id"] == id)),
              do: coverage_path(assigns, %{"observer_result" => id}),
              else: coverage_check_path(id, @current_path)
          end
        }
        full_result_path={coverage_full_result_path(@coverage_result.selected["id"], @current_path)}
      />
    </PreviewDetail.surface>
    <.result_drawer :if={!@coverage_result && !@coverage_full} {assigns} />
    """
  end

  defp coverage_check_path(id, back),
    do: path(%{"incident_return" => back}, :checks_result, id)

  defp return_label("/next/maintenance/" <> _, _), do: "maintenance"
  defp return_label("/next/coverage/" <> _, _), do: "coverage"
  defp return_label("/next/expected/" <> _, _), do: "coverage"
  defp return_label(path, _) when is_binary(path), do: "incident"
  defp return_label(nil, :checks), do: "checks"
  defp return_label(nil, _), do: "overview"

  defp coverage_full_result_path(id, back),
    do: path(%{"incident_return" => back}, :checks_result_page, id)

  defp result_drawer(assigns) do
    ~H"""
    <PreviewDetail.surface
      :if={@panel}
      tag="div"
      wide={@panel.kind in [:result, :expected, :coverage_diagnostic]}
      path={@current_path}
    >
      <.result_drawer_content {assigns} />
    </PreviewDetail.surface>
    """
  end

  defp result_drawer_body(assigns) do
    ~H"""
    <div class="pf-v6-c-card__body">
      <.result_drawer_content {assigns} />
    </div>
    """
  end

  defp result_drawer_content(assigns) do
    ~H"""
    <div class="preview-panel-tools">
      <.link
        :if={@panel.kind == :result}
        navigate={
          path(
            Map.put(@filters, "incident_return", @incident_return),
            result_action(@list_action, true),
            @selected_id
          )
        }
        class="pf-v6-c-button pf-m-link"
      >Open as page</.link>
      <.link
        :if={@live_action in [:expected, :coverage_result, :coverage_diagnostic]}
        patch={coverage_path(assigns |> assign(:coverage_full, true))}
        class="pf-v6-c-button pf-m-link"
      >Open as page</.link>
      <a
        :if={@incident_return}
        href={@incident_return}
        class="pf-v6-c-button pf-m-link preview-panel-back"
      >← Back to {return_label(@incident_return, @list_action)}</a>
      <.link
        patch={@list_path}
        data-overview-close
        class="pf-v6-c-button pf-m-link preview-panel-back"
      >Close details ×</.link>
      <div class="preview-connection" role="status">
        Connection interrupted. Displayed evidence may be out of date.
      </div>
    </div>
    <.result_panel
      :if={@panel.kind == :result}
      panel={@panel}
      now={@now}
      current_path={@current_path}
      filters={@filters}
      incident_return={@incident_return}
      list_action={@list_action}
    />
    <.coverage_detail_body :if={@panel.kind != :result} {assigns} heading_id="overview-panel-title" />
    """
  end

  defp coverage_detail_body(assigns) do
    ~H"""
    <div :if={@panel.kind == :not_found}>
      <h2 id={@heading_id} tabindex="-1" class="pf-v6-c-title pf-m-xl">
        {if @live_action == :coverage_diagnostic,
          do: "Diagnostic unavailable",
          else: "Result unavailable"}
      </h2>
      <p>
        {cond do
          @live_action == :coverage_diagnostic ->
            "The runner may have updated or removed this declaration."

          @list_action == :checks ->
            "This result may have been removed by retention."

          true ->
            "The selected result or declaration is no longer available."
        end}
      </p>
    </div>
    <PreviewCoverage.diagnostic_detail
      :if={@panel.kind == :coverage_diagnostic}
      item={@panel.item}
      heading_id={@heading_id}
      full_page={@coverage_full}
    />
    <PreviewCoverage.detail
      :if={@panel.kind == :expected}
      scope={@panel.scope}
      heading_id={@heading_id}
      full_page={@coverage_full}
      observers={@panel.observers}
      result_path={fn id -> coverage_path(assigns, %{"observer_result" => id}) end}
      page_path={
        fn page -> coverage_path(assigns, %{"runner_page" => if(page > 1, do: to_string(page))}) end
      }
    />
    <div :if={@panel.kind == :expected && @list_action == :index} class="preview-recorded-actions">
      <.link navigate={
        path(
          CoverageFilters.params(Map.drop(@filters, ~w(page healthy_page expected_page))),
          :coverage_result,
          @panel.scope["id"]
        )
      }>
        View in Coverage
      </.link>
    </div>
    """
  end

  defp result_table(assigns) do
    assigns =
      assigns
      |> assign_new(:list_action, fn -> :index end)
      |> assign_new(:label, fn ->
        if assigns.id == "preview-attention",
          do: "Results needing attention",
          else: "Current healthy results"
      end)

    ~H"""
    <table
      id={@id}
      class="pf-v6-c-table pf-m-compact preview-table"
      aria-label={@label}
    >
      <thead class="pf-v6-c-table__thead">
        <tr class="pf-v6-c-table__tr">
          <th class="pf-v6-c-table__th">Target and result</th><th class="pf-v6-c-table__th">
            Latest measurement
          </th>
        </tr>
      </thead>
      <tbody class="pf-v6-c-table__tbody">
        <tr
          :for={row <- @listing.items}
          id={"result-row-" <> row["id"]}
          data-overview-row
          class={[
            "pf-v6-c-table__tr",
            @panel && @panel.kind == :result && @panel.selected["id"] == row["id"] &&
              "preview-selected"
          ]}
        >
          <td class="pf-v6-c-table__td" data-label="Target and result">
            <div class="preview-identity">
              <.link
                id={"open-result-" <> row["id"]}
                patch={
                  if @panel && @panel.kind == :result && @panel.selected["id"] == row["id"],
                    do: path(@filters, @list_action),
                    else: path(@filters, result_action(@list_action, false), row["id"])
                }
                data-overview-open
                class="preview-result-link"
                title={target_label(row["target"]) <> " · " <> result_title(row)}
              >{target_label(row["target"])}{" "}<span>{result_title(row)}</span></.link>
              <p class="preview-caption preview-result-context" title={row_context(row)}>
                {row["environment_label"] || row["environment"] || "Unscoped"} · {row[
                  "runner_display"
                ]}
                <span :if={@list_action == :checks && get_in(row, ["check_group", "label"])}>
                  · {row["check_group"]["label"]}
                </span>
                <span :if={@list_action == :checks && row["retired"]}> · Retired</span>
              </p>
            </div>
          </td>
          <td class="pf-v6-c-table__td" data-label="Latest measurement">
            <div class="preview-measurement">
              <.state value={measured_health(row)} /><.state value={
                get_in(row, ["current", "knowledge"])
              } />
              <time
                :if={confirmed?(row)}
                datetime={row["current"]["source_at"]}
                title={time(row["current"]["source_at"])}
              >{age(row["current"]["source_at"], @now)}</time>
              <p class="preview-measurement-summary" title={summary(row)}>{summary(row)}</p>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp result_panel(assigns) do
    full_page = assigns[:full_page] || false
    action = result_action(assigns.list_action, full_page)
    filters = Map.put(assigns.filters, "incident_return", assigns.incident_return)

    assigns =
      assign(assigns,
        configuration_path:
          "/checks/" <>
            assigns.panel.selected["id"] <>
            "?" <> URI.encode_query(%{"return_to" => assigns.current_path}),
        incident_path: &NextIncidentsLive.incident_layer_path(assigns.current_path, "health", &1),
        peer_path: &path(filters, action, &1),
        full_result_path:
          if(!full_page,
            do:
              path(
                filters,
                result_action(assigns.list_action, true),
                assigns.panel.selected["id"]
              )
          )
      )

    ~H"""
    <MondekWeb.PreviewResultDetail.detail
      panel={@panel}
      now={@now}
      configuration_path={@configuration_path}
      incident_path={@incident_path}
      peer_path={@peer_path}
      full_result_path={@full_result_path}
      full_page={assigns[:full_page] || false}
      heading_id={assigns[:heading_id] || "overview-panel-title"}
      id_prefix={assigns[:id_prefix] || ""}
    />
    """
  end

  defp pager(assigns) do
    assigns = assign_new(assigns, :list_action, fn -> :index end)

    assigns =
      assign(assigns, pages: max(1, ceil(assigns.listing.total / assigns.listing.page_size)))

    ~H"""
    <MondekWeb.PreviewPagination.pagination
      page={@listing.page}
      size={@listing.page_size}
      total={@listing.total}
      label={@label}
      url={fn page -> path(Map.put(@filters, @key, to_string(page)), @list_action) end}
    />
    <div :if={@pages == 1} class="preview-pager">
      {count_label(@listing.total, "monitoring gap")} · page {@listing.page} of {@pages}
    </div>
    """
  end

  attr(:value, :any, required: true)

  defp state(assigns) do
    assigns = assign(assigns, text: state_text(assigns.value), tone: state_tone(assigns.value))

    ~H"""
    <span class={["pf-v6-c-label", @tone]}><span class="pf-v6-c-label__content">{@text}</span></span>
    """
  end

  defp confirmed?(row), do: get_in(row, ["current", "confirmed_observation_id"]) != nil

  defp measured_health(row),
    do: if(confirmed?(row), do: row["current"]["health"], else: "not_measured")

  defp summary(row),
    do: if(confirmed?(row), do: row["current"]["summary"], else: "No confirmed measurement yet.")

  defp row_context(row),
    do:
      Enum.join(
        [
          row["environment_label"] || row["environment"] || "Unscoped",
          row["source_id"] || "Source not recorded",
          row["runner_display"]
        ],
        " · "
      )

  defp count_label(count, unit), do: "#{count} #{unit}" <> if(count == 1, do: "", else: "s")

  defp result_title(row),
    do:
      if(row["label"] == row["check_label"],
        do: row["label"],
        else: row["check_label"] <> " · " <> row["label"]
      )

  defp scope_title(scope),
    do:
      if(scope["check_label"] == scope["result_label"],
        do: scope["check_label"],
        else: scope["check_label"] <> " · " <> scope["result_label"]
      )

  defp state_text("fresh"), do: "Fresh"
  defp state_text("stale"), do: "Overdue measurement"
  defp state_text("unavailable"), do: "Collection unavailable"
  defp state_text("awaiting"), do: "Awaiting measurement"
  defp state_text("missing"), do: "No selected runner"
  defp state_text(value), do: badge_text(value)
  defp state_tone(value) when value in ["CRIT", "unavailable"], do: "pf-m-red"
  defp state_tone(value) when value in ["WARN", "stale", "missing", "awaiting"], do: "pf-m-orange"
  defp state_tone("OK"), do: "pf-m-green"
  defp state_tone(_), do: ""
end

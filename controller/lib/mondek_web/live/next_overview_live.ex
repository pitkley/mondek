# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias Mondek.{ChecksFilters, Coverage, CoverageFilters, Inspection, Monitoring, OverviewFilters}

  alias MondekWeb.{
    NextIncidentsLive,
    PreviewCoverage,
    InvestigationStack,
    InvestigationTrail
  }

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       filters: %{},
       selected_id: nil,
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

    return_to = MondekWeb.BrowserNavigation.return_path(params["return_to"])
    filters = filter_module.params(params)
    filters = if return_to, do: Map.put(filters, "return_to", return_to), else: filters

    presentation_page =
      !is_nil(
        InvestigationTrail.promoted(params, InvestigationTrail.initial(URI.parse(uri).path))
      )

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
       coverage_page:
         case InvestigationTrail.root(URI.parse(uri).path) do
           {kind, _} when kind in ~w(coverage diagnostic) -> true
           _ -> false
         end,
       filters: filters,
       presentation_page: presentation_page,
       filter_module: filter_module,
       list_action: list_action,
       selected_id: params["id"],
       unavailable_result:
         socket.assigns.live_action in [
           :result,
           :result_page,
           :checks_result,
           :checks_result_page
         ] &&
           is_nil(InvestigationTrail.identity({"result", params["id"]})),
       return_to: return_to,
       filter_chips: chips,
       filter_picker: nil
     )
     |> assign(
       investigation_params: params,
       investigation_host:
         URI.parse(uri).path <>
           if(URI.parse(uri).query, do: "?" <> URI.parse(uri).query, else: ""),
       investigation_root: InvestigationTrail.root(URI.parse(uri).path),
       initial_trail: InvestigationTrail.initial(URI.parse(uri).path),
       investigation_active:
         List.last(
           InvestigationTrail.resolve(params, InvestigationTrail.initial(URI.parse(uri).path))
         ) ||
           InvestigationTrail.root(URI.parse(uri).path)
     )
     |> refresh()
     |> normalize_incident_pages()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, socket |> refresh() |> normalize_incident_pages()}
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
        |> Map.put("return_to", socket.assigns.return_to)

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

  def handle_event(_, _, socket), do: {:noreply, socket}

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

  defp refresh(%{assigns: %{coverage_page: true} = assigns} = socket) do
    assign(socket,
      now: Monitoring.now(),
      list_path: path(assigns.filters, assigns.list_action),
      current_path: assigns.investigation_host,
      page_title: "Coverage"
    )
  end

  defp refresh(%{assigns: %{live_action: action} = assigns} = socket)
       when action in [:result_page, :checks_result_page] do
    now = Monitoring.now()
    filters = Map.put(assigns.filters, "return_to", assigns.return_to)

    assign(socket,
      now: now,
      page_title: "Check result",
      list_path: path(assigns.filters, assigns.list_action),
      current_path: path(filters, action, assigns.selected_id)
    )
  end

  defp refresh(%{assigns: %{list_action: :checks} = assigns} = socket) do
    now = Monitoring.now()

    socket
    |> assign(
      now: now,
      checks: Inspection.preview_checks(assigns.filters, now),
      list_path: path(assigns.filters, :checks),
      current_path:
        path(
          Map.put(assigns.filters, "return_to", assigns.return_to),
          assigns.live_action,
          assigns.selected_id
        ),
      page_title: "Checks"
    )
  end

  defp refresh(%{assigns: %{list_action: :coverage} = assigns} = socket) do
    now = Monitoring.now()
    filters = assigns.filters

    diagnostics_filters =
      filters |> Map.drop(["status", "page"]) |> Map.put("page", filters["diagnostic_page"])

    assign(socket,
      now: now,
      coverage: Coverage.scopes(filters, now),
      runner_diagnostics: Coverage.diagnostics(diagnostics_filters, now),
      list_path: path(filters, :coverage),
      current_path: assigns.investigation_host,
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

    open_incidents =
      Map.new(Inspection.overview_incident_pages(filters, now), fn {key, listing} ->
        rows =
          Enum.map(listing.items, fn {kind, item} ->
            NextIncidentsLive.incident_row(kind, item, now)
          end)

        {key, listing |> Map.delete(:items) |> Map.put(:rows, rows)}
      end)

    effective_filters =
      Enum.reduce(open_incidents, filters, fn {key, listing}, acc ->
        page_filter(acc, key <> "_incident_page", listing.page)
      end)

    assign(socket,
      now: now,
      overview: overview,
      missing: missing,
      declarations: declarations,
      snapshot: snapshot,
      open_incidents: open_incidents,
      page_title: "Overview",
      list_path: path(effective_filters),
      current_path:
        path(
          Map.put(effective_filters, "return_to", socket.assigns.return_to),
          socket.assigns.live_action,
          socket.assigns.selected_id
        )
    )
  end

  defp normalize_incident_pages(
         %{assigns: %{list_action: :index, open_incidents: incidents, investigation_host: host}} =
           socket
       ) do
    uri = URI.parse(host)
    query = URI.decode_query(uri.query || "")

    normalized =
      Enum.reduce(incidents, query, fn {key, listing}, acc ->
        page_filter(acc, key <> "_incident_page", listing.page)
      end)

    if connected?(socket) && normalized != query,
      do: push_patch(socket, to: with_query(uri, normalized), replace: true),
      else: socket
  end

  defp normalize_incident_pages(socket), do: socket

  defp page_filter(filters, key, 1), do: Map.delete(filters, key)
  defp page_filter(filters, key, page), do: Map.put(filters, key, to_string(page))

  defp incident_page_path(host, key, page) do
    uri = URI.parse(host)
    query = URI.decode_query(uri.query || "") |> page_filter(key, page)
    with_query(uri, query)
  end

  defp with_query(uri, query) do
    URI.to_string(%{
      uri
      | query: if(map_size(query) == 0, do: nil, else: URI.encode_query(query))
    })
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
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "full-result-heading")}
      data-panel-background="#preview-result-page"
    >
      <MondekWeb.PreviewLayouts.navigation
        active={if @list_action == :checks, do: :checks, else: :overview}
        overview_path={if @list_action == :checks, do: "/", else: @list_path}
      />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section :if={!@investigation_root} class="preview-list" id="result-not-found">
          <header class="preview-heading">
            <h1 id="full-result-heading" tabindex="-1">Result unavailable</h1>
          </header>
          <p class="preview-empty">This result identity is not available.</p>
          <div class="preview-recorded-actions"><.link navigate="/checks">Browse results</.link></div>
        </section>
        <.investigation {assigns} />
      </main>
    </div>
    """
  end

  def render(%{coverage_page: true} = assigns) do
    ~H"""
    <div
      id="coverage-detail-page"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-panel-heading={
        InvestigationTrail.heading(@investigation_params, "coverage-page-heading", @initial_trail)
      }
      data-panel-background="#coverage-page-body"
      data-selection={overlay_selection(assigns)}
    >
      <MondekWeb.PreviewLayouts.navigation active={
        if @list_action == :coverage, do: :coverage, else: :overview
      } />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section :if={!@investigation_root} class="preview-list">
          <header class="preview-heading">
            <h1 id="coverage-page-heading" tabindex="-1">Coverage unavailable</h1>
          </header>
          <p class="preview-empty">This declaration identity is not available.</p>
          <div class="preview-recorded-actions">
            <.link navigate="/coverage">Browse declared results</.link>
          </div>
        </section>
        <.investigation {assigns} />
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
        <section :if={!@presentation_page} class="preview-list" aria-labelledby="coverage-heading">
          <header class="preview-results-header">
            <h1 id="coverage-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">Coverage</h1>
            <.link :if={@return_to} navigate={@return_to} class="pf-v6-c-button pf-m-link">Back to {return_label(
              @return_to,
              @list_action
            )}</.link>
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
              selected_id={
                case @investigation_active do
                  {"coverage", id} -> id
                  _ -> nil
                end
              }
              open={
                fn id ->
                  if id == @selected_id, do: @list_path, else: path(@filters, :coverage_result, id)
                end
              }
            />
            <p :if={@coverage["items"] == []} class="preview-empty">
              {cond do
                @filters["search"] || @filters["environment"] || @filters["target_key"] ||
                  @filters["runner_id"] || @filters["source_id"] ->
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
          <div
            :if={(@coverage["summary"]["awaiting_publishers"] || 0) > 0}
            class="preview-coverage-audit"
            id="coverage-restoration-warning"
          >
            <p>
              {count_label(@coverage["summary"]["awaiting_publishers"], "restored source")} waiting for a new inventory. Retained results stay historical until the runner publishes again.
            </p>
            <.link navigate="/coverage/publishers?lifecycle=awaiting_inventory">Review restored sources</.link>
          </div>
          <div :if={@incomplete_catalogue} class="preview-coverage-audit">
            <p>
              Some runners have not confirmed which checks they should run.
            </p>
            <a href="/coverage/publishers">Review runner declarations</a>
          </div>
          <PreviewCoverage.runner_diagnostics
            listing={@runner_diagnostics}
            runner_path={fn id -> InvestigationTrail.path(@list_path, [{"runner", id}]) end}
            page_path={
              fn page -> path(Map.put(@filters, "diagnostic_page", to_string(page)), :coverage) end
            }
            selected_id={
              case @investigation_active do
                {"diagnostic", id} -> id
                _ -> nil
              end
            }
            open={
              fn id ->
                if @live_action == :coverage_diagnostic && id == @selected_id,
                  do: @list_path,
                  else: path(@filters, :coverage_diagnostic, id)
              end
            }
          />
        </section>
        <.investigation {assigns} />
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
      data-panel-heading={
        if @presentation_page,
          do: InvestigationTrail.heading(@investigation_params, "checks-heading"),
          else: "checks-heading"
      }
      data-selection={overlay_selection(assigns)}
    >
      <MondekWeb.PreviewLayouts.navigation active={:checks} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section
          :if={!@presentation_page}
          class="preview-list"
          aria-labelledby="checks-heading"
        >
          <header class="preview-results-header">
            <h1 id="checks-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">Checks</h1>
            <.link :if={@return_to} navigate={@return_to} class="pf-v6-c-button pf-m-link">Back to {return_label(
              @return_to,
              @list_action
            )}</.link>
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
              active_identity={@investigation_active}
              now={@now}
              list_action={:checks}
              label="Check results"
            />
            <p :if={@checks.items == []} class="preview-empty">
              {if Map.drop(@filters, ["return_to"]) == %{},
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
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "overview-heading")}
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-updated-at={Monitoring.iso(@now)}
      data-selection={overlay_selection(assigns)}
      data-panel-background=".preview-overview-card, .preview-list"
    >
      <MondekWeb.PreviewLayouts.navigation active={:overview} overview_path={@list_path} />
      <main
        id="main-content"
        class={["preview-main", @investigation_active && "preview-has-selection"]}
        tabindex="-1"
      >
        <section
          :if={!@presentation_page}
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
                href="/coverage"
                class="preview-caption"
              >Some declarations need review</a>
            </div>
          </section>
        </section>
        <MondekWeb.PreviewDetail.card
          :if={
            !@presentation_page && @snapshot["coverage"]["active"] == 0 &&
              @declarations["scopes"] == 0
          }
          id="runner-onboarding"
          title="Connect your monitoring project"
          level={2}
        >
          <div class="preview-recorded-actions">
            <p>
              Install your consumer package on a runner. Its code declares the checks and targets that appear here.
            </p>
            <.link navigate="/guide" class="pf-v6-c-button pf-m-primary">Set up a runner</.link>
            <.link navigate="/runners" class="pf-v6-c-button pf-m-secondary">Inspect runner connections</.link>
          </div>
        </MondekWeb.PreviewDetail.card>
        <section
          :if={!@presentation_page}
          id="preview-open-incidents"
          class="preview-overview-card"
          aria-labelledby="overview-incidents-heading"
        >
          <header class="preview-results-header">
            <div class="preview-section-heading">
              <h2 id="overview-incidents-heading" class="pf-v6-c-title pf-m-2xl">Incidents</h2>
              <span id="overview-open-alert-count" class="pf-v6-c-badge pf-m-read">
                {@open_incidents["unacknowledged"].total + @open_incidents["acknowledged"].total} open
              </span>
            </div>
            <.link navigate="/incidents">View all incidents</.link>
          </header>
          <.dashboard_incidents
            :for={
              {key, label} <- [{"unacknowledged", "Unacknowledged"}, {"acknowledged", "Acknowledged"}]
            }
            id={"overview-" <> key <> "-incidents"}
            summary={@open_incidents[key]}
            page_url={
              fn page -> incident_page_path(@investigation_host, key <> "_incident_page", page) end
            }
            label={label}
            incident_selection={@investigation_active}
            list_path={@list_path}
            now={@now}
          />
        </section>
        <div class="preview-workspace">
          <section
            :if={!@presentation_page}
            class="preview-list"
            aria-labelledby="preview-results-heading"
          >
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
                active_identity={@investigation_active}
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
                      @investigation_active == {"coverage", scope["id"]} &&
                        "preview-selected"
                    ]}
                    data-overview-row
                  >
                    <td class="pf-v6-c-table__td" data-label="Target and result">
                      <div class="preview-identity">
                        <.link
                          id={"open-expected-" <> scope["id"]}
                          patch={
                            if @investigation_active == {"coverage", scope["id"]},
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
                active_identity={@investigation_active}
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

  defp return_label("/runners" <> _, _), do: "runners"
  defp return_label("/notifications" <> _, _), do: "notifications"
  defp return_label("/configuration" <> _, _), do: "configuration"
  defp return_label("/maintenance/" <> _, _), do: "maintenance"
  defp return_label("/coverage/" <> _, _), do: "coverage"
  defp return_label("/expected/" <> _, _), do: "coverage"
  defp return_label(path, _) when is_binary(path), do: "previous view"

  defp filter_icon("runner_id"), do: "terminal"
  defp filter_icon("source_id"), do: "code"
  defp filter_icon("environment"), do: "globe"
  defp filter_icon("target"), do: "map-pin"
  defp filter_icon("group"), do: "grid"
  defp filter_icon("health"), do: "pulse"
  defp filter_icon("freshness"), do: "clock"
  defp filter_icon("status"), do: "server"

  defp result_action(:checks, false), do: :checks_result
  defp result_action(_, false), do: :result

  defp overlay_selection(assigns),
    do: InvestigationTrail.selection(assigns.investigation_params, assigns.initial_trail)

  defp evidence_overlay(assigns) do
    ~H"""
    <.investigation {assigns} />
    """
  end

  defp investigation(assigns) do
    ~H"""
    <.live_component
      module={InvestigationStack}
      id="investigation-stack"
      host={@investigation_host}
      params={@investigation_params}
      now={@now}
      root={@investigation_root}
      initial={@initial_trail}
      context={if @investigation_root, do: {:result_page, @investigation_root}, else: @list_action}
      unavailable={@unavailable_result}
      back={if @investigation_root, do: @return_to || @list_path, else: @list_path}
    />
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
            @active_identity == {"result", row["id"]} &&
              "preview-selected"
          ]}
        >
          <td class="pf-v6-c-table__td" data-label="Target and result">
            <div class="preview-identity">
              <.link
                id={"open-result-" <> row["id"]}
                patch={
                  if @active_identity == {"result", row["id"]},
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

  defp dashboard_incidents(assigns) do
    ~H"""
    <section id={@id} class="preview-table-group" aria-labelledby={@id <> "-heading"}>
      <div class="preview-section-heading">
        <h3 id={@id <> "-heading"} class="pf-v6-c-title pf-m-md">{@label}</h3>
        <span class="pf-v6-c-badge pf-m-read">{count_label(@summary.total, "incident")}</span>
      </div>
      <p :if={@summary.rows == []} class="preview-empty">No {String.downcase(@label)} incidents.</p>
      <table
        :if={@summary.rows != []}
        class="pf-v6-c-table preview-table preview-overview-incidents-table"
        aria-label={@label <> " incidents"}
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
            :for={row <- @summary.rows}
            class={[
              "pf-v6-c-table__tr",
              @incident_selection == {row.kind, row.id} && "preview-selected"
            ]}
            data-overview-row
          >
            <td class="pf-v6-c-table__td" data-label="Severity">
              <.state :if={row.health} value={row.health} />
              <span :if={!row.health} class="preview-caption" title="Monitoring loss">Loss</span>
            </td>
            <td class="pf-v6-c-table__td" data-label="Incident">
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
            <td class="pf-v6-c-table__td preview-caption" data-label="Scope">
              {if row.context == "", do: "—", else: row.context}
            </td>
            <td class="pf-v6-c-table__td" data-label="Opened">
              <time datetime={row.opened_at} title={time(row.opened_at)}>{age(
                row.opened_at,
                @now
              )}</time>
            </td>
            <td class="pf-v6-c-table__td" data-label="Acknowledgement">
              <span title={if row.acknowledged, do: row.acknowledgement_label}>
                {if row.acknowledged, do: "Acknowledged", else: "Unacknowledged"}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
      <MondekWeb.PreviewPagination.pagination
        page={@summary.page}
        size={@summary.page_size}
        total={@summary.total}
        label={@label <> " incident pages"}
        url={@page_url}
      />
    </section>
    """
  end
end

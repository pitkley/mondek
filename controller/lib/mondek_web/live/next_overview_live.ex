# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NextOverviewLive do
  use MondekWeb, :live_view
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1, badge_text: 1, target_label: 1]
  alias Mondek.{Coverage, Inspection, Monitoring}
  alias MondekWeb.MonitoringUI

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)
    {:ok, assign(socket, filters: %{}, selected_id: nil, panel: nil)}
  end

  @impl true
  def handle_params(params, _, socket) do
    filters =
      params
      |> Map.take(~w(search page healthy_page expected_page))
      |> Enum.filter(fn {_, value} -> is_binary(value) end)
      |> Map.new(fn {key, value} -> {key, String.slice(value, 0, 200)} end)

    {:noreply, socket |> assign(filters: filters, selected_id: params["id"]) |> refresh()}
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
      filters = if search == "", do: %{}, else: %{"search" => search}
      {:noreply, push_patch(socket, to: path(filters), replace: true)}
    end
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
          case Inspection.overview_observers(socket.assigns.selected_id, now) do
            nil ->
              %{kind: :not_found}

            observers ->
              Map.merge(observers, %{
                kind: :result,
                inspection: Monitoring.stream_inspection(socket.assigns.selected_id, now)
              })
          end

        :expected ->
          case Coverage.scope(socket.assigns.selected_id, now) do
            nil ->
              %{kind: :not_found}

            scope ->
              %{
                kind: :expected,
                scope: scope,
                observers: Coverage.observers(scope["id"], %{}, now)
              }
          end

        _ ->
          nil
      end

    assign(socket,
      now: now,
      overview: overview,
      missing: missing,
      declarations: declarations,
      snapshot: snapshot,
      panel: panel,
      page_title: "Overview preview",
      list_path: path(filters),
      current_path: path(filters, socket.assigns.live_action, socket.assigns.selected_id)
    )
  end

  def path(filters, action \\ :index, id \\ nil) do
    base =
      case action do
        :result -> "/next/results/" <> URI.encode(id || "", &URI.char_unreserved?/1)
        :expected -> "/next/expected/" <> URI.encode(id || "", &URI.char_unreserved?/1)
        _ -> "/next"
      end

    query =
      filters |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new() |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="overview-preview"
      class="preview-shell"
      phx-hook="OverviewPanel"
      data-updated-at={Monitoring.iso(@now)}
      data-selection={if @panel, do: path(%{}, @live_action, @selected_id), else: ""}
    >
      <a class="preview-skip pf-v6-c-button pf-m-link" href="#main-content">Skip to content</a>
      <header class="preview-masthead">
        <.link patch="/next" class="preview-brand">mondek</.link>
        <span class="preview-caption">Overview preview</span>
        <details id="preview-theme-picker" class="preview-theme-picker" phx-update="ignore">
          <summary class="pf-v6-c-button pf-m-plain" aria-label="Choose theme">
            <span aria-hidden="true">◐</span><span class="preview-theme-title">Theme</span>
          </summary>
          <fieldset class="preview-theme-menu">
            <legend>Light themes</legend>
            <label :for={
              {value, name, description} <- [
                {"pearl", "Pearl", "Near-white canvas · white surfaces"},
                {"clear", "Clear", "White canvas · blue accents"},
                {"mist", "Mist", "Cool canvas · white surfaces"},
                {"linen", "Linen", "Warm canvas · teal accents"},
                {"original", "Original", "Previous gray palette"}
              ]
            }>
              <input
                type="radio"
                name="preview-theme"
                value={value}
                checked={value == "pearl"}
                data-preview-theme-choice
              />
              <span><strong>{name}</strong><span class="preview-caption">{description}</span></span>
            </label>
          </fieldset>
        </details>
        <a class="pf-v6-c-button pf-m-link" href="/">Open existing UI</a>
      </header>
      <aside class="preview-sidebar">
        <.link patch="/next" class="preview-sidebar-brand"><span
          class="preview-brand-mark"
          aria-hidden="true"
        >m</span><span>mondek<span class="preview-caption">Monitoring</span></span></.link>
        <nav class="pf-v6-c-nav" aria-label="Main navigation">
          <ul class="pf-v6-c-nav__list">
            <li class="pf-v6-c-nav__item">
              <.link patch={@list_path} class="pf-v6-c-nav__link pf-m-current" aria-current="page"><MondekWeb.Layouts.icon
                name="grid"
                size={18}
              /><span>Overview</span></.link>
            </li>
          </ul>
          <h2 class="preview-nav-heading">Existing pages</h2>
          <ul class="pf-v6-c-nav__list">
            <li
              :for={
                {label, href, icon} <- [
                  {"Incidents", "/incidents", "pulse"},
                  {"Checks", "/checks", "check"},
                  {"Maintenance", "/maintenance", "clock"},
                  {"Configuration", "/configuration", "sliders"},
                  {"Runners", "/runners", "server"},
                  {"Notifications", "/notifications", "send"}
                ]
              }
              class="pf-v6-c-nav__item"
            >
              <a href={href} class="pf-v6-c-nav__link"><MondekWeb.Layouts.icon name={icon} size={18} /><span>{label}</span></a>
            </li>
          </ul>
        </nav>
        <a href="/licenses" class="preview-credits">Licenses and credits</a>
      </aside>
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
                href="/coverage/publishers"
                class="preview-caption"
              >Some declarations need review</a>
            </div>
          </section>
        </section>
        <div class="preview-workspace">
          <section class="preview-list" aria-labelledby="preview-results-heading">
            <header class="preview-results-header">
              <h2 id="preview-results-heading" class="pf-v6-c-title pf-m-2xl">Results</h2>
              <form
                id="overview-search"
                phx-change="search"
                phx-submit="search"
                class="preview-toolbar"
                aria-label="Filter all result lists"
              >
                <label class="preview-search-label" for="preview-search">Search results and targets</label>
                <span class="pf-v6-c-form-control preview-search-control"><input
                  id="preview-search"
                  type="search"
                  name="search"
                  value={@filters["search"] || ""}
                  phx-debounce="300"
                /></span>
                <.link
                  :if={@filters["search"] not in [nil, ""]}
                  patch="/next"
                  class="pf-v6-c-button pf-m-link"
                >Clear</.link>
              </form>
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
                  @overview.attention.total == 0 && @missing["total"] == 0 &&
                    (@snapshot["coverage"]["active"] > 0 || @declarations["scopes"] > 0)
                }
                class="preview-empty"
                id="preview-no-attention"
              >
                {if @filters["search"] in [nil, ""],
                  do: "No results currently need attention.",
                  else: "No results needing attention match your search."}
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
              :if={@missing["total"] > 0}
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
              <table
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
          <div
            :if={@panel}
            id="overview-panel"
            class="preview-panel pf-v6-c-card"
            role="dialog"
            aria-modal="false"
            aria-labelledby="overview-panel-title"
          >
            <div class="pf-v6-c-card__body">
              <div class="preview-panel-tools">
                <.link
                  patch={@list_path}
                  data-overview-close
                  class="pf-v6-c-button pf-m-link preview-panel-back"
                >Close details ×</.link>
                <div class="preview-connection" role="status">
                  Connection interrupted. Displayed evidence may be out of date.
                </div>
              </div>
              <div :if={@panel.kind == :not_found}>
                <h2 id="overview-panel-title" tabindex="-1" class="pf-v6-c-title pf-m-xl">
                  Result unavailable
                </h2>
                <p>
                  The selected result or declaration no longer exists. Choose another result from the overview.
                </p>
              </div>
              <.result_panel
                :if={@panel.kind == :result}
                panel={@panel}
                now={@now}
                current_path={@current_path}
                filters={@filters}
              />
              <.expected_panel
                :if={@panel.kind == :expected}
                panel={@panel}
                now={@now}
                current_path={@current_path}
              />
            </div>
          </div>
        </div>
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp result_table(assigns) do
    ~H"""
    <table
      id={@id}
      class="pf-v6-c-table pf-m-compact preview-table"
      aria-label={
        if @id == "preview-attention",
          do: "Results needing attention",
          else: "Current healthy results"
      }
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
                    do: path(@filters),
                    else: path(@filters, :result, row["id"])
                }
                data-overview-open
                class="preview-result-link"
                title={target_label(row["target"]) <> " · " <> result_title(row)}
              >{target_label(row["target"])}{" "}<span>{result_title(row)}</span></.link>
              <p class="preview-caption preview-result-context" title={row_context(row)}>
                {row["environment_label"] || row["environment"] || "Unscoped"} · {row[
                  "runner_display"
                ]}
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
    ~H"""
    <h2 id="overview-panel-title" tabindex="-1" class="pf-v6-c-title pf-m-xl">
      {target_label(@panel.selected["target"])}
    </h2>
    <p class="preview-panel-subtitle">
      {result_title(@panel.selected)} · {@panel.selected["environment_label"] ||
        @panel.selected["environment"] || "Unscoped"}
    </p>
    <p class="preview-caption" title={@panel.selected["source_key"]}>
      Source: {@panel.selected["source_id"]}
    </p>
    <p :if={@panel.selected["retired"]} class="preview-empty">
      This result is retired. Its last measurement is historical.
    </p>
    <section
      :for={observer <- [@panel.selected]}
      id={"observer-" <> observer["id"]}
      class="preview-evidence"
    >
      <h3 class="pf-v6-c-title pf-m-md">{observer["runner_label"] || "Runner not recorded"}</h3>
      <p class="preview-caption">Runner {observer["runner_id"]}</p>
      <div class="preview-evidence-state">
        <.state value={measured_health(observer)} /><.state value={
          get_in(observer, ["current", "knowledge"])
        } />
      </div>
      <p>{summary(observer)}</p>
      <p :if={confirmed?(observer)} class="preview-caption">
        Measured
        <time datetime={observer["current"]["source_at"]}>{age(observer["current"]["source_at"], @now)}</time>
        · {time(observer["current"]["source_at"])}
      </p>
      <p
        :if={get_in(observer, ["current", "knowledge"]) == "unavailable"}
        class="preview-collection-error"
      >
        Latest collection: {MondekWeb.MonitoringUI.collection_diagnostic(observer["current"]) ||
          "Collection failed. The last confirmed measurement is retained."}
      </p>
      <pre
        :if={confirmed?(observer) && observer["current"]["details"] not in [nil, ""]}
        class="preview-findings"
      >{observer["current"]["details"]}</pre>
      <a
        class="pf-v6-c-button pf-m-link"
        href={"/checks/" <> observer["id"] <> "?" <> URI.encode_query(%{"return_to" => @current_path})}
      >Full result and configuration</a>
    </section>
    <section
      :if={Enum.any?(@panel.inspection["incidents"], &(&1["status"] == "open"))}
      class="preview-evidence"
    >
      <h3 class="pf-v6-c-title pf-m-md">Open health incidents for the selected observation</h3>
      <p :for={incident <- Enum.filter(@panel.inspection["incidents"], &(&1["status"] == "open"))}>
        <a href={MonitoringUI.parent_incident_path(incident, @current_path)}>Inspect incident and acknowledgement</a>
      </p>
    </section>
    <details :if={@panel.total > 1} id="preview-related-results" class="preview-evidence">
      <summary>Related results for this scope ({@panel.total - 1})</summary>
      <p class="preview-caption">
        These declarations match the same scope. Code, settings and collection access can differ.
      </p>
      <p :for={peer <- Enum.reject(@panel.items, &(&1["id"] == @panel.selected["id"]))}>
        <.link patch={path(@filters, :result, peer["id"])}>{peer["runner_label"] || "Runner"} · {String.slice(
          peer["runner_id"] || "",
          0,
          8
        )}</.link>
        <.state value={measured_health(peer)} /><.state value={get_in(peer, ["current", "knowledge"])} />
      </p>
      <p :if={@panel.total > length(@panel.items)} class="preview-caption">
        Showing {length(@panel.items) - 1} of {@panel.total - 1} other results. <a href="/checks">Browse all results</a>.
      </p>
    </details>
    """
  end

  defp expected_panel(assigns) do
    ~H"""
    <h2 id="overview-panel-title" tabindex="-1" class="pf-v6-c-title pf-m-xl">
      {target_label(@panel.scope["target"])}
    </h2>
    <p class="preview-panel-subtitle">
      {scope_title(@panel.scope)} · {@panel.scope["environment_label"] || @panel.scope["environment"] ||
        "Unscoped"}
    </p>
    <.state value={@panel.scope["status"]} />
    <p class="preview-expected-description">
      {if @panel.scope["counts"]["selected"] == 0,
        do: "No runner is selected to measure this declared result.",
        else: "Runner selection has changed. The observations below show its current state."}
    </p>
    <section :for={observer <- @panel.observers["items"]} class="preview-evidence">
      <h3 class="pf-v6-c-title pf-m-md">{observer["runner_label"]}</h3>
      <p class="preview-caption">Runner {observer["runner_id"]}</p>
      <p>
        {observer["exclusion_reason"] || observer["scope_reason"] || observer["measurement_state"]}
      </p>
      <p :if={observer["stream_id"] && confirmed?(observer)}>
        {summary(observer)} · {age(observer["current"]["source_at"], @now)}
      </p>
      <a
        :if={observer["stream_id"]}
        href={"/checks/" <> observer["stream_id"] <> "?" <> URI.encode_query(%{"return_to" => @current_path})}
        class="pf-v6-c-button pf-m-link"
      >Inspect result</a>
    </section>
    <p :if={@panel.observers["total"] > length(@panel.observers["items"])} class="preview-caption">
      Showing {length(@panel.observers["items"])} of {@panel.observers["total"]} declarations.
    </p>
    <p class="preview-expected-description">
      Check the monitoring project's placement rules and the runner's deployment settings.
    </p>
    <a
      href={"/coverage/" <> @panel.scope["id"] <> "?" <> URI.encode_query(%{"return_to" => @current_path})}
      class="pf-v6-c-button pf-m-link"
    >Full declaration and placement details</a>
    """
  end

  defp pager(assigns) do
    assigns =
      assign(assigns, pages: max(1, ceil(assigns.listing.total / assigns.listing.page_size)))

    ~H"""
    <nav class="preview-pager" aria-label={@label}>
      <span>{count_label(
        @listing.total,
        if(@label == "Unobserved declarations", do: "monitoring gap", else: "result")
      )} · page {@listing.page} of {@pages}</span>
      <.link
        :if={@listing.page > 1}
        patch={path(Map.put(@filters, @key, to_string(@listing.page - 1)))}
        class="pf-v6-c-button pf-m-secondary"
      >Previous</.link>
      <.link
        :if={@listing.page < @pages}
        patch={path(Map.put(@filters, @key, to_string(@listing.page + 1)))}
        class="pf-v6-c-button pf-m-secondary"
      >Next</.link>
    </nav>
    """
  end

  attr :value, :any, required: true

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

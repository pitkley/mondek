# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageLive do
  use MondekWeb, :live_view

  alias Mondek.Coverage
  alias MondekWeb.AgentPrompts
  alias Phoenix.LiveView.JS

  @statuses ~w(missing awaiting partial stale unavailable unconfirmed observed)

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       navigation_counts: Mondek.Inspection.navigation_counts(now),
       page_title: "Coverage",
       filters: %{},
       filter_draft: %{},
       controller_url: MondekWeb.Endpoint.url(),
       listing: %{},
       scope: nil,
       selected_id: nil,
       return_to: "/coverage",
       now: now
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    filters = normalize_filters(params)
    origin = URI.parse(uri)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_draft: filters,
       controller_url:
         URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port}),
       selected_id: params["id"],
       return_to:
         filters["return_to"] ||
           list_path(filters |> Map.put("page", filters["list_page"]) |> Map.delete("list_page")),
       now: DateTime.utc_now()
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, socket |> assign(now: DateTime.utc_now()) |> refresh()}
  end

  @impl true
  def handle_event("filter", form, socket) do
    filters = form |> normalize_filters() |> Map.drop(["page", "list_page"]) |> clean_filters()
    {:noreply, push_patch(socket, to: path(socket.assigns.live_action, nil, filters))}
  end

  def handle_event(event, form, socket) when event in ["filter_change", "recover_filters"] do
    {:noreply, assign(socket, filter_draft: normalize_filters(form))}
  end

  defdelegate normalize_filters(params), to: MondekWeb.CoverageNavigation, as: :filters

  defp refresh(socket) do
    %{filters: filters, now: now} = socket.assigns
    socket = assign(socket, navigation_counts: Mondek.Inspection.navigation_counts(now))

    case socket.assigns.live_action do
      :index ->
        assign(socket, listing: Coverage.scopes(filters, now), scope: nil)

      :show ->
        id = socket.assigns.selected_id

        assign(socket,
          scope: Coverage.scope(id, now),
          listing: Coverage.observers(id, Map.take(filters, ["page"]), now)
        )

      :publishers ->
        assign(socket, listing: Coverage.publishers(filters, now), scope: nil)

      :diagnostics ->
        assign(socket, listing: Coverage.diagnostics(filters, now), scope: nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={:coverage}
      page_title="Coverage"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
      main_class="coverage-page"
      updated_time_id="coverage-updated"
    >
      <MondekWeb.Layouts.section_header
        section="Coverage"
        description="Which results should exist, which runners are selected, and whether measurements are arriving."
        nav_label="Coverage views"
      >
        <:tabs>
          <.link navigate="/coverage" aria-current={if @live_action in [:index, :show], do: "page"}>Intended results</.link>
          <.link
            navigate="/coverage/publishers"
            aria-current={if @live_action == :publishers, do: "page"}
          >Runner declarations</.link>
          <.link
            navigate="/coverage/diagnostics"
            aria-current={if @live_action == :diagnostics, do: "page"}
          >Unresolved declarations</.link>
        </:tabs>
      </MondekWeb.Layouts.section_header>
      <.link :if={@live_action == :show || @filters["return_to"]} navigate={@return_to} class="back">{MondekWeb.InvestigationNavigation.return_label(
        @filters["return_to"],
        "All intended results"
      )}</.link>
      <div class="page-heading view-heading">
        <div>
          <h2>{heading(@live_action, @scope)}</h2>
        </div>
      </div>
      <div :if={@live_action == :index} class="notice info notice-copy" id="coverage-explanation">
        <p>
          Coverage compares checks declared in code with measurements received. Each row is one intended result for a target and monitored environment, even before any runner is selected.
        </p>
        <p class="space-top">
          Being selected to run is not proof of a measurement. Fresh results establish coverage even when their health is Critical;
          <.link navigate="/checks" class="text-link">Checks</.link>
          shows measured health.
        </p>
        <p class="space-top" id="coverage-boundary">
          Targets and checks that nobody has declared remain unknown. Declare a target roster in code to detect missing runners, including nodes that have never connected.
        </p>
        <p class="space-top">
          Prolonged missing or unusable measurements have a separate
          <.link navigate="/monitoring-incidents" class="text-link">monitoring-loss incident and notification history</.link>
          after a grace period.
        </p>
      </div>
      <.scope_list
        :if={@live_action == :index}
        listing={@listing}
        filters={@filters}
        draft={@filter_draft}
      />
      <.scope_detail
        :if={@live_action == :show}
        scope={@scope}
        listing={@listing}
        filters={@filters}
        now={@now}
      />
      <.publisher_list
        :if={@live_action == :publishers}
        listing={@listing}
        filters={@filters}
        draft={@filter_draft}
      />
      <.diagnostic_list
        :if={@live_action == :diagnostics}
        listing={@listing}
        filters={@filters}
        draft={@filter_draft}
      />
      <AgentPrompts.library
        id="coverage-agent-prompts"
        kinds={[:coverage]}
        context={Map.put(prompt_context(@scope), "controller_url", @controller_url)}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp scope_list(assigns) do
    assigns = assign(assigns, summary: assigns.listing["summary"] || %{})

    ~H"""
    <section
      class="coverage-summary"
      aria-label="Coverage for matching intended results"
      id="declared-coverage-summary"
    >
      <div><span>Intended results</span><strong>{@summary["scopes"] || 0}</strong></div>
      <div>
        <span>With fresh measurements</span><strong>{count(@summary, "observed") +
          count(@summary, "partial")}</strong>
      </div>
      <div><span>No selected runner</span><strong>{count(@summary, "missing")}</strong></div>
    </section>
    <p
      :if={count(@summary, "awaiting_publishers") > 0}
      id="coverage-restoration-warning"
      class="notice notice-copy space-top"
    >
      {count(@summary, "awaiting_publishers")} source publications are waiting for a new inventory after restoration. Previous declarations and health do not establish current coverage.
      <.link navigate="/coverage/publishers?lifecycle=awaiting_inventory" class="text-link">Inspect waiting publications</.link>
    </p>
    <p :if={count(@summary, "retired_publishers") > 0} class="footnote space-top">
      Retired source publications: {count(@summary, "retired_publishers")}.
      <.link navigate="/coverage/publishers?lifecycle=retired" class="text-link">Inspect retained publication history</.link>
    </p>
    <p
      :if={count(@summary, "unsupported_publishers") + count(@summary, "unconfirmed_publishers") > 0}
      class="notice notice-copy space-top"
      id="coverage-audit-warning"
    >
      Coverage is incomplete. Sources missing coverage support: {count(
        @summary,
        "unsupported_publishers"
      )}. Sources with unconfirmed declarations: {count(
        @summary,
        "unconfirmed_publishers"
      )}. <.link navigate="/coverage/publishers" class="text-link">Inspect runner declarations</.link>
    </p>
    <p :if={count(@summary, "unbound_declarations") > 0} class="footnote space-top">
      {count(@summary, "unbound_declarations")} declarations cannot yet identify their intended results.
      <.link navigate="/coverage/diagnostics" class="text-link">Inspect unresolved declarations</.link>
    </p>
    <.filters filters={@filters} draft={@draft} status={true} action={:index} />
    <p :if={@filters["runner_id"] not in [nil, ""]} class="notice notice-copy space-top">
      Showing results declared by this runner. Counts and measurements include every runner declaring each result.
    </p>
    <section
      class="panel"
      id="coverage-scopes"
      aria-labelledby="coverage-scopes-heading"
      tabindex="-1"
      phx-hook="InventoryNavigation"
      data-page-controls="[data-coverage-pagination]"
      data-page-path={page_path(:index, nil, @filters, @listing)}
    >
      <div class="panel-heading">
        <h2 id="coverage-scopes-heading">{@listing["total"] || 0} matching intended results</h2>
      </div>
      <.pagination listing={@listing} filters={@filters} action={:index} id="coverage-pages-top" />
      <div :if={@listing["items"] == []} class="panel-body coverage-empty">
        <h3>
          {if clean_filters(@filters) == %{},
            do: "No intended results declared yet",
            else: "No intended results match these filters"}
        </h3>
        <p>
          Runners report checks from their source code automatically. Inspect runner declarations for missing coverage support or unresolved targets.
        </p>
        <.link navigate="/coverage/publishers" class="text-link">Inspect runner declarations</.link>
      </div>
      <article
        :for={scope <- @listing["items"] || []}
        class="coverage-scope"
        data-scope-id={scope["id"]}
      >
        <div class="coverage-scope-title">
          <div>
            <h3>
              <.link
                navigate={
                  path(
                    :show,
                    scope["id"],
                    Map.put(Map.delete(@filters, "page"), "list_page", @listing["page"])
                  )
                }
                class="text-link"
              >{result_title(scope)}</.link>
            </h3>
            <p>
              {scope["target"]["label"]}
              <span aria-hidden="true">·</span> {scope["environment_label"] || scope["environment"] ||
                "Unscoped"}
            </p>
            <small>{scope["source_id"]}</small>
          </div>
          <span class={status_class(scope["status"])}>{status_label(scope["status"])}</span>
        </div>
        <p class="coverage-observer-count">
          Fresh measurements: {count(scope["counts"], "fresh")} of {count(scope["counts"], "selected")} selected runners
          <span aria-hidden="true">·</span>
          Declared by {count(scope["counts"], "declaring")} {if count(scope["counts"], "declaring") ==
                                                                  1, do: "runner", else: "runners"}
        </p>
        <p :if={count(scope["counts"], "unconfirmed") > 0} class="footnote">
          {count(scope["counts"], "unconfirmed")} last-known declarations remain unconfirmed.
        </p>
        <p :if={mixed?(scope)} class="footnote">
          Published code, runtime or declarations differ. Inspect observers before comparing deployment versions.
        </p>
      </article>
      <.pagination listing={@listing} filters={@filters} action={:index} id="coverage-pages-bottom" />
    </section>
    """
  end

  defp scope_detail(assigns) do
    ~H"""
    <div :if={is_nil(@scope)} class="panel panel-body coverage-empty" id="coverage-scope-missing">
      <h2>This scope is no longer declared</h2><p>
        Publishing runners may have withdrawn it or changed its identity. Retained check and incident history remains available.
      </p>
      <.link navigate="/checks" class="text-link">Inspect checks and history</.link>
    </div>
    <section :if={@scope} class="panel" id="coverage-scope-detail">
      <div class="panel-heading">
        <h2>Measurement coverage</h2><span class={status_class(@scope["status"])}>{status_label(
          @scope["status"]
        )}</span>
      </div>
      <div class="panel-body">
        <p class="coverage-explanation">{status_explanation(@scope["status"])}</p>
        <p :if={@scope["status"] == "missing"} class="space-top">
          <.link
            navigate={"/monitoring-incidents?" <> URI.encode_query(%{"source_id" => @scope["source_id"]})}
            class="text-link"
          >Inspect monitoring-loss notifications for this source</.link>
        </p>
        <p class="space-top">
          Fresh measurements: {count(@scope["counts"], "fresh")} of {count(
            @scope["counts"],
            "selected"
          )} selected runners. {count(
            @scope["counts"],
            "declaring"
          )} {if count(@scope["counts"], "declaring") == 1,
            do: "runner declares",
            else: "runners declare"} this result.
        </p>
        <p :if={count(@scope["counts"], "unconfirmed") > 0} class="notice notice-copy space-top">
          {count(@scope["counts"], "unconfirmed")} last-known declarations remain unconfirmed and do not establish current placement or coverage.
        </p>
        <p :if={mixed?(@scope)} class="notice notice-copy space-top">
          Publishers report different code, runtime or declaration versions. Each observer's measurement is checked against its own desired configuration; no shared latest release is inferred.
        </p>
        <dl class="coverage-identity">
          <div>
            <dt>Target</dt><dd>
              {@scope["target"]["label"]}
              <code>{@scope["target"]["kind"]}:{@scope["target"]["key"]}</code>
            </dd>
          </div>
          <div>
            <dt>Monitored environment</dt><dd>
              {@scope["environment_label"] || @scope["environment"] || "Unscoped"}
              <code>{@scope["environment"] || "null"}</code>
            </dd>
          </div>
          <div>
            <dt>Source</dt><dd><code>{@scope["source_id"]}</code></dd>
          </div>
          <div>
            <dt>Check / result</dt><dd>
              <code>{@scope["source_key"]}</code> / <code>{@scope["result_key"]}</code>
            </dd>
          </div>
        </dl>
      </div>
    </section>
    <section
      :if={@scope}
      class="panel"
      id="coverage-observers"
      aria-labelledby="coverage-observers-heading"
      tabindex="-1"
      phx-hook="InventoryNavigation"
      data-page-controls="[data-coverage-pagination]"
      data-page-path={page_path(:show, @scope["id"], @filters, @listing)}
    >
      <div class="panel-heading">
        <h2 id="coverage-observers-heading">Runners declaring this result</h2>
      </div>
      <p class="panel-body">
        Each runner keeps its own measurements, health and incident history. Selection follows requirements in check and datasource code; it does not prove credentials or connectivity work.
        Shared runners can monitor other environments when placement allows it.
      </p>
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:show}
        scope_id={@scope["id"]}
        id="coverage-observer-pages-top"
      />
      <.observer
        :for={observer <- @listing["items"] || []}
        observer={observer}
        return_to={path(:show, @scope["id"], @filters)}
      />
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:show}
        scope_id={@scope["id"]}
        id="coverage-observer-pages-bottom"
      />
    </section>
    """
  end

  defp observer(assigns) do
    ~H"""
    <article class="coverage-scope" data-runner-id={@observer["runner_id"]}>
      <div class="coverage-scope-title">
        <h3>
          <.link
            navigate={MondekWeb.RunnersLive.detail_path(@observer["runner_id"], @return_to)}
            class="text-link"
          >{@observer[
            "runner_label"
          ] || @observer["runner_id"]}</.link>
        </h3>
        <span class="badge">{measurement_label(@observer["measurement_state"])}</span>
      </div>
      <p :if={!@observer["audit_confirmed"]} class="notice notice-copy space-top">
        Last-known declaration. The runner's current inventory no longer confirms whether it should collect this result.
      </p>
      <p class="space-top">
        {if @observer["selected"], do: "Selected to execute", else: "Excluded from execution"}<span :if={
          @observer["exclusion_reason"]
        }>: {@observer["exclusion_reason"]}</span>
      </p>
      <p :if={get_in(@observer, ["runner_context", "local_environment"])} class="footnote space-top">
        Runner executes in: <strong>{@observer["runner_context"]["local_environment"]}</strong>.
      </p>
      <p :if={@observer["older_version"]} class="space-top">
        Fresh evidence belongs to an earlier configuration. Waiting for a measurement from the desired version.
      </p>
      <p class="footnote space-top">
        Last controller contact: {utc(@observer["last_seen_at"])}. Contact alone does not establish measurement coverage.
      </p>
      <p :if={get_in(@observer, ["current", "confirmed_observation_id"])} class="space-top">
        Last measured health: {health_label(@observer["current"]["health"])}
        <span aria-hidden="true">·</span> Source time: {utc(@observer["current"]["source_at"])}
      </p>
      <div class="actions space-top">
        <.link
          :if={
            @observer["stream_id"] && @observer["selected"] && @observer["audit_confirmed"] &&
              !@observer["older_version"] && @observer["measurement_state"] != "fresh"
          }
          navigate={result_path("/checks/" <> @observer["stream_id"] <> "/diagnostics", @return_to)}
          class="button primary small"
        >Investigate measurement</.link>
        <.link
          :if={!@observer["stream_id"] || !@observer["audit_confirmed"] || !@observer["selected"]}
          navigate={MondekWeb.RunnersLive.detail_path(@observer["runner_id"], @return_to)}
          class="button small"
        >{if @observer["audit_confirmed"] && !@observer["selected"],
          do: "Inspect runner context",
          else: "Inspect runner publication"}</.link>
        <.link
          :if={@observer["stream_id"]}
          navigate={result_path("/checks/" <> @observer["stream_id"], @return_to)}
          class="button small"
        >Inspect result</.link>
        <.link
          :if={@observer["assignment_id"]}
          navigate={result_path("/configuration/" <> @observer["assignment_id"], @return_to)}
          class={
            if @observer["older_version"], do: "button primary small", else: "button small secondary"
          }
        >{if @observer["older_version"],
          do: "Review pending configuration",
          else: "Inspect configuration"}</.link>
      </div>
      <details
        class="diagnostic-details space-top"
        id={"coverage-observer-versions-" <> to_string(@observer["id"])}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Declaration and deployment details</summary>
        <.versions item={@observer} />
      </details>
    </article>
    """
  end

  defp publisher_list(assigns) do
    ~H"""
    <p class="notice notice-copy">
      Runners report which checks their source code provides, including checks excluded by placement. Offline runners remain visible so that lost monitoring is not mistaken for intentionally removed checks.
    </p>
    <.filters filters={@filters} draft={@draft} status={false} action={:publishers} />
    <section
      class="panel"
      id="coverage-publishers"
      tabindex="-1"
      phx-hook="InventoryNavigation"
      data-page-controls="[data-coverage-pagination]"
      data-page-path={page_path(:publishers, nil, @filters, @listing)}
      aria-label="Source publications"
    >
      <div class="panel-heading">
        <h2>{@listing["total"] || 0} source publications</h2>
      </div>
      <div :if={@listing["items"] == []} class="panel-body coverage-empty">
        <h3>No matching publications</h3><p>
          {if clean_filters(@filters) == %{},
            do: "Attach a runner to publish its source inventory and coverage declarations.",
            else: "Clear or adjust the filters to inspect other source publications."}
        </p><.link navigate="/guide" class="text-link">Runner setup</.link>
      </div>
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:publishers}
        id="coverage-publisher-pages-top"
      />
      <article
        :for={publisher <- @listing["items"] || []}
        class="coverage-scope"
        data-publisher-id={publisher["id"]}
      >
        <div class="coverage-scope-title">
          <h3>
            <.link
              navigate={
                MondekWeb.RunnersLive.detail_path(
                  publisher["runner_id"],
                  path(:publishers, nil, @filters)
                )
              }
              class="text-link"
            >{publisher[
              "runner_label"
            ] || publisher["runner_id"]}</.link>
          </h3><span class="badge">{publisher_label(publisher)}</span>
        </div>
        <p>{publisher["source_id"]}</p>
        <p :if={publisher["lifecycle_status"] == "retired"} class="notice space-top">
          Retired from this controller. Counts below describe retained declarations; this publication does not establish active coverage.
        </p>
        <p :if={publisher["lifecycle_status"] == "awaiting_inventory"} class="notice space-top">
          Waiting for a new publication. Retained declarations and previous measurements do not establish current coverage.
        </p>
        <p :if={publisher["audit_status"] == "unsupported"} class="space-top">
          This runner reports its selected checks, but not the complete set of intended results. Update the runner SDK to enable coverage auditing.
        </p>
        <p :if={publisher["audit_status"] == "unconfirmed"} class="space-top">
          Previous declarations remain visible, but the runner's current inventory no longer confirms them. Restore coverage support before relying on these declarations.
        </p>
        <p
          :if={
            publisher["lifecycle_status"] == "active" && publisher["audit_status"] == "confirmed" &&
              publisher["candidates"] == 0
          }
          class="space-top"
        >
          This runner explicitly declares no checks for this source.
        </p>
        <p :if={publisher["coverage_version"] && publisher["candidates"] > 0} class="space-top">
          {publisher["candidates"]} declared checks; {publisher["declarations"] - publisher["unbound"]} resolved result declarations; {publisher[
            "unbound"
          ]} unresolved.
        </p>
        <p class="footnote space-top">
          Last controller contact: {utc(publisher["last_seen_at"])}. Inventory accepted: {utc(
            publisher["received_at"]
          )}.
        </p>
        <p :if={publisher["coverage_received_at"]} class="footnote space-top">
          Last supported catalogue accepted: {utc(publisher["coverage_received_at"])}.
        </p>
        <div class="actions space-top">
          <.link navigate={"/coverage/publishers/#{publisher["id"]}"} class="text-link">Manage publication</.link>
          <.link
            :if={publisher["lifecycle_status"] == "active"}
            navigate={
              list_path(%{
                "runner_id" => publisher["runner_id"],
                "source_id" => publisher["source_id"]
              })
            }
            class="text-link"
          >Intended results</.link>
        </div>
        <details
          class="diagnostic-details space-top"
          id={"coverage-publisher-versions-" <> to_string(publisher["id"])}
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Publication details</summary><.versions item={publisher} />
        </details>
      </article>
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:publishers}
        id="coverage-publisher-pages-bottom"
      />
    </section>
    """
  end

  defp diagnostic_list(assigns) do
    ~H"""
    <p class="notice notice-copy">
      These checks cannot yet identify all their intended results. They may lack a concrete environment or target, or use custom metadata that cannot describe excluded checks. Inspect each reason below; these declarations are excluded from the intended-result counts.
    </p>
    <.filters filters={@filters} draft={@draft} status={false} action={:diagnostics} />
    <section
      class="panel"
      id="coverage-diagnostics"
      tabindex="-1"
      phx-hook="InventoryNavigation"
      data-page-controls="[data-coverage-pagination]"
      data-page-path={page_path(:diagnostics, nil, @filters, @listing)}
      aria-label="Unresolved declarations"
    >
      <div class="panel-heading">
        <h2>{@listing["total"] || 0} unresolved declarations</h2>
      </div>
      <p :if={@listing["items"] == []} class="panel-body">
        No unresolved declarations match this selection.
      </p>
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:diagnostics}
        id="coverage-diagnostic-pages-top"
      />
      <article :for={item <- @listing["items"] || []} class="coverage-scope">
        <h3>{result_title(item)}</h3><p>
          {item["source_id"]} · {item["runner_label"]}
        </p>
        <p :if={!item["audit_confirmed"]} class="notice notice-copy space-top">
          Last-known declaration. The current inventory no longer confirms this catalogue.
        </p>
        <p class="footnote space-top">
          Last supported catalogue accepted: {utc(item["coverage_received_at"])}.
        </p>
        <p class="space-top">{item["scope_reason"]}</p><p
          :if={item["exclusion_reason"]}
          class="space-top"
        >
          Placement: {item["exclusion_reason"]}
        </p>
        <.link
          navigate={
            MondekWeb.RunnersLive.detail_path(item["runner_id"], path(:diagnostics, nil, @filters))
          }
          class="text-link"
        >Inspect publishing runner</.link>
      </article>
      <.pagination
        listing={@listing}
        filters={@filters}
        action={:diagnostics}
        id="coverage-diagnostic-pages-bottom"
      />
    </section>
    """
  end

  defp versions(assigns) do
    ~H"""
    <dl class="coverage-identity">
      <div :if={@item["runner_context"] not in [nil, %{}]}>
        <dt>Execution context</dt><dd>
          {@item["runner_context"]["label"]} <code>{@item["runner_context"]["id"]}</code>
        </dd>
      </div>
      <div :if={get_in(@item, ["runner_context", "local_environment"])}>
        <dt>Execution environment</dt><dd>{@item["runner_context"]["local_environment"]}</dd>
      </div>
      <div :if={@item["desired_generation"]}>
        <dt>Desired configuration</dt><dd>
          Version {@item["desired_generation"]}; active {@item["active_generation"] || "not reported"}
        </dd>
      </div>
      <div>
        <dt>Package code</dt><dd><code>{@item["code_revision"] || "Not reported"}</code></dd>
      </div>
      <div>
        <dt>Runtime</dt><dd><code>{@item["runtime_revision"] || "Not reported"}</code></dd>
      </div>
      <div :if={@item["definition_revision"]}>
        <dt>Declaration</dt><dd><code>{@item["definition_revision"]}</code></dd>
      </div>
      <div>
        <dt>Runner identity</dt><dd><code>{@item["runner_id"]}</code></dd>
      </div>
    </dl>
    """
  end

  defp filters(assigns) do
    assigns = assign(assigns, statuses: @statuses)

    ~H"""
    <form
      id="coverage-filters"
      class="coverage-filters"
      phx-submit="filter"
      phx-change="filter_change"
      phx-auto-recover="recover_filters"
    >
      <input :if={@draft["return_to"]} type="hidden" name="return_to" value={@draft["return_to"]} />
      <label for="coverage-search">Search<input
        id="coverage-search"
        name="search"
        value={@draft["search"]}
        placeholder={
          case @action do
            :publishers -> "Source, runner or context"
            :diagnostics -> "Check, source or reason"
            _ -> "Check, target or source"
          end
        }
      /></label>
      <label for="coverage-environment">Monitored environment ID<input
        id="coverage-environment"
        name="environment"
        value={@draft["environment"]}
      /></label>
      <label for="coverage-source">Source ID<input
        id="coverage-source"
        name="source_id"
        value={@draft["source_id"]}
      /></label>
      <label :if={@status} for="coverage-status">Coverage<select id="coverage-status" name="status"><option
        value=""
        selected={@draft["status"] in [nil, ""]}
      >
        All coverage
      </option><option
        :for={status <- @statuses}
        value={status}
        selected={@draft["status"] == status}
      >
        {status_label(status)}
      </option></select></label>
      <input :if={@filters["runner_id"]} type="hidden" name="runner_id" value={@filters["runner_id"]} />
      <label :if={@action == :publishers} for="coverage-lifecycle">Publication state<select
        id="coverage-lifecycle"
        name="lifecycle"
      >
        <option
          :for={
            {value, label} <- [
              {"all", "All publications"},
              {"active", "Active publications"},
              {"retired", "Retired from this controller"},
              {"awaiting_inventory", "Waiting for a new publication"}
            ]
          }
          value={value}
          selected={(@draft["lifecycle"] || "all") == value}
        >
          {label}
        </option>
      </select></label>
      <button class="button" type="submit">Apply filters</button>
      <.link :if={clean_filters(@filters) != %{}} patch={path(@action, nil, %{})} class="text-link">Clear filters</.link>
    </form>
    """
  end

  attr :listing, :map, required: true
  attr :filters, :map, required: true
  attr :action, :atom, required: true
  attr :scope_id, :string, default: nil
  attr :id, :string, required: true

  defp pagination(assigns) do
    assigns = assign(assigns, page: assigns.listing["page"] || 1, pages: pages(assigns.listing))

    ~H"""
    <nav
      :if={@pages > 1}
      class="pagination"
      id={@id}
      data-coverage-pagination
      aria-label={
        if String.ends_with?(@id, "top"),
          do: "Coverage pages above results",
          else: "Coverage pages below results"
      }
    >
      <.link
        :if={@page > 1}
        patch={path(@action, @scope_id, Map.put(@filters, "page", @page - 1))}
        phx-click={page_focus(@action, @scope_id, @filters, @page - 1)}
        class="button small"
      >Previous</.link>
      <span role={if String.ends_with?(@id, "top"), do: "status"}>Page {@page} of {@pages}</span>
      <.link
        :if={@page < @pages}
        patch={path(@action, @scope_id, Map.put(@filters, "page", @page + 1))}
        phx-click={page_focus(@action, @scope_id, @filters, @page + 1)}
        class="button small"
      >Next</.link>
    </nav>
    """
  end

  defp heading(:show, scope), do: if(scope, do: result_title(scope), else: "Intended result")
  defp heading(:publishers, _), do: "Runner declarations"
  defp heading(:diagnostics, _), do: "Unresolved declarations"
  defp heading(_, _), do: "Intended results"

  defp result_title(%{"check_label" => label, "result_label" => label}), do: label
  defp result_title(item), do: item["check_label"] <> " · " <> item["result_label"]

  defp count(map, key), do: (map || %{})[key] || 0
  defp pages(listing), do: max(1, ceil((listing["total"] || 0) / (listing["page_size"] || 25)))

  defp mixed?(scope),
    do: Enum.any?(~w(code_variants runtime_variants definition_variants), &(count(scope, &1) > 1))

  defp clean_filters(filters),
    do:
      Map.reject(filters, fn {key, value} ->
        value in [nil, ""] or (key in ["page", "list_page"] and value in [1, "1"])
      end)

  defp list_path(filters), do: path(:index, nil, filters)

  defp page_path(action, id, filters, listing),
    do: path(action, id, Map.put(filters, "page", listing["page"]))

  defp page_focus(action, id, filters, page) do
    target =
      case action do
        :show -> "#coverage-observers"
        :publishers -> "#coverage-publishers"
        :diagnostics -> "#coverage-diagnostics"
        _ -> "#coverage-scopes"
      end

    JS.dispatch("mondek:inventory-page",
      to: target,
      detail: %{path: path(action, id, Map.put(filters, "page", page))}
    )
  end

  defp path(action, id, filters) do
    base =
      case action do
        :show -> "/coverage/" <> id
        :publishers -> "/coverage/publishers"
        :diagnostics -> "/coverage/diagnostics"
        _ -> "/coverage"
      end

    query = filters |> clean_filters() |> Enum.sort() |> URI.encode_query()
    base <> if(query == "", do: "", else: "?" <> query)
  end

  defp result_path(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp status_label("missing"), do: "No selected runner"
  defp status_label("awaiting"), do: "Awaiting current measurement"
  defp status_label("partial"), do: "Partial runner coverage"
  defp status_label("stale"), do: "Measurements are stale"
  defp status_label("unavailable"), do: "Collection unavailable"
  defp status_label("unconfirmed"), do: "Declarations unconfirmed"
  defp status_label("observed"), do: "Fresh measurements available"
  defp status_label(_), do: "Coverage unknown"
  defp status_class("observed"), do: "badge fresh"
  defp status_class(_), do: "badge pending"

  defp status_explanation("missing"),
    do:
      "No runner with a confirmed declaration is selected to collect this result. Review the placement reasons below, then adjust runner context or check and datasource requirements in code. Credentials and network access do not change placement."

  defp status_explanation("observed"),
    do:
      "All selected runners have fresh measurements using their current saved settings. This confirms monitoring coverage, not healthy results; measurement health is shown separately."

  defp status_explanation("partial"),
    do:
      "At least one runner has a fresh measurement, but another lacks one or has an unconfirmed declaration. Each runner measures independently; one result does not replace another runner's perspective."

  defp status_explanation("unconfirmed"),
    do:
      "The runners' current inventories no longer confirm these intended results. Previous declarations remain visible, but coverage is uncertain until the runners report them again."

  defp status_explanation("awaiting"),
    do:
      "A runner is selected, but no fresh measurement uses the current saved settings yet. Inspect the runner and its configuration below to check whether execution has started and the settings have been applied."

  defp status_explanation("stale"),
    do:
      "The last measurements are too old to establish current coverage. Inspect the selected runners and their results for collection or connectivity problems."

  defp status_explanation("unavailable"),
    do:
      "The runner could not produce a complete measurement. Choose Investigate measurement on the affected runner below for collection details. A previous health result remains historical context and does not restore coverage."

  defp status_explanation(_),
    do: "Inspect runner declarations and measurements to establish coverage."

  defp health_label("OK"), do: "Healthy"
  defp health_label("WARN"), do: "Warning"
  defp health_label("CRIT"), do: "Critical"
  defp health_label(_), do: "Unknown"
  defp measurement_label("fresh"), do: "Fresh measurement"
  defp measurement_label("excluded"), do: "Not selected here"
  defp measurement_label("older_version"), do: "Earlier configuration measured"
  defp measurement_label("unadmitted"), do: "Not accepted for execution"
  defp measurement_label("stale"), do: "Measurement overdue"
  defp measurement_label("pending"), do: "Awaiting measurement"
  defp measurement_label(value), do: status_label(value)
  defp publisher_label(%{"lifecycle_status" => "retired"}), do: "Retired from this controller"

  defp publisher_label(%{"lifecycle_status" => "awaiting_inventory"}),
    do: "Waiting for a new publication"

  defp publisher_label(%{"audit_status" => "confirmed"}), do: "Declarations confirmed"
  defp publisher_label(%{"audit_status" => "unconfirmed"}), do: "Declarations unconfirmed"
  defp publisher_label(_), do: "Intended checks unknown"
  defp utc(nil), do: "Not reported"
  defp utc(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> utc(datetime)
      _ -> "Not reported"
    end
  end

  defp utc(_), do: "Not reported"
  defp prompt_context(nil), do: %{"page_path" => "/coverage"}

  defp prompt_context(scope) do
    %{
      "page_path" => "/coverage/" <> scope["id"],
      "source_id" => scope["source_id"],
      "check_key" => scope["source_key"],
      "check_name" => scope["check_label"],
      "result_key" => scope["result_key"],
      "monitored_environment" => scope["environment"],
      "target_id" => scope["target"]["key"],
      "target_kind" => scope["target"]["kind"],
      "target_name" => scope["target"]["label"]
    }
  end
end

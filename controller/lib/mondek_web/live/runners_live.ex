# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnersLive do
  use MondekWeb, :live_view

  alias Phoenix.LiveView.JS
  alias Mondek.{Monitoring, RunnerFleet}
  alias MondekWeb.{AgentPrompts, Layouts}

  @filter_keys ~w(search contact collection source_id sort page page_size)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       page_title: "Runners",
       filters: %{},
       draft: nil,
       listing: %{},
       runner: nil,
       selected_id: nil,
       return_to: nil,
       snapshot: %{},
       now: Monitoring.now(),
       controller_url: MondekWeb.Endpoint.url()
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    cond do
      params["notification_status"] || params["notification_page"] ->
        {:noreply, push_navigate(socket, to: MondekWeb.NotificationNavigation.path(params))}

      params["runner_id"] && !params["id"] ->
        {:noreply, push_navigate(socket, to: detail_path(params["runner_id"]))}

      true ->
        origin = URI.parse(uri)

        {:noreply,
         socket
         |> assign(
           filters: Map.take(params, @filter_keys),
           draft: nil,
           selected_id: params["id"],
           return_to: safe_return(params["return_to"]),
           controller_url:
             URI.to_string(%URI{scheme: origin.scheme, host: origin.host, port: origin.port})
         )
         |> refresh()}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("edit_filters", params, socket),
    do: {:noreply, assign(socket, draft: RunnerFleet.normalize(params))}

  def handle_event("filter", params, socket),
    do: {:noreply, push_patch(socket, to: path(Map.drop(params, ["page"])))}

  defp refresh(socket) do
    now = Monitoring.now()

    socket = assign(socket, now: now, snapshot: Mondek.Inspection.navigation_counts(now))

    if socket.assigns.selected_id do
      runner = RunnerFleet.detail(socket.assigns.selected_id, now)
      assign(socket, runner: runner, page_title: if(runner, do: runner["label"], else: "Runner"))
    else
      listing = RunnerFleet.list(socket.assigns.filters, now)

      assign(socket,
        listing: listing,
        filters: listing["filters"],
        draft: socket.assigns.draft || listing["filters"]
      )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app active={:runners} page_title="Runners" snapshot={@snapshot} now={@now} flash={@flash}>
      <div class="runner-fleet-page">
        <.inventory
          :if={!@selected_id}
          listing={@listing}
          filters={@filters}
          draft={@draft}
          now={@now}
        />
        <.runner_detail
          :if={@selected_id && @runner}
          runner={@runner}
          now={@now}
          return_to={@return_to}
          controller_url={@controller_url}
        />
        <section :if={@selected_id && !@runner} class="panel">
          <div class="empty">
            <h1>Runner not found</h1><p>This installation identity is not registered.</p><.link
              navigate="/runners"
              class="text-link"
            >Browse runners</.link>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp inventory(assigns) do
    assigns =
      assign(assigns, counts: assigns.listing["counts"] || %{}, list_path: path(assigns.filters))

    ~H"""
    <div class="page-heading">
      <div>
        <div class="eyebrow">Collection & transport</div><h1>Runners</h1><p>
          Find the runner responsible for a measurement and inspect its connection or collection gaps.
        </p>
      </div>
      <.link navigate="/guide" class="button secondary">Set up a runner</.link>
    </div>
    <section id="runner-fleet-summary" class="fleet-summary" aria-label="Overall runner fleet">
      <div>
        <strong>{@counts["total"] || 0}</strong><span>registered {plural(
          @counts["total"] || 0,
          "runner"
        )}</span>
      </div>
      <div><strong>{@counts["recent"] || 0}</strong><span>recent contact</span></div>
      <div class={if (@counts["overdue"] || 0) > 0, do: "fleet-summary-attention"}>
        <strong>{@counts["overdue"] || 0}</strong><span>contact overdue</span>
      </div>
      <div class={if (@counts["issues"] || 0) > 0, do: "fleet-summary-attention"}>
        <strong>{@counts["issues"] || 0}</strong><span>with measurement gaps</span>
      </div>
    </section>
    <p class="footnote fleet-boundary">
      Overall fleet counts. Contact confirms communication; fresh measurements confirm collection. Target health is shown in <.link navigate="/checks">Checks</.link>.
    </p>
    <section class="panel fleet-inventory">
      <form id="runner-filters" class="fleet-filters" phx-change="edit_filters" phx-submit="filter">
        <label class="fleet-search" for="runner-search">Search runners<input
          id="runner-search"
          name="search"
          type="search"
          value={@draft["search"]}
          placeholder="Name, identity, source or context"
        /></label>
        <label for="runner-contact-filter">Controller contact<select
          id="runner-contact-filter"
          name="contact"
        ><option
          :for={
            {value, label} <- [
              {"all", "Any contact"},
              {"recent", "Recent contact"},
              {"overdue", "Contact overdue"},
              {"never", "Never contacted"}
            ]
          }
          value={value}
          selected={(@draft["contact"] || "all") == value}
        >
          {label}
        </option></select></label>
        <label for="runner-collection-filter">Collection<select
          id="runner-collection-filter"
          name="collection"
        ><option
          :for={
            {value, label} <- [
              {"all", "Any collection state"},
              {"issues", "Measurement gaps"},
              {"fresh", "All results fresh"},
              {"empty", "No active results"}
            ]
          }
          value={value}
          selected={(@draft["collection"] || "all") == value}
        >
          {label}
        </option></select></label>
        <label for="runner-sort">Sort by<select id="runner-sort" name="sort"><option
          :for={
            {value, label} <- [
              {"attention", "Needs attention first"},
              {"name", "Runner name"},
              {"last_contact", "Latest contact first"}
            ]
          }
          value={value}
          selected={(@draft["sort"] || "attention") == value}
        >
          {label}
        </option></select></label>
        <button type="submit" class="button">Apply filters</button>
        <.link :if={filtered?(@filters)} patch="/runners" class="text-link">Clear filters</.link>
        <div :if={@draft["source_id"] not in [nil, ""]} class="fleet-source-filter">
          <label for="runner-source-filter">Source ID<input
            id="runner-source-filter"
            name="source_id"
            value={@draft["source_id"]}
          /></label>
        </div>
      </form>
      <div class="fleet-list-heading">
        <h2>Runner fleet</h2><span>{length(@listing["items"])} shown · {@listing["total"]} matching · {@counts[
          "total"
        ] || 0} registered</span>
      </div>
      <div :if={@listing["items"] == []} class="empty" id="runner-list-empty">
        <h3>
          {if (@counts["total"] || 0) == 0, do: "No runners registered", else: "No matching runners"}
        </h3><p>
          {if (@counts["total"] || 0) == 0,
            do:
              "Start a runner with its consumer package and a persistent state directory. Its published checks appear automatically.",
            else: "Try a different search or clear the filters."}
        </p><.link :if={(@counts["total"] || 0) == 0} navigate="/guide" class="text-link">Set up your first runner</.link>
      </div>
      <div :if={@listing["items"] != []} class="table-wrap fleet-table-wrap">
        <table id="runner-list" class="fleet-table" role="table">
          <caption class="sr-only">
            Registered runners and their independent controller contact and collection state
          </caption><thead role="rowgroup">
            <tr role="row">
              <th scope="col" role="columnheader">Runner / execution context</th><th
                scope="col"
                role="columnheader"
              >
                Controller contact
              </th><th scope="col" role="columnheader">
                Collection
              </th><th scope="col" role="columnheader">Inventory</th>
            </tr>
          </thead><tbody role="rowgroup">
            <tr :for={runner <- @listing["items"]} id={"runner-row-" <> runner["id"]} role="row">
              <td data-label="Runner" role="cell">
                <.link
                  navigate={detail_path(runner["id"], @list_path)}
                  aria-label={(runner["label"] || "Unnamed runner") <> " · " <> runner["id"]}
                  class="fleet-runner-name"
                >{runner[
                  "label"
                ] || "Unnamed runner"}</.link><span
                  :if={execution_context(runner) != runner["label"]}
                  class="fleet-secondary"
                >{execution_context(runner)}</span><span
                  class="fleet-identity mono"
                  title={runner["id"]}
                >{short_id(runner["id"])}</span>
              </td>
              <td data-label="Controller contact" role="cell">
                <.contact_badge value={runner["contact_status"]} /><span class="fleet-secondary"><.relative_time
                  value={runner["last_seen_at"]}
                  now={@now}
                /></span>
              </td>
              <td data-label="Collection" role="cell">
                <.collection_badge value={runner["collection_status"]} /><span class="fleet-secondary">{runner[
                  "coverage"
                ]["fresh"]} / {runner["coverage"]["active"]} results fresh</span><span
                  :if={runner["collection_status"] == "issues"}
                  class="fleet-secondary"
                >{gaps_text(runner["coverage"])}</span>
              </td>
              <td data-label="Inventory" role="cell">
                <span>{runner["check_count"]} scheduled {plural(runner["check_count"], "check")}</span><span class="fleet-secondary">{source_summary(
                  runner
                )}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.pages listing={@listing} filters={@filters} />
    </section>
    <p class="footnote space-top">
      Runners collect measurements. <.link navigate="/notifications">Notifications</.link>
      records the controller's separate delivery to receivers.
    </p>
    """
  end

  defp runner_detail(assigns) do
    runner = assigns.runner
    status = runner["status"] || %{}

    assigns =
      assign(assigns,
        coverage: runner["coverage"],
        status: status,
        scheduler: status["scheduler"] || %{},
        current_path: detail_path(runner["id"], assigns.return_to),
        context: %{
          "controller_url" => assigns.controller_url,
          "page_path" => "/runners/" <> runner["id"],
          "runner_id" => runner["id"],
          "runner_name" => runner["label"]
        }
      )

    ~H"""
    <div id="runner-detail">
      <.link navigate={@return_to || "/runners"} class="back">{back_label(@return_to)}</.link>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Runner detail</div><h1>{@runner["label"] || "Unnamed runner"}</h1><p :if={
            execution_context(@runner) != @runner["label"]
          }>
            {execution_context(@runner)}
          </p><p class="fleet-identity mono">Installation {@runner["id"]}</p>
        </div><.contact_badge value={@runner["contact_status"]} />
      </div>
      <div class="fleet-detail-top">
        <section class="panel" id="runner-measurements" aria-labelledby="runner-measurements-heading">
          <div class="panel-heading">
            <h2 id="runner-measurements-heading">Measurement coverage</h2><.collection_badge value={
              @runner["collection_status"]
            } />
          </div><div class="panel-body">
            <p class="fleet-primary-count">
              <strong>{@coverage["fresh"]}</strong> of {@coverage["active"]} active results fresh
            </p>
            <p :if={@coverage["active"] == 0}>
              No active published results are expected from this runner. Inspect its source declarations and placement decisions in Coverage.
            </p>
            <p :if={@coverage["active"] > 0} class="footnote">
              A fresh Warning or Critical measurement still confirms collection. Investigate its target health in Checks.
            </p>
            <div class="fleet-gap-links">
              <.link
                :for={
                  {key, title, filter} <- [
                    {"unavailable", "Unavailable", "unavailable"},
                    {"stale", "Stale", "stale"},
                    {"awaiting", "Awaiting measurement", "awaiting"}
                  ]
                }
                :if={(@coverage[key] || 0) > 0}
                navigate={checks_path(@runner["id"], @current_path, filter)}
              ><strong>{@coverage[key]}</strong> {title}</.link>
            </div>
            <div class="fleet-detail-actions">
              <.link navigate={checks_path(@runner["id"], @current_path)} class="text-link">Inspect all results</.link><.link
                navigate={"/configuration?" <> URI.encode_query(%{"runner_id" => @runner["id"]})}
                class="text-link"
              >{@runner["check_count"]} scheduled {plural(@runner["check_count"], "check")}</.link><.link
                navigate={"/monitoring-incidents?" <> URI.encode_query(%{"runner_id" => @runner["id"], "return_to" => @current_path})}
                class="text-link"
              >Monitoring loss incidents</.link>
            </div>
          </div>
        </section>
        <section class="panel" id="runner-contact" aria-labelledby="runner-contact-heading">
          <div class="panel-heading">
            <h2 id="runner-contact-heading">Controller connection</h2>
          </div><div class="panel-body">
            <p><strong>{contact_label(@runner["contact_status"])}</strong></p><p class="space-top">
              Last contact: <.relative_time value={@runner["last_seen_at"]} now={@now} />
            </p>
            <p class="footnote space-top">
              Contact is recent for {@runner["contact_seconds"]} seconds. It confirms communication, not a successful measurement.
            </p>
            <p :if={@runner["contact_status"] != "recent"} class="notice warn notice-copy space-top">
              Inspect the runner process and its controller connection from the runner's host. Checks may still be executing and buffering evidence while disconnected.
            </p>
            <p :if={@runner["contact_status"] == "recent"} class="footnote space-top">
              If measurements are unavailable, open an affected result for its execution error and datasource details.
            </p>
          </div>
        </section>
      </div>
      <section
        class="panel space-top"
        id="runner-last-report"
        aria-labelledby="runner-last-report-heading"
      >
        <div class="panel-heading">
          <h2 id="runner-last-report-heading">Last reported execution & upload</h2>
        </div><div class="panel-body">
          <p class="footnote">
            These values cover this runner's checks. They may predate the latest contact and stay fixed until a new status report arrives. They do not identify a specific blocked check.
          </p>
          <div class="fleet-telemetry-groups">
            <section aria-labelledby="runner-execution-heading">
              <h3 id="runner-execution-heading">Execution scheduling</h3><dl class="fleet-facts">
                <div>
                  <dt>Active checks on runner</dt><dd>{reported(@scheduler["active_checks"])}</dd>
                </div><div>
                  <dt>Running checks</dt><dd>{reported(@scheduler["running_checks"])}</dd>
                </div><div>
                  <dt>Maximum concurrent checks</dt><dd>{reported(@scheduler["max_concurrency"])}</dd>
                </div><div>
                  <dt>Due, waiting for a slot</dt><dd>
                    {reported(@scheduler["due_waiting_checks"])}
                  </dd>
                </div><div>
                  <dt>Oldest due wait</dt><dd>{seconds(@scheduler["oldest_due_seconds"])}</dd>
                </div><div>
                  <dt>Waiting for preparation</dt><dd>
                    {reported(@scheduler["preparation_pending_checks"])}
                  </dd>
                </div><div>
                  <dt>Prepared, awaiting activation</dt><dd>
                    {reported(@scheduler["prepared_waiting_checks"])}
                  </dd>
                </div>
              </dl><p
                :if={positive?(@scheduler["due_waiting_checks"])}
                class="notice warn notice-copy space-top"
              >
                Executions were waiting for capacity. Inspect slow checks and the concurrency limit before changing their schedules.
              </p>
            </section>
            <section aria-labelledby="runner-upload-heading">
              <h3 id="runner-upload-heading">Evidence awaiting upload</h3><dl class="fleet-facts">
                <div>
                  <dt>Buffered reports</dt><dd>{reported(@status["queue_count"])}</dd>
                </div><div>
                  <dt>Spool usage</dt><dd>{bytes(@status["queue_bytes"])}</dd>
                </div><div>
                  <dt>Oldest buffered report</dt><dd>
                    <.relative_time
                      :if={@status["oldest_at"]}
                      value={@status["oldest_at"]}
                      now={@now}
                    /><span :if={!@status["oldest_at"]}>{if @status["queue_count"] == 0,
                      do: "No buffered reports",
                      else: "Not reported"}</span>
                  </dd>
                </div><div>
                  <dt>Reports dropped since journal creation</dt><dd>
                    {reported(@status["dropped"])}
                  </dd>
                </div>
              </dl><p
                :if={positive?(@status["queue_count"])}
                class="notice info notice-copy space-top"
              >
                A brief queue can be normal. If it persists, inspect controller reachability and upload responses from the runner.
              </p><p :if={positive?(@status["dropped"])} class="notice warn notice-copy space-top">
                This cumulative count records past evidence loss. It does not by itself show a current outage.
              </p>
            </section>
          </div>
          <details
            :if={@status["diagnostic"] not in [nil, "", %{}, []]}
            id="runner-diagnostic"
            class="diagnostic-details space-top"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Last recorded diagnostic</summary><p class="footnote space-top">
              This message can survive recovery and may describe an earlier problem. Use measurement coverage and contact above to assess the current state.
            </p><pre class="diagnostic-text">{diagnostic(@status["diagnostic"])}</pre>
          </details>
        </div>
      </section>
      <section
        class="panel space-top"
        id="runner-publications"
        aria-labelledby="runner-publications-heading"
      >
        <div class="panel-heading">
          <h2 id="runner-publications-heading">Published sources & placement</h2><span class="badge">{@runner[
            "active_publication_count"
          ] || 0} active</span>
        </div><div class="panel-body">
          <p class="footnote">
            Execution context describes where this runner operates. Monitored environments belong to each result and can be different.
          </p>
          <p :if={(@runner["publications"] || []) == []} class="space-top">
            No source inventory has been published.
            <.link navigate={"/coverage?" <> URI.encode_query(%{"runner_id" => @runner["id"], "return_to" => @current_path})}>Inspect declared coverage</.link>
            or review runner startup.
          </p>
          <article :for={publication <- @runner["publications"] || []} class="fleet-publication">
            <div>
              <h3>{publication["source_id"]}</h3><span :if={publication["retired_at"]} class="badge">Retired publication</span>
            </div><dl class="fleet-facts">
              <div>
                <dt>Execution context</dt><dd>{publication_context(publication)}</dd>
              </div><div>
                <dt>Inventory revision</dt><dd>{publication["revision"] || "Not recorded"}</dd>
              </div><div>
                <dt>Received</dt><dd>
                  <.relative_time value={publication["received_at"]} now={@now} />
                </dd>
              </div>
            </dl><.link
              navigate={"/coverage?" <> URI.encode_query(%{"source_id" => publication["source_id"], "runner_id" => @runner["id"], "return_to" => @current_path})}
              class="text-link"
            >Inspect declarations and placement</.link>
          </article>
          <p
            :if={(@runner["publication_count"] || 0) > length(@runner["publications"] || [])}
            class="footnote space-top"
          >
            Showing {length(@runner["publications"])} of {@runner["publication_count"]} retained source publications. Search Coverage by source to investigate the remaining declarations.
          </p>
        </div>
      </section>
      <details
        id="runner-provenance"
        class="panel disclosure space-top"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Installation & session provenance</summary><div class="panel-body">
          <dl class="fleet-facts">
            <div>
              <dt>Installation ID</dt><dd class="mono">{@runner["id"]}</dd>
            </div><div>
              <dt>Current session</dt><dd class="mono">{@runner["session_id"] || "Not recorded"}</dd>
            </div><div>
              <dt>Boot sequence</dt><dd>{@runner["boot"] || "Not recorded"}</dd>
            </div><div>
              <dt>Retired checks</dt><dd>{@runner["retired_check_count"] || 0}</dd>
            </div>
          </dl><p class="footnote space-top">
            The installation identity survives restarts when the state directory is retained. A new session does not make buffered evidence new.
          </p><details class="diagnostic-details space-top">
            <summary>Reported status data</summary><pre>{Jason.encode!(@status, pretty: true)}</pre>
          </details>
        </div>
      </details>
      <div class="space-top">
        <AgentPrompts.library
          id="runner-agent-prompts"
          kinds={[:collection, :deployment]}
          context={@context}
        />
      </div>
    </div>
    """
  end

  defp pages(assigns) do
    assigns =
      assign(assigns,
        pages: max(1, ceil(assigns.listing["total"] / assigns.listing["page_size"]))
      )

    ~H"""
    <nav id="runner-pagination" class="panel-footer pagination" aria-label="Runner pages">
      <.link :if={@listing["page"] > 1} patch={path(Map.put(@filters, "page", @listing["page"] - 1))}>Previous</.link><span>Page {@listing[
        "page"
      ]} of {@pages} · {@listing["total"]} matching {plural(@listing["total"], "runner")}</span><.link
        :if={@listing["page"] < @pages}
        patch={path(Map.put(@filters, "page", @listing["page"] + 1))}
      >Next</.link>
    </nav>
    """
  end

  defp contact_badge(assigns) do
    ~H"""
    <span class={"badge fleet-contact-" <> to_string(@value)}>{contact_label(@value)}</span>
    """
  end

  defp collection_badge(assigns) do
    ~H"""
    <span class={"badge fleet-collection-" <> to_string(@value)}>{collection_label(@value)}</span>
    """
  end

  defp relative_time(assigns) do
    ~H"""
    <time :if={@value} datetime={@value} title={@value}>{age(@value, @now)}</time><span :if={!@value}>Not recorded</span>
    """
  end

  defdelegate path(filters), to: MondekWeb.RunnerNavigation
  defdelegate detail_path(id, return_to \\ nil), to: MondekWeb.RunnerNavigation
  defdelegate return_path(value), to: MondekWeb.RunnerNavigation
  defp safe_return(value), do: MondekWeb.RunnerNavigation.safe_return(value)

  defp checks_path(id, return_to, freshness \\ nil),
    do: MondekWeb.RunnerNavigation.checks_path(id, return_to, freshness)

  defp filtered?(filters),
    do:
      Enum.any?(Map.take(filters, ~w(search contact collection source_id)), fn {_k, v} ->
        v not in [nil, "", "all"]
      end)

  defp contact_label("recent"), do: "Recent contact"
  defp contact_label("overdue"), do: "Contact overdue"
  defp contact_label(_), do: "Never contacted"
  defp collection_label("fresh"), do: "All results fresh"
  defp collection_label("issues"), do: "Measurement gaps"
  defp collection_label(_), do: "No active results"
  defp back_label("/coverage" <> _), do: "← Back to coverage"
  defp back_label(nil), do: "← All runners"
  defp back_label("/runners" <> _), do: "← Back to runners"
  defp back_label("/monitoring-incidents" <> _), do: "← Back to monitoring incident"

  defp back_label(path),
    do:
      if(String.ends_with?(URI.parse(path).path, "/diagnostics"),
        do: "← Back to measurement investigation",
        else: "← Back to result"
      )

  defp short_id(id), do: String.slice(id || "", 0, 8)
  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
  defp reported(value) when is_number(value) and value >= 0, do: value
  defp reported(_), do: "Not reported"
  defp positive?(value), do: is_number(value) && value > 0

  defp seconds(value) when is_number(value) and value >= 0,
    do: "#{Float.round(value * 1.0, 1)} seconds"

  defp seconds(_), do: "Not reported"

  defp bytes(value) when is_number(value) and value >= 0,
    do: "#{Float.round(value / 1024, 1)} KiB"

  defp bytes(_), do: "Not reported"
  defp diagnostic(value) when is_binary(value), do: value
  defp diagnostic(value), do: Jason.encode!(value, pretty: true)

  defp publication_context(publication) do
    context = publication["runner_context"] || publication["context"] || %{}
    context = if is_map(context), do: context, else: %{}
    label = context["label"] || context["id"] || "Context not declared"
    environment = context["local_environment"]
    label <> if(is_binary(environment) && environment != "", do: " · " <> environment, else: "")
  end

  defp execution_context(runner) do
    values =
      runner["publications"]
      |> List.wrap()
      |> Enum.reject(& &1["retired_at"])
      |> Enum.map(&publication_context/1)
      |> Enum.uniq()

    if values == [],
      do: "Execution context not declared",
      else:
        Enum.join(Enum.take(values, 2), " · ") <>
          if(length(values) > 2, do: " · +#{length(values) - 2} contexts", else: "")
  end

  defp source_summary(runner) do
    case runner["publications"] |> List.wrap() |> Enum.reject(& &1["retired_at"]) do
      [] ->
        "No active source publication"

      [publication] ->
        publication["source_id"]

      publications ->
        "#{runner["active_publication_count"] || length(publications)} active sources"
    end
  end

  defp gaps_text(coverage),
    do:
      [{"unavailable", "unavailable"}, {"stale", "stale"}, {"awaiting", "awaiting"}]
      |> Enum.filter(fn {key, _} -> (coverage[key] || 0) > 0 end)
      |> Enum.map_join(" · ", fn {key, label} -> "#{coverage[key]} #{label}" end)

  defp age(value, now) do
    case DateTime.from_iso8601(value || "") do
      {:ok, at, _} ->
        seconds = max(DateTime.diff(now, at), 0)

        cond do
          seconds < 60 -> "#{seconds}s ago"
          seconds < 3600 -> "#{div(seconds, 60)}m ago"
          seconds < 86400 -> "#{div(seconds, 3600)}h ago"
          true -> "#{div(seconds, 86400)}d ago"
        end

      _ ->
        "Not recorded"
    end
  end
end

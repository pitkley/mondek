# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckInventory do
  @moduledoc "Presentation and URL state for the independently measured result inventory."
  use MondekWeb, :html
  alias Phoenix.LiveView.JS

  defdelegate normalize(params), to: MondekWeb.CheckNavigation
  defdelegate investigation_return(value), to: MondekWeb.CheckNavigation

  defdelegate target_context_path(target_id, filters, retain_investigation \\ true),
    to: MondekWeb.CheckNavigation

  defdelegate leave_target_path(filters), to: MondekWeb.CheckNavigation
  defdelegate path(filters), to: MondekWeb.CheckNavigation
  defdelegate change_tab(filters, tab), to: MondekWeb.CheckNavigation
  defdelegate change_view(filters, view), to: MondekWeb.CheckNavigation
  defdelegate change_scope(filters, params), to: MondekWeb.CheckNavigation
  defdelegate clear_scope(filters), to: MondekWeb.CheckNavigation
  defdelegate clear_all(filters), to: MondekWeb.CheckNavigation
  defdelegate view(filters), to: MondekWeb.CheckNavigation

  def runner_names(known, rows) do
    known = Enum.reject(known, &is_nil(&1["installation_id"] || &1["id"]))

    visible =
      rows
      |> Enum.reject(&is_nil(&1["runner_id"]))
      |> Enum.map(&%{"id" => &1["runner_id"], "label" => &1["runner_label"]})

    runners = Map.values(Map.new(known ++ visible, &{&1["installation_id"] || &1["id"], &1}))
    names = Enum.frequencies_by(runners, &runner_name/1)
    known_ids = MapSet.new(known, &(&1["installation_id"] || &1["id"]))

    Map.new(runners, fn runner ->
      id = runner["installation_id"] || runner["id"]
      label = runner_name(runner)

      {id,
       if(names[label] > 1 || !MapSet.member?(known_ids, id),
         do: "#{label} (#{id})",
         else: label
       )}
    end)
  end

  def page(assigns) do
    groups = assigns.listing["groups"] || []

    runner_names =
      runner_names(assigns.snapshot["runners"] || [], Enum.flat_map(groups, & &1["items"]))

    target_view = view(assigns.filters) == "targets"
    selected = assigns.listing["selected_target"]

    filters =
      if target_view && selected,
        do: Map.put(assigns.filters, "target", selected["id"]),
        else: assigns.filters

    result_listing =
      if target_view,
        do: Map.put(assigns.listing, "total", assigns.listing["selected_total"] || 0),
        else: assigns.listing

    assigns =
      assign(assigns,
        groups: groups,
        target_view: target_view,
        runner_names: runner_names,
        filters: filters,
        context_group: assigns.listing["scope_target"] || List.first(groups),
        result_listing: result_listing
      )

    ~H"""
    <div class="checks-page">
      <.link
        :if={@filters["return_to"]}
        navigate={@filters["return_to"]}
        class="back"
        id="checks-runner-return"
      >← Back to runner</.link>
      <div class="page-heading checks-heading">
        <div>
          <div class="eyebrow">Monitoring</div><h1>Checks</h1>
        </div><.link navigate="/guide" class="text-link">Set up monitoring</.link>
      </div>
      <section
        :if={@filters["target_scope"]}
        id="checks-target-context"
        class="checks-target-context space-bottom"
        aria-labelledby="checks-target-context-heading"
      >
        <h2 id="checks-target-context-heading">Observations of one exact target</h2>
        <p :if={@context_group}>
          <strong>{@context_group["label"]}</strong> · {identity(@context_group)}
        </p>
        <p>
          This view stays within the same source, monitored environment and target identity. Each runner's result keeps its own health and measurement age.
        </p>
        <p :if={!@context_group}>
          No results match within this target context. Changing filters will not select another target.
        </p>
        <div class="checks-context-actions">
          <.link
            :if={@filters["investigation_return"]}
            id="checks-investigation-return"
            navigate={@filters["investigation_return"]}
            class="button small"
          >Back to filtered results</.link>
          <.link id="checks-leave-target" patch={leave_target_path(@filters)} class="text-link">Leave target context</.link>
        </div>
      </section>
      <div
        :if={get_in(@snapshot, ["coverage", "active"]) == 0 && @filters["status"] != "retired"}
        class="notice checks-setup"
      >
        <strong>Waiting for runner-provided checks</strong><p>
          Connect a runner with your monitoring project. Its code declares the checks and targets that appear here.
        </p><.link navigate="/guide" class="text-link">Open runner setup</.link>
      </div>
      <section class="checks-controls" aria-label="Filter checks">
        <div class="checks-tabs" role="group" aria-label="Result filters">
          <button
            :for={{key, label} <- tabs()}
            id={"inventory-tab-" <> key}
            type="button"
            phx-click="checks_tab"
            phx-value-tab={key}
            aria-pressed={to_string(@filters["tab"] == key)}
          >
            {label}<span>{@listing["filter_counts"][key]}</span>
          </button>
          <span :if={@filters["tab"] == "custom"} class="checks-custom-filter">Custom filters</span>
        </div>
        <.filters filters={@filters} snapshot={@snapshot} runner_names={@runner_names} />
      </section>
      <section
        id="check-inventory"
        class="checks-inventory"
        tabindex="-1"
        aria-labelledby="check-inventory-heading"
        phx-hook="InventoryNavigation"
        data-page-path={path(@filters)}
      >
        <h2 id="check-inventory-heading" class="sr-only">Check results</h2>
        <div class="checks-viewbar">
          <p class="checks-match-count" role="status">
            <strong>{@listing["total"]} matching {plural(@listing["total"], "result")}</strong><span :if={
              @listing["target_total"]
            }> · {@listing["target_total"]} {plural(@listing["target_total"], "group")}</span>
          </p>
          <div class="checks-view-switch" role="group" aria-label="Result presentation">
            <span>View</span>
            <button
              id="inventory-view-list"
              type="button"
              phx-click="checks_view"
              phx-value-view="list"
              aria-pressed={to_string(!@target_view)}
            >List</button>
            <button
              id="inventory-view-targets"
              type="button"
              phx-click="checks_view"
              phx-value-view="targets"
              aria-pressed={to_string(@target_view)}
            >By group</button>
          </div>
        </div>
        <div :if={@listing["total"] == 0} class="empty checks-empty">
          <h3>No matching results</h3><p>Try a different search or clear the filters.</p><button
            type="button"
            class="button"
            phx-click="clear_checks_all"
          >{if @filters["target_scope"],
            do: "Clear filters within this target",
            else: "Clear all filters"}</button>
        </div>
        <div
          :if={@listing["total"] > 0}
          class={["checks-workspace", @target_view && "checks-by-target"]}
        >
          <aside
            :if={@target_view}
            id="inventory-target-index"
            class="checks-target-index"
            aria-label="Check groups"
          >
            <div class="checks-index-heading">
              Check groups
            </div>
            <form
              id="inventory-group-search-form"
              class="checks-group-search"
              phx-change="group_search"
              phx-submit="group_search"
              phx-auto-recover="group_search"
            >
              <label for="inventory-group-search" class="sr-only">Filter check groups</label>
              <input
                id="inventory-group-search"
                name="group_search"
                type="search"
                value={@filters["group_search"] || ""}
                maxlength="200"
                phx-debounce="250"
                placeholder="Filter groups"
                aria-describedby="inventory-group-search-help"
              />
              <span id="inventory-group-search-help">Filters this list, not the selected results.</span>
            </form>
            <div
              class="checks-target-options"
              id="inventory-target-options"
              phx-hook="InventoryTargetScroll"
              tabindex="-1"
              aria-label="Check groups"
              data-has-more={to_string(@listing["group_has_more"] || false)}
              data-loaded={length(@listing["target_groups"])}
              data-index-scope={
                URI.encode_query(
                  Map.take(
                    @filters,
                    ~w(search runner_id environment health freshness status tab group_search target_scope)
                  )
                )
              }
            >
              <button
                :for={group <- @listing["target_groups"]}
                id={"inventory-target-" <> group["id"]}
                type="button"
                phx-click="select_target"
                phx-value-target={group["id"]}
                aria-pressed={to_string(@filters["target"] == group["id"])}
              >
                <span class="checks-target-name">{group["label"]}<span>{group["total"]}<span :if={
                  group["inventory_total"] != group["total"]
                }>/{group["inventory_total"]}</span></span></span>
                <span>{environment(group)} · {group_kind(group)}</span>
                <span class="checks-target-identity" title={identity(group)}>{group["source_id"] ||
                  "Legacy source"} · {group["group_key"] || group["target_key"] ||
                  "Identity not declared"}</span>
                <small class="target-group-state">{group_state(group)}</small>
              </button>
              <p :if={@listing["target_groups"] == []} class="checks-group-search-empty">
                No matching groups. The selected results remain open.
              </p>
              <.group_loader listing={@listing} />
            </div>
          </aside>
          <div class="checks-results-pane">
            <div class="checks-results-navigation">
              <form
                id="inventory-page-size-form"
                class="inventory-page-size-form"
                phx-change="page_size"
                phx-submit="page_size"
                phx-auto-recover="recover_page_size"
              >
                <label for="inventory-page-size">Results per page</label><select
                  id="inventory-page-size"
                  name="page_size"
                ><option
                  :for={size <- [10, 25, 50, 100]}
                  value={size}
                  selected={@listing["page_size"] == size}
                >
                  {size}
                </option></select>
              </form>
              <.pager listing={@result_listing} filters={@filters} position="top" />
            </div>
            <section
              :for={{group, index} <- Enum.with_index(@groups)}
              id={"target-group-" <> group["id"]}
              class="target-group checks-result-group"
              aria-labelledby={"target-heading-" <> group["id"]}
            >
              <header class="checks-group-heading">
                <div>
                  <h3 id={"target-heading-" <> group["id"]}>{group["label"]}</h3><span class="target-kind">{group_kind(
                    group
                  )}</span><span class="target-group-context" title={identity(group)}>{environment(
                    group
                  )} · {group["source_id"] || "Legacy source"}<span :if={
                    group["target_key"] && group["target_key"] != group["label"]
                  }> · {group["target_key"]}</span></span>
                </div>
                <p class="target-group-size">
                  {matching_count(group)} · {group["observers"]} {plural(group["observers"], "runner")}
                  <.link
                    :if={!@filters["target_scope"] && !group["is_check_group"]}
                    patch={target_context_path(group["id"], @filters)}
                    class="text-link target-context-link"
                  >Show all observations of this target</.link>
                </p>
              </header>
              <p
                :if={group["first_index"] > 1 || group["last_index"] < group["total"]}
                class="target-group-range"
              >
                Showing results {group["first_index"]}–{group["last_index"]} of {group["total"]} in this group.
                <span :if={group["first_index"] > 1}>Continued from the previous page.</span>
                <span :if={group["last_index"] < group["total"]}>Continues on the next page.</span>
              </p>
              <.result_rows
                group={group}
                index={index}
                now={@now}
                runner_names={@runner_names}
                return_to={path(@filters)}
                show_scope={group["is_check_group"] || false}
                target_links={group["is_check_group"] && !@filters["target_scope"]}
              />
            </section>
            <.pager listing={@result_listing} filters={@filters} position="bottom" />
          </div>
        </div>
      </section>
      <p class="checks-evidence-note">
        Each row is an independent result. Last measured health and measurement freshness are separate.
      </p>
    </div>
    """
  end

  defp filters(assigns) do
    ~H"""
    <datalist id="inventory-environments"><option
      :for={entry <- @snapshot["environments"] || []}
      value={environment_id(entry)}
      label={environment_option(entry)}
    /></datalist>
    <form
      id="inventory-filters"
      class="checks-filter-form"
      phx-submit="filter"
      phx-change="filter"
      phx-auto-recover="recover_filters"
    >
      <div class="checks-primary-filters">
        <label class="checks-search"><span class="sr-only">Search</span><input
          type="search"
          id="inventory-search"
          name="search"
          value={@filters["search"] || ""}
          phx-debounce="300"
          placeholder="Search checks, targets or runners"
        /></label>
        <label><span class="sr-only">Monitored environment</span><input
          id="inventory-environment"
          name="environment"
          list="inventory-environments"
          value={@filters["environment"] || ""}
          phx-debounce="300"
          placeholder="All monitored environments"
          title="Choose a suggestion or enter a monitored environment ID"
        /></label>
        <label><span id="inventory-runner-label" class="sr-only">Observing runner</span><select
          id="inventory-runner"
          name="runner_id"
          aria-labelledby="inventory-runner-label"
        ><option value="">All observing runners</option><option
          :for={runner <- @snapshot["runners"] || []}
          value={runner["installation_id"] || runner["id"]}
          selected={@filters["runner_id"] == (runner["installation_id"] || runner["id"])}
        >
          {@runner_names[runner["installation_id"] || runner["id"]]}
        </option><option
          :if={
            @filters["runner_id"] not in [nil, ""] &&
              !Enum.any?(
                @snapshot["runners"] || [],
                &((&1["installation_id"] || &1["id"]) == @filters["runner_id"])
              )
          }
          value={@filters["runner_id"]}
          selected
        >
          {@filters["runner_id"]}
        </option></select></label>
        <button type="submit" class="button">Search</button><button
          :if={Enum.any?(~w(search environment runner_id), &(@filters[&1] not in [nil, ""]))}
          id="inventory-clear-scope"
          type="button"
          class="text-link"
          phx-click="clear_checks_scope"
        >Clear</button>
      </div>
      <details
        id="inventory-more-filters"
        class="checks-more-filters"
        open={@filters["tab"] == "custom" || @filters["status"] in ~w(all retired)}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>
          More filters<span :if={@filters["status"] in ~w(all retired)}> · {humanize(
            @filters["status"]
          )} membership</span>
        </summary>
        <div class="checks-secondary-filters">
          <label><span id="inventory-health-label">Last measured health</span><select
            id="inventory-health"
            name="health"
            aria-labelledby="inventory-health-label"
          ><option value="">
            All health
          </option><option
            :for={
              {value, label} <- [
                {"OK", "Healthy"},
                {"WARN", "Warning"},
                {"CRIT", "Critical"},
                {"not_measured", "Not measured"}
              ]
            }
            value={value}
            selected={@filters["health"] == value}
          >
            {label}
          </option></select></label>
          <label><span id="inventory-freshness-label">Measurement freshness</span><select
            id="inventory-freshness"
            name="freshness"
            aria-labelledby="inventory-freshness-label"
          ><option value="">
            All freshness
          </option><option
            :for={
              {value, label} <- [
                {"fresh", "Fresh"},
                {"gaps", "Measurement gaps"},
                {"stale", "Stale"},
                {"awaiting", "Awaiting measurement"},
                {"unavailable", "Unavailable"}
              ]
            }
            value={value}
            selected={@filters["freshness"] == value}
          >
            {label}
          </option></select></label>
          <label><span id="inventory-status-label">Membership</span><select
            id="inventory-status"
            name="status"
            aria-labelledby="inventory-status-label"
          ><option
            :for={
              {value, label} <- [
                {"active", "Active"},
                {"retired", "Retired"},
                {"all", "All membership"}
              ]
            }
            value={value}
            selected={(@filters["status"] || "active") == value}
          >
            {label}
          </option></select></label>
        </div>
      </details>
    </form>
    """
  end

  def result_rows(assigns) do
    duplicates = Enum.frequencies_by(assigns.group["items"], &{&1["label"], &1["runner_id"]})

    assigns =
      assigns
      |> assign(:duplicates, duplicates)
      |> assign_new(:show_scope, fn -> false end)
      |> assign_new(:target_links, fn -> false end)
      |> assign_new(:index, fn -> 0 end)

    ~H"""
    <div
      class="table-wrap checks-table-wrap"
      tabindex="0"
      role="region"
      aria-label={"Results for " <> @group["label"]}
    >
      <table
        role="table"
        class="inventory-table checks-results-table"
        aria-labelledby={"target-heading-" <> @group["id"]}
      >
        <colgroup>
          <col class="checks-health-col" /><col class="checks-name-col" /><col class="checks-summary-col" /><col class="checks-age-col" /><col class="checks-runner-col" />
        </colgroup>
        <thead role="rowgroup" class={@index > 0 && "checks-repeated-heading"}>
          <tr role="row">
            <th role="columnheader" scope="col">Last measured health</th><th
              role="columnheader"
              scope="col"
            >
              Check result
            </th><th role="columnheader" scope="col">
              Last measurement
            </th><th role="columnheader" scope="col">Measured</th><th role="columnheader" scope="col">
              Observing runner
            </th>
          </tr>
        </thead>
        <tbody role="rowgroup">
          <tr :for={row <- @group["items"]} role="row" id={"result-" <> row["id"]}>
            <td role="cell" data-label="Health">
              <span class={"badge " <> String.downcase(health(row))}><span :if={
                health(row) != "not_measured" && get_in(row, ["current", "knowledge"]) != "fresh"
              }>Last: </span>{health_text(health(row))}</span>
            </td>
            <td role="cell" data-label="Result">
              <.link
                navigate={"/checks/" <> row["id"] <> "?" <> URI.encode_query(%{"return_to" => @return_to})}
                class="checks-result-link"
              >{row["label"] || row["result_key"]}</.link>
              <span :if={@show_scope} class="checks-result-context">
                <.link
                  :if={@target_links}
                  patch={
                    target_context_path(
                      Mondek.Inspection.target_id(row),
                      filters_from_path(@return_to)
                    )
                  }
                  class="text-link checks-resource-link"
                  title="Show all observations of this exact target"
                >{target_label(row)}</.link><span :if={!@target_links}>{target_label(row)}</span>
                · {environment(row)}
              </span>
              <.link
                :if={
                  row["check_label"] != row["label"] ||
                    @duplicates[{row["label"], row["runner_id"]}] > 1
                }
                class="checks-scheduled-check"
                navigate={"/configuration/" <> row["assignment_id"] <> "?" <> URI.encode_query(%{"return_to" => @return_to})}
                title={"Scheduled check: " <> (row["source_key"] || row["assignment_id"])}
              >{row["check_label"] || "Scheduled check"}<span :if={
                @duplicates[{row["label"], row["runner_id"]}] > 1
              }> · {row["source_key"] || row["assignment_id"]}</span></.link>
            </td>
            <td role="cell" data-label="Measurement">
              <span class="target-result-summary" title={summary(row)}>{summary(row)}</span>
            </td>
            <td role="cell" data-label="Measured">
              <span
                :if={get_in(row, ["current", "knowledge"]) == "fresh"}
                class="checks-mobile-freshness"
              >Fresh measurement</span>
              <span
                :if={get_in(row, ["current", "knowledge"]) != "fresh"}
                class={"badge " <> (get_in(row,["current","knowledge"]) || "awaiting")}
              >{freshness(row)}</span><time
                datetime={get_in(row, ["current", "source_at"])}
                title={get_in(row, ["current", "source_at"])}
              >{age(get_in(row, ["current", "source_at"]), @now)}</time>
            </td>
            <td role="cell" data-label="Observing runner">
              <span class="target-result-observer" title={@runner_names[row["runner_id"]]}>{@runner_names[
                row["runner_id"]
              ] || "Awaiting runner"}</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp pager(assigns) do
    assigns =
      assign(assigns,
        pages: max(1, ceil(assigns.listing["total"] / assigns.listing["page_size"]))
      )

    ~H"""
    <nav
      :if={@pages > 1}
      class="pagination checks-pagination"
      id={"inventory-pagination-" <> @position}
      aria-label={"Result pages, " <> @position}
    >
      <span>Page {@listing["page"]} of {@pages} · {@listing["total"]} matching</span><div>
        <.link
          :if={@listing["page"] > 1}
          patch={path(Map.put(@filters, "page", @listing["page"] - 1))}
          phx-click={page_focus(@filters, @listing["page"] - 1)}
          class="button small"
        >Previous</.link>
        <.link
          :if={@listing["page"] < @pages}
          patch={path(Map.put(@filters, "page", @listing["page"] + 1))}
          phx-click={page_focus(@filters, @listing["page"] + 1)}
          class="button small"
        >Next</.link>
      </div>
    </nav>
    """
  end

  defp group_loader(assigns) do
    ~H"""
    <div id="inventory-group-loader" class="checks-group-loader" tabindex="-1">
      <p>
        {length(@listing["target_groups"])} of {@listing["group_total"] || @listing["target_total"]} groups shown
      </p>
      <button
        :if={@listing["group_has_more"]}
        id="inventory-load-more-groups"
        type="button"
        class="button small"
        phx-click="load_more_groups"
        phx-disable-with="Loading groups…"
      >Load more groups</button>
      <p :if={@listing["group_limit_reached"]}>Filter groups to narrow this list.</p>
    </div>
    """
  end

  defp filters_from_path(path), do: URI.decode_query(URI.parse(path).query || "")

  defp target_label(row),
    do: get_in(row, ["target", "label"]) || get_in(row, ["target", "key"]) || "Unbound target"

  defp group_kind(%{"is_check_group" => true}), do: "Check group"
  defp group_kind(group), do: humanize(group["target_kind"] || "target")

  defp page_focus(filters, page),
    do:
      JS.dispatch("mondek:inventory-page",
        to: "#check-inventory",
        detail: %{path: path(Map.put(filters, "page", page))}
      )

  defp tabs,
    do: [
      {"all", "All results"},
      {"attention", "Needs attention"},
      {"critical", "Critical"},
      {"gaps", "Measurement gaps"}
    ]

  defp plural(1, name), do: name
  defp plural(_, name), do: name <> "s"
  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp environment(group),
    do: environment_option(%{"id" => group["environment"], "label" => group["environment_label"]})

  defp environment_id(%{"id" => id}), do: id
  defp environment_id(id), do: id
  defp environment_option(%{"id" => nil}), do: "Not declared"

  defp environment_option(%{"id" => id, "label" => label})
       when label not in [nil, ""] and label != id, do: "#{label} (#{id})"

  defp environment_option(%{"id" => id}), do: id
  defp environment_option(id), do: id
  defp runner_name(r), do: r["label"] || r["name"] || r["installation_id"] || r["id"] || "Runner"

  defp identity(g),
    do:
      "Environment #{environment(g)} · Source #{g["source_id"] || "not recorded"} · #{group_kind(g)} ID #{g["group_key"] || g["target_key"] || "not declared"}"

  defp matching_count(g) do
    if g["inventory_total"] && g["inventory_total"] != g["total"],
      do: "#{g["total"]} of #{g["inventory_total"]} results match",
      else: "#{g["total"]} matching #{plural(g["total"], "result")}"
  end

  defp group_state(g) do
    unhealthy = (g["health_counts"]["CRIT"] || 0) + (g["health_counts"]["WARN"] || 0)

    gaps =
      Enum.reduce(~w(stale unavailable awaiting), 0, &(&2 + (g["knowledge_counts"][&1] || 0)))

    parts = if unhealthy > 0, do: ["#{unhealthy} unhealthy"], else: []
    parts = if gaps > 0, do: parts ++ ["#{gaps} measurement #{plural(gaps, "gap")}"], else: parts

    if parts == [],
      do:
        if(g["knowledge_counts"]["retired"] == g["total"],
          do: "Retired monitoring",
          else: "No measured failures"
        ),
      else: Enum.join(parts, " · ")
  end

  defp health(row),
    do:
      if(get_in(row, ["current", "confirmed_observation_id"]),
        do: get_in(row, ["current", "health"]) || "UNKNOWN",
        else: "not_measured"
      )

  defp health_text("CRIT"), do: "● Critical"
  defp health_text("WARN"), do: "▲ Warning"
  defp health_text("OK"), do: "✓ Healthy"
  defp health_text("not_measured"), do: "Not measured"
  defp health_text(_), do: "Unknown"

  defp summary(row),
    do:
      if(get_in(row, ["current", "confirmed_observation_id"]),
        do: get_in(row, ["current", "summary"]) || "No summary provided.",
        else: "No confirmed measurement yet."
      )

  defp freshness(row) do
    case get_in(row, ["current", "knowledge"]) do
      value when value in ["awaiting", nil] -> "Awaiting measurement"
      value -> humanize(value)
    end
  end

  defp age(nil, _), do: "—"

  defp age(value, now) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} ->
        seconds = max(0, DateTime.diff(now, time))

        cond do
          seconds < 60 -> "#{seconds}s ago"
          seconds < 3600 -> "#{div(seconds, 60)}m ago"
          seconds < 86400 -> "#{div(seconds, 3600)}h ago"
          true -> "#{div(seconds, 86400)}d ago"
        end

      _ ->
        "—"
    end
  end
end

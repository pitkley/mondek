# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewMaintenanceChooser do
  use MondekWeb, :html
  import MondekWeb.MaintenancePresentation
  alias Mondek.MaintenanceSelection

  attr :candidates, :map, required: true
  attr :filter_choices, :map, required: true
  attr :picker, :any, required: true
  attr :filters, :map, required: true
  attr :proposal, :map, required: true
  attr :selected_rows, :list, required: true
  attr :selected_only, :boolean, required: true
  attr :selected_page, :integer, required: true
  attr :draft_origin, :string, required: true
  attr :preview, :any, required: true
  attr :preview_ui, :boolean, required: true
  attr :return_to, :any, required: true
  attr :fields, :list, required: true
  attr :chips, :list, required: true

  def selection_chooser(%{preview_ui: true} = assigns) do
    rows = assigns.candidates["items"] || []
    visible = MapSet.new(rows, & &1["key"])
    pinned = Enum.reject(assigns.selected_rows, &MapSet.member?(visible, &1["key"]))

    assigns =
      assign(assigns,
        rows: rows,
        pinned: pinned,
        page: assigns.candidates["page"] || 1,
        total: assigns.candidates["total"] || 0,
        selected_keys: MapSet.new(selections(assigns.proposal), &MaintenanceSelection.key/1)
      )

    ~H"""
    <section
      class="panel preview-maintenance-chooser"
      id="maintenance-check-chooser"
      style={if @proposal["scope"] != "selection" || @preview, do: "display: none"}
    >
      <header class="panel-heading">
        <h2>Choose checks or targets</h2>
        <span class="pf-v6-c-badge pf-m-read" id="maintenance-selected-count">{length(@selected_rows)} selected</span>
      </header>
      <div class="preview-maintenance-choice-toolbar">
        <MondekWeb.PreviewFilters.filter_picker
          id="maintenance-choice-search"
          picker={@picker}
          chips={@chips}
          fields={@fields}
          search={@filters["search"]}
          form_label="Filter checks and targets"
          label="Search checks and targets"
          placeholder="Search or filter choices"
        />
        <p class="footnote">
          {if @filters["kind"] == "target",
            do:
              "A selected target covers matching results across runners. Select child targets separately.",
            else: "A selected check covers all of its results, including results added later."}
        </p>
      </div>
      <form
        id="maintenance-selection-form"
        phx-change="selection_change"
        phx-auto-recover="recover_selection"
        phx-submit="selection_change"
      >
        <input type="hidden" name="_proposal" value={encoded_draft(@proposal, @draft_origin)} />
        <input
          type="hidden"
          name="_page_selections"
          value={Jason.encode!(Enum.map(@rows, &selector_identity/1))}
        />
        <input type="hidden" name="_filters" value={Jason.encode!(@filters)} />
        <input type="hidden" name="selected_keys[]" value="" />
        <table class="pf-v6-c-table pf-m-compact preview-table" aria-label="Checks and targets">
          <thead class="pf-v6-c-table__thead">
            <tr class="pf-v6-c-table__tr">
              <th scope="col" class="pf-v6-c-table__th preview-maintenance-choice-select">Select</th>
              <th scope="col" class="pf-v6-c-table__th">Check or target</th>
              <th scope="col" class="pf-v6-c-table__th preview-maintenance-choice-results">
                Results
              </th>
            </tr>
          </thead>
          <tbody class="pf-v6-c-table__tbody">
            <tr :if={@rows == []}>
              <td colspan="3" class="pf-v6-c-table__td">No choices match these filters.</td>
            </tr>
            <.choice_row
              :for={row <- @rows}
              row={row}
              selected={MapSet.member?(@selected_keys, row["key"])}
              pinned={false}
            />
          </tbody>
          <tbody :if={@pinned != []} class="pf-v6-c-table__tbody preview-maintenance-pinned">
            <tr>
              <th colspan="3" scope="rowgroup" class="pf-v6-c-table__th">
                Selected outside this view
              </th>
            </tr>
            <.choice_row :for={row <- @pinned} row={row} selected={true} pinned={true} />
          </tbody>
        </table>
      </form>
      <div class="preview-maintenance-choice-toolbar preview-maintenance-choice-actions">
        <div class="maintenance-selection-actions">
          <button
            :if={@rows != []}
            id="maintenance-select-page"
            type="button"
            class="button small"
            phx-click="select_page"
          >Select this page</button>
          <button
            :if={@total > 0 && @total <= 512}
            id="maintenance-select-matching"
            type="button"
            class="button small"
            phx-click="select_matching"
          >Select all {@total} matches</button>
          <button
            :if={@selected_rows != []}
            id="maintenance-clear-selection"
            type="button"
            class="button small"
            phx-click="clear_selection"
          >Clear selection</button>
        </div>
        <nav :if={@total > 25} class="pagination" aria-label="Maintenance selection pages">
          <button
            :if={@page > 1}
            type="button"
            class="button small"
            phx-click="selection_page"
            phx-value-page={@page - 1}
          >Previous</button>
          <span>Page {@page} of {ceil(@total / 25)}</span>
          <button
            :if={@page * 25 < @total}
            type="button"
            class="button small"
            phx-click="selection_page"
            phx-value-page={@page + 1}
          >Next</button>
        </nav>
      </div>
    </section>
    """
  end

  def selection_chooser(assigns) do
    rows =
      if assigns.selected_only,
        do: Enum.slice(assigns.selected_rows, (assigns.selected_page - 1) * 25, 25),
        else: assigns.candidates["items"] || []

    page =
      if assigns.selected_only, do: assigns.selected_page, else: assigns.candidates["page"] || 1

    total =
      if assigns.selected_only,
        do: length(assigns.selected_rows),
        else: assigns.candidates["total"] || 0

    assigns =
      assign(assigns,
        rows: rows,
        page: page,
        total: total,
        pages: max(1, ceil(total / 25)),
        selected_keys: MapSet.new(selections(assigns.proposal), &MaintenanceSelection.key/1)
      )

    ~H"""
    <section
      class="panel"
      id="maintenance-check-chooser"
      style={if @proposal["scope"] != "selection" || @preview, do: "display: none"}
    >
      <div class="panel-heading">
        <h2>Choose checks or targets</h2><span class="badge" id="maintenance-selected-count">{count_label(
          length(@selected_rows),
          "selection"
        )}</span>
      </div><div class="panel-body">
        <p id="maintenance-selection-help">
          Build one maintenance window for this explicit selection. A scheduled check includes its future results. A target includes future results with the same source, monitored environment, kind and key across observers.
        </p>
        <p class="footnote space-top">
          Selecting a host does not include separately named disks, processes or applications. Add each required target or check explicitly.
        </p>
        <div class="maintenance-selection-actions space-top">
          <button
            type="button"
            class="button small"
            phx-click="selection_view"
            phx-value-view="available"
            aria-pressed={to_string(!@selected_only)}
          >Available choices</button>
          <button
            id="maintenance-review-selected"
            type="button"
            class="button small"
            phx-click="selection_view"
            phx-value-view="selected"
            aria-pressed={to_string(@selected_only)}
          >Review selected ({length(@selected_rows)})</button>
          <button
            :if={@selected_rows != []}
            id="maintenance-clear-selection"
            type="button"
            class="button small"
            phx-click="clear_selection"
          >Clear selection</button>
        </div>
        <form
          id="maintenance-selection-form"
          phx-change="selection_change"
          phx-auto-recover="recover_selection"
          phx-submit="selection_change"
          class="space-top"
        >
          <input type="hidden" name="_proposal" value={encoded_draft(@proposal, @draft_origin)} />
          <input
            type="hidden"
            name="_page_selections"
            value={Jason.encode!(Enum.map(@rows, &selector_identity/1))}
          />
          <input type="hidden" name="_filters" value={Jason.encode!(@filters)} />
          <input type="hidden" name="_selected_only" value={to_string(@selected_only)} />
          <input type="hidden" name="_selected_page" value={@selected_page} />
          <input type="hidden" name="selected_keys[]" value="" />
          <div class="maintenance-picker-filters" style={if @selected_only, do: "display: none"}>
            <div class="field">
              <label for="maintenance-kind">Choose by</label><select
                id="maintenance-kind"
                name="filters[kind]"
              >
                <option value="check" selected={@filters["kind"] != "target"}>
                  Scheduled checks
                </option>
                <option value="target" selected={@filters["kind"] == "target"}>
                  Monitored targets
                </option>
              </select>
            </div>
            <div class="field">
              <label for="maintenance-search">Search choices</label><input
                id="maintenance-search"
                name="filters[search]"
                value={@filters["search"]}
                maxlength="200"
                phx-debounce="300"
              />
            </div>
            <div class="field">
              <label for="maintenance-environment">Monitored environment</label><input
                id="maintenance-environment"
                name="filters[environment]"
                value={@filters["environment"]}
                maxlength="200"
                phx-debounce="300"
                placeholder="Any monitored environment"
                list="maintenance-environment-options"
                aria-describedby="maintenance-filter-help"
              />
              <datalist id="maintenance-environment-options">
                <option :for={choice <- @filter_choices["environments"] || []} value={choice["id"]}>
                  {choice["label"]}
                </option>
              </datalist>
            </div>
            <div class="field">
              <label for="maintenance-source">Source ID</label><input
                id="maintenance-source"
                name="filters[source_id]"
                value={@filters["source_id"]}
                maxlength="200"
                phx-debounce="300"
                placeholder="Any source"
                list="maintenance-source-options"
                aria-describedby="maintenance-filter-help"
              />
              <datalist id="maintenance-source-options">
                <option :for={choice <- @filter_choices["sources"] || []} value={choice["id"]}>
                  {choice["label"]}
                </option>
              </datalist>
            </div>
            <div class="field">
              <label for="maintenance-runner">Observing runner</label><input
                id="maintenance-runner"
                name="filters[runner_id]"
                value={@filters["runner_id"]}
                maxlength="200"
                phx-debounce="300"
                placeholder="Any observing runner"
                list="maintenance-runner-options"
                aria-describedby="maintenance-filter-help"
              />
              <datalist id="maintenance-runner-options">
                <option :for={choice <- @filter_choices["runners"] || []} value={choice["id"]}>
                  {choice["label"]}
                </option>
              </datalist>
            </div>
          </div>
          <p :if={!@selected_only} id="maintenance-filter-help" class="footnote space-top">
            Choose a named suggestion or enter its stable ID. Suggestions show up to 100 environments, sources and runners; a missing suggestion does not remove an existing selection.
          </p>
          <p
            :if={
              !@selected_only &&
                Enum.any?(@filter_choices["truncated"] || %{}, fn {_kind, limited} -> limited end)
            }
            id="maintenance-choices-truncated"
            class="footnote"
          >
            More choices exist than are listed. Enter an unlisted stable ID to filter it directly.
          </p>
          <p :if={!@selected_only && @filters["kind"] == "target"} class="footnote space-top">
            The observing-runner filter only narrows these choices. A selected target covers its matching results across all observers.
          </p>
          <p :if={@selected_only} class="footnote space-top">
            Reviewing the complete selection, including choices from other pages and filters. A selection with no current results stays in the window.
          </p>
          <div :if={!@selected_only && @rows != []} class="maintenance-selection-actions space-top">
            <button
              id="maintenance-select-page"
              type="button"
              class="button small"
              phx-click="select_page"
            >Select this page ({length(@rows)})</button>
            <button
              id="maintenance-select-matching"
              type="button"
              class="button small"
              phx-click="select_matching"
              disabled={@total > 512}
            >Add all {@total} matching choices</button>
          </div>
          <p :if={!@selected_only && @total > 512} class="footnote space-top">
            A window can contain at most 512 checks or targets. Narrow the filters before adding every match.
          </p>
          <p :if={@rows == []} class="empty">
            {if @selected_only,
              do: "No checks or targets selected yet.",
              else: "No active choices match these filters."}
          </p>
          <ul class="maintenance-candidates maintenance-picker-rows">
            <li :for={row <- @rows} id={"maintenance-choice-" <> row["key"]}>
              <label class="maintenance-choice">
                <input
                  type="checkbox"
                  name="selected_keys[]"
                  value={row["key"]}
                  checked={MapSet.member?(@selected_keys, row["key"])}
                />
                <span><strong>{row["label"]}</strong><small>{row["context"]}</small><small>{count_label(
                  row["matched_results"] || 0,
                  "current result"
                )}{if row["available"] == false, do: " · Not currently available", else: ""}</small></span>
              </label>
              <.link
                :if={!@selected_only && row["scope"] == "check" && @selected_rows == []}
                navigate={new_path(row["assignment_id"], @preview_ui, @return_to)}
                class="text-link maintenance-single-link"
              >Schedule just this check</.link>
              <button
                :if={@selected_only}
                type="button"
                class="button small"
                phx-click="remove_selection"
                phx-value-key={row["key"]}
                aria-label={"Remove " <> row["label"]}
              >Remove</button>
            </li>
          </ul>
        </form>
        <nav class="pagination" aria-label="Maintenance selection pages">
          <button
            :if={@page > 1}
            type="button"
            class="button small"
            phx-click="selection_page"
            phx-value-page={@page - 1}
          >Previous</button>
          <span>Page {@page} of {@pages} · {count_label(
            @total,
            if(@selected_only, do: "selection", else: "choice")
          )}</span>
          <button
            :if={@page < @pages}
            type="button"
            class="button small"
            phx-click="selection_page"
            phx-value-page={@page + 1}
          >Next</button>
        </nav>
        <p class="footnote">
          Filters and page changes keep your selection. “Add all” captures today's matching choices; the search itself is not saved as a rule.
        </p>
      </div>
    </section>
    """
  end

  defp choice_row(assigns) do
    assigns = assign(assigns, :checkbox_id, "maintenance-select-" <> assigns.row["key"])

    ~H"""
    <tr
      class={["pf-v6-c-table__tr preview-maintenance-choice-row", @selected && "preview-selected"]}
      id={"maintenance-choice-" <> @row["key"]}
    >
      <td class="pf-v6-c-table__td">
        <input
          id={@checkbox_id}
          type="checkbox"
          name={if !@pinned, do: "selected_keys[]"}
          value={@row["key"]}
          checked={@selected}
          phx-click={if @pinned, do: "remove_selection"}
          phx-value-key={if @pinned, do: @row["key"]}
          aria-label={(if @pinned, do: "Remove ", else: "Select ") <> @row["label"]}
        />
      </td>
      <th scope="row" class="pf-v6-c-table__th">
        <label for={@checkbox_id}>
          {@row["label"]}
          <span class="preview-caption">{@row["context"]}</span>
        </label>
      </th>
      <td class="pf-v6-c-table__td">
        {@row["matched_results"] || 0}
        <p :if={@row["available"] == false} class="preview-caption">Unavailable</p>
      </td>
    </tr>
    """
  end
end

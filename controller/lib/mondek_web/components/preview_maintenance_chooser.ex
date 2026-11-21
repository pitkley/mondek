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
  attr :return_to, :any, required: true
  attr :fields, :list, required: true
  attr :chips, :list, required: true

  def selection_chooser(assigns) do
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
          {case @filters["kind"] do
            "target" ->
              "A selected target covers matching results across runners. Select child targets separately."

            "stable_check" ->
              "A stable check covers all outputs of that source check in the selected environment, including across runner replacements."

            "check_target" ->
              "A stable check target covers only outputs for that exact target from the selected check and environment, across runner replacements."

            _ ->
              "A selected check covers all of its results, including results added later on that scheduled instance."
          end}
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

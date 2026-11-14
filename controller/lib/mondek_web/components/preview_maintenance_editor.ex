# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewMaintenanceEditor do
  use MondekWeb, :html
  import MondekWeb.MaintenancePresentation
  alias Mondek.MaintenanceTime
  alias MondekWeb.PreviewMaintenanceDetails
  alias Phoenix.LiveView.JS

  attr :proposal, :map, required: true
  attr :window, :any, required: true
  attr :scope_options, :list, required: true
  attr :preview, :any, required: true
  attr :token, :any, required: true
  attr :stale, :boolean, required: true
  attr :draft_origin, :string, required: true
  attr :return_to, :any, required: true
  attr :current_path, :string, required: true
  attr :section_level, :integer, values: [2, 3], default: 2

  def editor(assigns) do
    assigns =
      assign(assigns,
        active: assigns.window && assigns.window["status"] == "active",
        show_scope: is_nil(assigns.window) && assigns.proposal["scope"] != "selection",
        new_window: is_nil(assigns.window),
        start_choices:
          MaintenanceTime.choices(assigns.proposal["starts_local"], assigns.proposal["timezone"]),
        end_choices:
          MaintenanceTime.choices(assigns.proposal["ends_local"], assigns.proposal["timezone"])
      )

    ~H"""
    <section
      class="panel space-top preview-maintenance-settings"
      id="maintenance-settings"
    >
      <div class="panel-heading">
        <.dynamic_tag tag_name={"h#{@section_level}"}>
          {if @preview, do: "Review maintenance", else: "Window settings"}
        </.dynamic_tag>
      </div><div class="panel-body">
        <form
          id="maintenance-form"
          phx-change="edit"
          phx-auto-recover="recover"
          phx-submit={if @preview, do: "save", else: "preview"}
        >
          <input type="hidden" name="_proposal" value={encoded_draft(@proposal, @draft_origin)} />
          <input :if={@preview} type="hidden" name="_review_token" value={@token} />
          <div :if={!@preview} class="maintenance-settings-fields">
            <section
              :if={@show_scope}
              class="maintenance-settings-group"
            >
              <.dynamic_tag tag_name={"h#{@section_level + 1}"}>What to cover</.dynamic_tag>
              <div :if={@proposal["scope"] != "selection"} class="field full">
                <label for="maintenance-scope">Notification scope</label><select
                  id="maintenance-scope"
                  name="scope_choice"
                >
                  <option
                    :for={option <- @scope_options}
                    value={scope_key(option)}
                    selected={same_scope?(option, @proposal)}
                  >
                    {option["label"] || scope_label(option)}
                  </option>
                </select>
              </div>
              <div :if={@proposal["scope"] == "selection"} class="field full">
                <span class="field-label">Notification scope</span><p id="maintenance-selection-scope">
                  {scope_label(@proposal)}. All matching results are counted once, even when selections overlap.
                </p>
              </div>
              <button
                id="maintenance-include-more"
                type="button"
                class="button small space-top"
                phx-click="include_more"
              >Include more checks or targets</button>
              <p
                :if={@proposal["scope"] == "target"}
                class="footnote space-top"
                id="maintenance-dynamic-scope"
              >
                Only results for this exact monitored environment and target from the same source are covered, wherever they run. Future matching results join automatically; other results from a shared execution remain eligible.
              </p>
              <p :if={@proposal["scope"] == "check"} class="footnote space-top">
                All results of this scheduled check are covered. Other checks, including checks of the same target, are unaffected.
              </p>
              <p :if={@proposal["scope"] == "selection"} class="footnote space-top">
                Scheduled-check selections include future results of those same check instances. Target selections follow their exact source and monitored environment across observers. Separately named child targets are not included automatically.
              </p>
              <p :if={@window} class="footnote space-top">
                A saved window's scope is fixed. To cover something else, create another window.
              </p>
            </section>
            <section class="maintenance-settings-group">
              <.dynamic_tag tag_name={"h#{@section_level + 1}"}>Window details</.dynamic_tag>
              <div class={["form-grid", @new_window && "maintenance-new-details"]}>
                <div class={["field", @window && "full"]}>
                  <label for="maintenance-name">Window name</label><input
                    id="maintenance-name"
                    name="window[name]"
                    value={@proposal["name"]}
                    maxlength="200"
                    required
                  />
                </div>
                <div class={["field", @window && "full"]}>
                  <label for="maintenance-reason">Reason</label><textarea
                    id="maintenance-reason"
                    name="window[reason]"
                    maxlength="500"
                    required
                  >{@proposal["reason"]}</textarea>
                </div>
              </div>
            </section>
            <section class="maintenance-settings-group">
              <.dynamic_tag tag_name={"h#{@section_level + 1}"}>Schedule</.dynamic_tag>
              <div class={[
                "form-grid maintenance-schedule-grid",
                @active && "maintenance-active-schedule"
              ]}>
                <div :if={!@active} class="field">
                  <label for="maintenance-start-mode">Start</label><select
                    id="maintenance-start-mode"
                    name="window[start_mode]"
                  ><option value="scheduled" selected={@proposal["start_mode"] == "scheduled"}>
                    Scheduled
                  </option><option
                    :if={!repeating?(@proposal)}
                    value="now"
                    selected={@proposal["start_mode"] == "now"}
                  >
                    Now
                  </option></select>
                </div>
                <div :if={!@active} class="field">
                  <label for="maintenance-timezone">Timezone</label><input
                    id="maintenance-timezone"
                    name="window[timezone]"
                    value={@proposal["timezone"]}
                    list="maintenance-timezones"
                    maxlength="100"
                    required
                  /><small>Use UTC or an IANA name, such as Europe/Berlin.</small>
                  <datalist id="maintenance-timezones"><option
                    :for={
                      zone <- [
                        "UTC",
                        "Europe/Berlin",
                        "Europe/London",
                        "America/New_York",
                        "America/Los_Angeles",
                        "Asia/Tokyo",
                        "Australia/Sydney"
                      ]
                    }
                    value={zone}
                  /></datalist>
                </div>
                <div
                  :if={@proposal["start_mode"] != "now" && !@active}
                  class="field"
                >
                  <label for="maintenance-start">{if repeating?(@proposal),
                    do: "First window: start date and time",
                    else: "Start date and time"}</label><input
                    id="maintenance-start"
                    type="datetime-local"
                    name="window[starts_local]"
                    value={form_time(@proposal["starts_local"])}
                    step="1"
                    max="9999-12-31T23:59:59"
                    required
                  />
                  <.fold_choice
                    :if={!repeating?(@proposal) && @start_choices != []}
                    field="start"
                    choices={@start_choices}
                    selected={@proposal["start_fold"]}
                  />
                </div>
                <div class="field">
                  <label for="maintenance-end">{if repeating?(@proposal),
                    do: "First window: end date and time",
                    else: "End date and time"}</label><input
                    id="maintenance-end"
                    type="datetime-local"
                    name="window[ends_local]"
                    value={form_time(@proposal["ends_local"])}
                    step="1"
                    max="9999-12-31T23:59:59"
                    required
                  />
                  <.fold_choice
                    :if={!repeating?(@proposal) && @end_choices != []}
                    field="end"
                    choices={@end_choices}
                    selected={@proposal["end_fold"]}
                  />
                </div>
                <p :if={@active} class="footnote">
                  This window has started. Enter the new end time in {@proposal["timezone"]}.
                </p>
              </div>
              <div :if={@new_window} class="form-grid maintenance-repeat-fields">
                <div class="field full">
                  <label for="maintenance-repeat">Repeat</label>
                  <select id="maintenance-repeat" name="repeat">
                    <option value="none" selected={!repeating?(@proposal)}>Does not repeat</option>
                    <option value="weekly" selected={repeating?(@proposal)}>Weekly series</option>
                  </select>
                </div>
                <.recurrence_fields :if={repeating?(@proposal)} proposal={@proposal} />
              </div>
            </section>
            <div class="form-actions">
              <p>
                {if @proposal["scope"] == "selection" && selections(@proposal) == [],
                  do: "Select a check or target to preview this window.",
                  else: "Review the times, matching results and overlaps before saving."}
              </p><button
                id="maintenance-preview-button"
                class="button primary"
                disabled={
                  @stale || (@proposal["scope"] == "selection" && selections(@proposal) == [])
                }
                phx-disable-with="Previewing…"
              >Preview maintenance</button>
            </div>
          </div>
          <div :if={@preview} id="maintenance-preview">
            <.dynamic_tag tag_name={"h#{@section_level + 1}"}>{@proposal["name"]}</.dynamic_tag><p class="space-top">
              {@proposal["reason"]}
            </p><p class="space-top">
              {scope_label(@proposal, @scope_options)}
            </p>
            <PreviewMaintenanceDetails.times
              :if={!repeating?(@proposal)}
              window={Map.merge(@proposal, Map.take(@preview, ~w(starts_at ends_at)))}
            />
            <.series_preview
              :if={repeating?(@proposal)}
              proposal={@proposal}
              preview={@preview}
              section_level={@section_level}
            />
            <p id="maintenance-preview-summary" class="notice notice-copy space-top">
              Current matches: {count_label(
                get_in(@preview, ["counts", "matched_results"]) || 0,
                "result"
              )} across {count_label(
                get_in(@preview, ["counts", "matched_checks"]) || 0,
                "scheduled check"
              )}.
            </p>
            <p :if={@proposal["scope"] == "target"} class="footnote space-top">
              This is a preview of current membership. Future results with this exact source, monitored environment and target join this window automatically.
            </p>
            <p
              :if={(get_in(@preview, ["counts", "matched_results"]) || 0) == 0}
              id="maintenance-zero-matches"
              class="notice notice-copy space-top"
            >
              No results currently match. The window remains saved; matching results can be covered when they appear before it ends.
            </p>
            <details
              id="maintenance-preview-matches"
              open
              class="space-top maintenance-results-disclosure"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>
                Inspect currently matching results ({get_in(@preview, ["counts", "matched_results"]) ||
                  0})
              </summary>
              <PreviewMaintenanceDetails.matches
                rows={@preview["rows"] || []}
                current_path={@current_path}
                section_level={@section_level}
              />
              <nav :if={pages(@preview) > 1} class="pagination" aria-label="Affected result pages">
                <button
                  :if={(@preview["page"] || 1) > 1}
                  type="button"
                  class="button small"
                  phx-click="preview_page"
                  phx-value-page={@preview["page"] - 1}
                >Previous</button>
                <span>Page {@preview["page"] || 1} of {pages(@preview)}</span>
                <button
                  :if={(@preview["page"] || 1) < pages(@preview)}
                  type="button"
                  class="button small"
                  phx-click="preview_page"
                  phx-value-page={@preview["page"] + 1}
                >Next</button>
              </nav>
            </details>
            <section class="space-top" id="maintenance-overlaps">
              <.dynamic_tag tag_name={"h#{@section_level + 1}"}>Overlapping windows</.dynamic_tag>
              <p :if={(@preview["overlaps"] || []) == []}>
                No overlapping maintenance windows currently match this scope.
              </p>
              <ul :if={(@preview["overlaps"] || []) != []} class="maintenance-candidates">
                <li :for={window <- @preview["overlaps"]}>
                  <.link
                    navigate={window_path(window["id"], @return_to)}
                    class="text-link"
                  >{window["name"]}</.link><small>{utc_time(window["starts_at"])} – {utc_time(
                    window["ends_at"]
                  )}</small>
                </li>
              </ul>
              <p :if={(@preview["overlap_omitted"] || 0) > 0} class="footnote">
                Showing {length(@preview["overlaps"] || [])} of {@preview["overlap_total"]} overlapping windows.
                <.link
                  navigate="/maintenance"
                  class="text-link"
                >Inspect maintenance</.link>
                for other saved windows.
              </p>
              <p class="footnote space-top">
                Overlaps are allowed. Ending one window leaves other windows and incident acknowledgements in effect.
              </p>
            </section>
            <div class="form-actions">
              <button type="button" class="button" phx-click="back">Back to editing</button><button
                id="maintenance-save"
                class="button primary"
                disabled={is_nil(@token) || @stale}
                phx-disable-with="Saving…"
              >Save maintenance {if repeating?(@proposal), do: "series", else: "window"}</button>
            </div>
          </div>
        </form>
      </div><div class="panel-footer">
        Maintenance pauses failure notifications. Checks and recovery notifications continue. Notifications already sending may still be delivered.
      </div>
    </section>
    """
  end

  defp fold_choice(assigns) do
    ~H"""
    <fieldset class="maintenance-fold">
      <legend>This time occurs twice. Choose an occurrence.</legend>
      <label :for={choice <- @choices}><input
        type="radio"
        name={"window[#{@field}_fold]"}
        value={choice["value"]}
        checked={@selected == choice["value"]}
        required
      />{choice["label"]}</label>
    </fieldset>
    """
  end

  defp recurrence_fields(assigns) do
    assigns = assign(assigns, rule: assigns.proposal["recurrence"])

    ~H"""
    <div class="field">
      <label for="maintenance-repeat-interval">Repeat every</label>
      <select id="maintenance-repeat-interval" name="recurrence[interval]">
        <option :for={n <- 1..12} value={n} selected={@rule["interval"] == n}>
          {count_label(n, "week")}
        </option>
      </select>
    </div>
    <div class="field">
      <label for="maintenance-repeat-ending">Series ends</label>
      <select id="maintenance-repeat-ending" name="recurrence[end_mode]">
        <option value="count" selected={@rule["end_mode"] == "count"}>
          After a number of windows
        </option>
        <option value="date" selected={@rule["end_mode"] == "date"}>Through a last-start date</option>
      </select>
    </div>
    <div :if={@rule["end_mode"] == "count"} class="field">
      <label for="maintenance-repeat-count">Number of windows, including the first</label>
      <input
        id="maintenance-repeat-count"
        name="recurrence[count]"
        type="number"
        min="2"
        max="52"
        required
        value={@rule["count"]}
      />
    </div>
    <div :if={@rule["end_mode"] == "date"} class="field">
      <label for="maintenance-repeat-until">Last-start date, inclusive</label>
      <input
        id="maintenance-repeat-until"
        name="recurrence[until_date]"
        type="date"
        max="9999-12-31"
        required
        value={@rule["until_date"]}
      />
    </div>
    <p class="field full footnote">
      The first window sets the weekday and local start/end clocks, including overnight dates. Every series has 2–52 windows and a fixed end; it does not renew automatically.
    </p>
    <fieldset class="field full maintenance-series-folds">
      <legend>When a local time occurs twice</legend>
      <p class="footnote">
        These choices apply to any repeated date, even if the first date is unambiguous. Missing spring-forward times are rejected; choose clocks outside the missing interval.
      </p>
      <div class="form-grid">
        <div :for={{endpoint, label} <- [{"start", "Start time"}, {"end", "End time"}]} class="field">
          <label for={"maintenance-repeat-#{endpoint}-fold"}>{label}</label>
          <select id={"maintenance-repeat-#{endpoint}-fold"} name={"window[#{endpoint}_fold]"}>
            <option value="reject" selected={@proposal[endpoint <> "_fold"] == "reject"}>
              Require an explicit choice
            </option>
            <option value="earlier" selected={@proposal[endpoint <> "_fold"] == "earlier"}>
              Earlier occurrence
            </option>
            <option value="later" selected={@proposal[endpoint <> "_fold"] == "later"}>
              Later occurrence
            </option>
          </select>
        </div>
      </div>
    </fieldset>
    """
  end

  defp series_preview(assigns) do
    ~H"""
    <section id="maintenance-series-preview" class="space-top">
      <.dynamic_tag tag_name={"h#{@section_level + 1}"}>Review every scheduled date</.dynamic_tag>
      <p id="maintenance-series-preview-summary">
        {count_label(@preview["occurrence_total"] || 0, "window")}, {repeat_label(
          @proposal["recurrence"]
        )}. Timezone: {@proposal["timezone"]}. These UTC intervals are saved together and remain fixed.
      </p>
      <p>
        First start: {local_time(@preview["first_starts_at"], @proposal["timezone"])}. Final end: {local_time(
          @preview["final_ends_at"],
          @proposal["timezone"]
        )}.
      </p>
      <details
        id="maintenance-series-preview-dates"
        class="space-top"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Inspect every scheduled date ({@preview["occurrence_total"]})</summary>
        <PreviewMaintenanceDetails.occurrence_rows
          rows={@preview["occurrences"] || []}
          timezone={@proposal["timezone"]}
          saved={false}
        />
        <nav
          :if={(@preview["occurrence_pages"] || 1) > 1}
          class="pagination"
          aria-label="Reviewed maintenance dates"
        >
          <button
            :if={@preview["occurrence_page"] > 1}
            type="button"
            class="button small"
            phx-click="occurrence_preview_page"
            phx-value-page={@preview["occurrence_page"] - 1}
          >Previous dates</button>
          <span>Page {@preview["occurrence_page"]} of {@preview["occurrence_pages"]}</span>
          <button
            :if={@preview["occurrence_page"] < @preview["occurrence_pages"]}
            type="button"
            class="button small"
            phx-click="occurrence_preview_page"
            phx-value-page={@preview["occurrence_page"] + 1}
          >Next dates</button>
        </nav>
      </details>
    </section>
    """
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewMaintenanceDetails do
  use MondekWeb, :html
  import MondekWeb.MaintenancePresentation
  alias MondekWeb.PreviewDetail
  alias Phoenix.LiveView.JS

  attr :rows, :list, required: true
  attr :page, :integer, required: true
  attr :saved, :boolean, required: true

  def saved_selection(assigns) do
    assigns =
      assign(assigns,
        visible: Enum.slice(assigns.rows, (assigns.page - 1) * 25, 25),
        pages: selected_pages(assigns.rows)
      )

    ~H"""
    <section class="panel space-top" id="maintenance-saved-selection">
      <details
        id="maintenance-selection-details"
        class="maintenance-selection-disclosure"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Inspect selected checks and targets ({length(@rows)})</summary>
        <div class="panel-body">
          <p>
            {if @saved,
              do: "These selections are fixed for this window.",
              else: "These selections will be fixed when the window is saved."} Future results join only when they match one of these exact checks or targets.
          </p>
          <ul class="maintenance-candidates">
            <li :for={row <- @visible}>
              <strong>{row["label"]}</strong><small>{row["context"]}</small><small>{count_label(
                row["matched_results"] || 0,
                "current result"
              )}{if row["available"] == false, do: " · Not currently available", else: ""}</small>
            </li>
          </ul>
          <nav class="pagination" aria-label="Saved selection pages">
            <button
              :if={@page > 1}
              type="button"
              class="button small"
              phx-click="saved_selection_page"
              phx-value-page={@page - 1}
            >Previous</button>
            <span>Page {@page} of {@pages}</span>
            <button
              :if={@page < @pages}
              type="button"
              class="button small"
              phx-click="saved_selection_page"
              phx-value-page={@page + 1}
            >Next</button>
          </nav>
        </div>
      </details>
    </section>
    """
  end

  attr :window, :map, required: true
  attr :context, :map, required: true
  attr :current_path, :string, required: true
  attr :section_level, :integer, values: [2, 3], default: 2

  def preview_window_details(assigns) do
    ~H"""
    <.preview_saved_window
      window={@window}
      context={@context}
      current_path={@current_path}
      section_level={@section_level}
    />
    <.preview_history
      events={@window["history"] || []}
      total={@window["history_count"] || 0}
      section_level={@section_level}
    />
    """
  end

  defp preview_saved_window(assigns) do
    ~H"""
    <PreviewDetail.card id="maintenance-saved" title="Saved window" level={@section_level}>
      <PreviewDetail.facts label="Saved window">
        <tr>
          <th scope="row">Status</th><td>{status_label(@window)}</td>
        </tr>
        <tr>
          <th scope="row">Reason</th><td>{@window["reason"]}</td>
        </tr>
        <tr>
          <th scope="row">Scope</th><td>{scope_label(@window)}</td>
        </tr>
        <tr>
          <th scope="row">Starts</th><td>{utc_time(@window["starts_at"])}</td>
        </tr>
        <tr>
          <th scope="row">Ends</th><td>{utc_time(@window["ends_at"])}</td>
        </tr>
        <tr>
          <th scope="row">{if @window["cancelled_at"], do: "Planned duration", else: "Duration"}</th><td>
            {duration(@window["starts_at"], @window["ends_at"])}
          </td>
        </tr>
        <tr :if={@window["timezone"] not in [nil, "UTC", "Etc/UTC"]}>
          <th scope="row">Local schedule</th>
          <td>
            {local_time(@window["starts_at"], @window["timezone"])} to {local_time(
              @window["ends_at"],
              @window["timezone"]
            )} · {@window["timezone"]}
          </td>
        </tr>
        <tr :if={@window["cancelled_at"]}>
          <th scope="row">{status_label(@window)}</th><td>
            {utc_time(@window["cancelled_at"])} · {@window["cancellation_reason"]}
          </td>
        </tr>
        <tr :if={@window["series_id"]}>
          <th scope="row">Series</th><td>
            <.link navigate={preview_entity_path(:series, @window["series_id"], :page, @context)}>Inspect the series</.link>
            <p class="preview-caption">
              Editing or cancelling this window changes only this date. Other windows in the series remain scheduled.
            </p>
          </td>
        </tr>
      </PreviewDetail.facts>
    </PreviewDetail.card>
    <PreviewDetail.card id="maintenance-saved-matches" title="Matching results" level={@section_level}>
      <p :if={(@window["current_matches"] || []) == []} class="preview-recorded-actions">
        No current results match this scope.
      </p>
      <table
        :if={@window["current_matches"] not in [nil, []]}
        class="pf-v6-c-table preview-table"
        aria-label="Matching results"
      >
        <thead class="pf-v6-c-table__thead">
          <tr class="pf-v6-c-table__tr">
            <th scope="col" class="pf-v6-c-table__th">Target and result</th>
            <th scope="col" class="pf-v6-c-table__th">Runner</th>
          </tr>
        </thead>
        <tbody class="pf-v6-c-table__tbody">
          <tr :for={row <- @window["current_matches"]} class="pf-v6-c-table__tr">
            <td class="pf-v6-c-table__td">
              <.link
                patch={related_result_path(@current_path, row["id"])}
                class="preview-result-link"
              >{row[
                "label"
              ] || row["check_label"]}</.link>
              <p class="preview-caption">
                {target_label(row["target"] || %{})} · {row["environment"] || "Unscoped"}
              </p>
            </td>
            <td class="pf-v6-c-table__td">{row["runner_label"] || row["runner_id"]}</td>
          </tr>
        </tbody>
      </table>
      <p
        :if={(@window["match_count"] || 0) > length(@window["current_matches"] || [])}
        class="preview-recorded-actions preview-caption"
      >
        Showing {length(@window["current_matches"] || [])} of {@window["match_count"]} current matches.
      </p>
    </PreviewDetail.card>
    """
  end

  defp preview_history(assigns) do
    ~H"""
    <PreviewDetail.card id="maintenance-history" title="Window history" level={@section_level}>
      <p :if={@events == []} class="preview-recorded-actions">No recorded changes.</p>
      <PreviewDetail.facts :if={@events != []} label="Window history">
        <tr :for={event <- @events}>
          <th scope="row">{event_label(event)}</th>
          <td>
            <p>{event["reason"]}</p>
            <p class="preview-caption">
              {utc_time(event["inserted_at"] || event["at"])} · {event["actor"] || "Local operator"} · Revision {event[
                "revision"
              ]}
            </p>
            <details
              :if={is_map(event["snapshot"])}
              id={"preview-window-revision-#{event["revision"]}"}
              class="preview-maintenance-revision"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>Window at this revision</summary>
              <.revision_facts window={event["snapshot"]} />
            </details>
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={@total > length(@events)} class="preview-recorded-actions preview-caption">
        Showing {length(@events)} of {@total} recorded changes.
      </p>
    </PreviewDetail.card>
    """
  end

  attr :series, :map, required: true

  def series_summary(assigns) do
    ~H"""
    <div class="maintenance-series-summary space-top">
      <p>
        {repeat_label(@series["recurrence"] || %{})} · {@series["timezone"] ||
          @series["proposal"]["timezone"]}
      </p>
      <p :if={(@series["active_count"] || 0) > 0}>
        {count_label(@series["active_count"], "window")} active now.
      </p>
      <p :if={(@series["active_count"] || 0) == 0 && (@series["upcoming_count"] || 0) > 0}>
        No window active now.
      </p>
      <p :if={@series["next_starts_at"]}>
        Next window: {local_time(
          @series["next_starts_at"],
          @series["timezone"] || @series["proposal"]["timezone"]
        )}.
      </p>
      <p>
        {count_label(@series["upcoming_count"] || 0, "upcoming window")}. Final scheduled end: {utc_time(
          @series["final_ends_at"]
        )}.
      </p>
    </div>
    """
  end

  attr :series, :map, required: true
  attr :params, :map, required: true
  attr :cancel_open, :boolean, required: true
  attr :cancel_reason, :string, required: true
  attr :cancel_revision, :any, required: true
  attr :preview, :any, required: true
  attr :return_to, :any, required: true
  attr :list_filters, :map, required: true
  attr :series_path, :any, required: true
  attr :current_path, :string, required: true
  attr :section_level, :integer, values: [2, 3], default: 2

  def series_detail(assigns) do
    ~H"""
    <section class="panel" id="maintenance-series-saved">
      <div class="panel-heading">
        <.dynamic_tag tag_name={"h#{@section_level}"}>Saved maintenance series</.dynamic_tag><span class="badge">{status_label(
          @series
        )}</span>
      </div>
      <div class="panel-body">
        <p>{@series["reason"]}</p><p class="space-top">
          {scope_label(@series)}
        </p>
        <.series_summary series={@series} />
        <p class="footnote space-top">
          {if series_remaining?(@series),
            do:
              "Each active or upcoming window holds failure notifications only during its own interval.",
            else: "No notification hold remains from this series."} Checks and recovery notifications continue. Saved UTC times remain fixed across timezone database updates.
        </p>
        <div class="form-actions">
          <.link
            id="maintenance-series-copy"
            navigate={"/maintenance/new?" <> URI.encode_query(Map.reject(Map.merge(@list_filters, %{"copy_series" => @series["id"], "return_to" => @return_to}), fn {_, value} -> is_nil(value) end))}
            class="button"
          >Copy into a new schedule</.link>
          <button
            :if={(@series["upcoming_count"] || 0) > 0 && !@cancel_open}
            id="maintenance-series-cancel"
            class="button danger"
            phx-click="series_cancel_open"
          >Cancel upcoming windows</button>
        </div>
        <p class="footnote" id="maintenance-series-copy-help">
          Copying leaves this series unchanged. Choose a new first date and review the new series. Cancel any remaining upcoming windows separately if needed.
        </p>
      </div>
    </section>
    <section
      class="panel space-top"
      id="maintenance-series-cancellation"
      style={if !@cancel_open, do: "display: none"}
    >
      <div class="panel-heading">
        <.dynamic_tag tag_name={"h#{@section_level}"}>Cancel upcoming windows</.dynamic_tag>
      </div>
      <div class="panel-body">
        <p>
          Only windows that have not started are cancelled. Active windows keep their saved end time; open an individual window to end it early. Other maintenance and acknowledgements remain in effect.
        </p>
        <form
          id="maintenance-series-cancel-form"
          phx-change="series_cancel_edit"
          phx-auto-recover="series_cancel_edit"
          phx-submit={if @preview, do: "series_cancel_apply", else: "series_cancel_preview"}
        >
          <input type="hidden" name="_id" value={@series["id"]} /><input
            type="hidden"
            name="revision"
            value={@cancel_revision}
          />
          <input :if={@preview} type="hidden" name="_review_token" value={@preview["review_token"]} />
          <div class="field space-top">
            <label for="maintenance-series-cancel-reason">Reason for cancellation</label>
            <textarea
              id="maintenance-series-cancel-reason"
              name="reason"
              maxlength="500"
              required
              readonly={not is_nil(@preview)}
            >{@cancel_reason}</textarea>
          </div>
          <div :if={@preview} id="maintenance-series-cancel-preview" class="space-top">
            <p id="maintenance-series-cancel-summary">
              Cancel {count_label(
                @preview["upcoming_count"] || @preview["total"] || 0,
                "upcoming window"
              )}. Keep {count_label(@preview["active_count"] || 0, "active window")} unchanged.
            </p>
            <details
              id="maintenance-series-cancel-dates"
              class="space-top"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>Inspect windows to cancel ({@preview["total"]})</summary>
              <.occurrence_rows
                rows={@preview["rows"] || []}
                timezone={@series["timezone"]}
                saved={false}
              />
              <nav
                :if={(@preview["pages"] || 1) > 1}
                class="pagination"
                aria-label="Windows reviewed for cancellation"
              >
                <button
                  :if={@preview["page"] > 1}
                  type="button"
                  class="button small"
                  phx-click="series_cancel_page"
                  phx-value-page={@preview["page"] - 1}
                >Previous dates</button>
                <span>Page {@preview["page"]} of {@preview["pages"]}</span>
                <button
                  :if={@preview["page"] < @preview["pages"]}
                  type="button"
                  class="button small"
                  phx-click="series_cancel_page"
                  phx-value-page={@preview["page"] + 1}
                >Next dates</button>
              </nav>
            </details>
          </div>
          <div class="form-actions">
            <button
              id="maintenance-series-cancel-confirm"
              class={"button " <> if(@preview, do: "danger", else: "primary")}
              phx-disable-with="Saving…"
            >{if @preview, do: "Confirm cancellation", else: "Review cancellation"}</button>
            <button :if={@preview} type="button" class="button" phx-click="series_cancel_back">Back to reason</button>
          </div>
          <p :if={@cancel_revision != @series["revision"]} role="alert" class="form-error">
            The series changed. Your reason is preserved.
            <button
              id="maintenance-series-cancel-current"
              type="button"
              class="button small"
              phx-click="series_cancel_open"
            >Review current series</button>
          </p>
        </form>
      </div>
    </section>
    <section class="panel space-top" id="maintenance-series-windows">
      <div class="panel-heading">
        <.dynamic_tag
          tag_name={"h#{@section_level}"}
          id="maintenance-series-windows-heading"
          tabindex="-1"
        >
          Scheduled windows ({@series["occurrence_total"]})
        </.dynamic_tag>
      </div>
      <div class="panel-body">
        <p id="maintenance-series-window-help">
          {if series_remaining?(@series),
            do:
              "Inspect any date and its history. Only active or upcoming windows can still be changed or cancelled.",
            else:
              "All windows have ended or been cancelled. Inspect any date and its retained history."} Individually changed dates remain part of this series.
        </p>
        <.occurrence_rows
          rows={@series["occurrences"] || []}
          timezone={@series["timezone"]}
          saved={true}
        />
        <nav
          :if={(@series["occurrence_pages"] || 1) > 1}
          class="pagination"
          aria-label="Saved maintenance dates"
        >
          <.link
            :if={@series["occurrence_page"] > 1}
            patch={
              series_page_path(
                @series_path || series_path(@series["id"]) <> "?" <> URI.encode_query(@params),
                "occurrence_page",
                @series["occurrence_page"] - 1
              )
            }
            class="button small"
          >Previous dates</.link>
          <span>Page {@series["occurrence_page"]} of {@series["occurrence_pages"]}</span>
          <.link
            :if={@series["occurrence_page"] < @series["occurrence_pages"]}
            patch={
              series_page_path(
                @series_path || series_path(@series["id"]) <> "?" <> URI.encode_query(@params),
                "occurrence_page",
                @series["occurrence_page"] + 1
              )
            }
            class="button small"
          >Next dates</.link>
        </nav>
      </div>
    </section>
    <section class="panel space-top">
      <div class="panel-body">
        <p>
          {if series_remaining?(@series),
            do: "Current matches:",
            else: "Results currently matching the saved scope:"} {count_label(
            get_in(@series, ["counts", "matched_results"]) || @series["result_total"] || 0,
            "result"
          )}.
          <span id="maintenance-series-membership-help">{if series_remaining?(@series),
            do: series_membership_copy(@series["scope"]),
            else:
              "This saved scope would match these results, but no notification hold remains from this series."}</span>
          Current membership does not predict future health or coverage.
        </p>
        <details
          id="maintenance-series-results"
          class="space-top"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Inspect currently matching results</summary><.matches
            rows={@series["rows"] || []}
            current_path={@current_path}
            section_level={@section_level}
          />
          <nav
            :if={(@series["result_pages"] || 1) > 1}
            class="pagination"
            aria-label="Series current result pages"
          >
            <.link
              :if={@series["result_page"] > 1}
              patch={
                series_page_path(
                  @series_path || series_path(@series["id"]) <> "?" <> URI.encode_query(@params),
                  "result_page",
                  @series["result_page"] - 1
                )
              }
              class="button small"
            >Previous results</.link>
            <span>Page {@series["result_page"]} of {@series["result_pages"]}</span>
            <.link
              :if={@series["result_page"] < @series["result_pages"]}
              patch={
                series_page_path(
                  @series_path || series_path(@series["id"]) <> "?" <> URI.encode_query(@params),
                  "result_page",
                  @series["result_page"] + 1
                )
              }
              class="button small"
            >Next results</.link>
          </nav>
        </details>
      </div>
    </section>
    <section class="panel space-top" id="maintenance-series-history">
      <div class="panel-heading">
        <.dynamic_tag tag_name={"h#{@section_level}"}>Series history</.dynamic_tag>
      </div><div class="panel-body">
        <p>
          Showing {length(@series["history"] || [])} of {@series["history_count"] || 0} series decisions. Individual window pages retain their own edits and cancellations.
        </p>
        <article :for={event <- @series["history"] || []} class="maintenance-history-event">
          <.dynamic_tag tag_name={"h#{@section_level + 1}"}>
            {series_event_label(event["kind"])}
          </.dynamic_tag>
          <p :if={get_in(event, ["snapshot", "window_id"])}>
            <.link navigate={window_path(event["snapshot"]["window_id"])} class="text-link">Window {event[
              "snapshot"
            ]["index"]}: inspect this change</.link>
          </p>
          <p :if={get_in(event, ["snapshot", "count"])}>
            {count_label(event["snapshot"]["count"], "window")}.
          </p>
          <p>{event["reason"]}</p><small>{event["actor"] || "Local operator"} · {utc_time(
            event["inserted_at"]
          )} · revision {event["revision"]}</small>
        </article>
      </div>
    </section>
    """
  end

  defp revision_facts(assigns) do
    ~H"""
    <PreviewDetail.facts label="Window at this revision">
      <tr>
        <th scope="row">Name</th><td>{@window["name"]}</td>
      </tr>
      <tr>
        <th scope="row">Scope</th><td>{scope_label(@window)}</td>
      </tr>
      <tr>
        <th scope="row">Starts</th><td>{utc_time(@window["starts_at"])}</td>
      </tr>
      <tr>
        <th scope="row">Ends</th><td>{utc_time(@window["ends_at"])}</td>
      </tr>
      <tr :if={@window["timezone"] not in [nil, "UTC", "Etc/UTC"]}>
        <th scope="row">Local schedule</th>
        <td>
          {local_time(@window["starts_at"], @window["timezone"])} to {local_time(
            @window["ends_at"],
            @window["timezone"]
          )}
        </td>
      </tr>
      <tr>
        <th scope="row">Timezone</th><td>{@window["timezone"] || "UTC"}</td>
      </tr>
      <tr>
        <th scope="row">Duration</th><td>{duration(@window["starts_at"], @window["ends_at"])}</td>
      </tr>
      <tr :if={@window["cancelled_at"]}>
        <th scope="row">{cancellation_label(@window)} at</th><td>
          {utc_time(@window["cancelled_at"])}
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  attr :window, :map, required: true

  def times(assigns) do
    assigns = assign(assigns, cancelled: not is_nil(assigns.window["cancelled_at"]))

    ~H"""
    <dl class="maintenance-times space-top">
      <div>
        <dt>{if @cancelled, do: "Scheduled start", else: "Starts"}</dt><dd>
          {local_time(@window["starts_at"], @window["timezone"])}<small>{utc_time(
            @window["starts_at"]
          )}</small>
        </dd>
      </div>
      <div>
        <dt>{if @cancelled, do: "Scheduled end", else: "Ends"}</dt><dd>
          {local_time(@window["ends_at"], @window["timezone"])}<small>{utc_time(@window["ends_at"])}</small>
        </dd>
      </div>
      <div>
        <dt>Timezone</dt><dd>{@window["timezone"] || "UTC"}</dd>
      </div>
      <div>
        <dt>{if @cancelled, do: "Planned duration", else: "Duration"}</dt><dd>
          {duration(@window["starts_at"], @window["ends_at"])}
        </dd>
      </div>
      <div :if={@cancelled}>
        <dt>{cancellation_label(@window)} at</dt><dd>
          {local_time(@window["cancelled_at"], @window["timezone"])}<small>{utc_time(
            @window["cancelled_at"]
          )}</small>
        </dd>
      </div>
    </dl>
    """
  end

  attr :rows, :list, required: true

  attr :current_path, :string, required: true
  attr :section_level, :integer, values: [2, 3], default: 2

  def matches(assigns) do
    ~H"""
    <div class="space-top maintenance-matches">
      <.dynamic_tag tag_name={"h#{@section_level + 1}"}>Currently matching results</.dynamic_tag>
      <p :if={@rows == []}>No current results match.</p>
      <ul :if={@rows != []} class="maintenance-candidates">
        <li :for={row <- @rows}>
          <.link patch={related_result_path(@current_path, row["id"])} class="text-link">{row["label"] ||
            row["check_label"]}</.link>
          <small>Scheduled check: {row["check_label"]} · {row["environment"] ||
            "No declared environment"} · {row["runner_label"] || row["runner_id"]}</small>
          <small>Target: {target_label(row["target"] || %{})}</small>
        </li>
      </ul>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :timezone, :string, required: true
  attr :saved, :boolean, required: true

  def occurrence_rows(assigns) do
    ~H"""
    <ol class="maintenance-series-dates">
      <li :for={row <- @rows} data-window-index={row["index"] || row["series_index"]}>
        <div class="maintenance-date-heading">
          <strong>Window {row["index"] || row["series_index"]}</strong>
          <span :if={row["status"]} class="badge">{status_label(row)}</span>
          <span :if={row["exception"]} class="badge">Changed from original</span>
        </div>
        <p>{local_time(row["starts_at"], @timezone)} → {local_time(row["ends_at"], @timezone)}</p>
        <p class="footnote">
          {utc_time(row["starts_at"])} → {utc_time(row["ends_at"])} · {duration_label(row)}
        </p>
        <p :if={row["touches_previous"]} class="notice notice-copy">
          Touches the previous window: maintenance continues without a gap.
        </p>
        <p :if={(row["overlap_count"] || 0) > 0}>
          {count_label(row["overlap_count"], "overlapping independent window")}.
        </p>
        <.link
          :if={@saved && row["id"]}
          navigate={window_path(row["id"])}
          class="text-link"
        >{if editable?(row),
          do: "Inspect or change this window",
          else: "Inspect this window"}</.link>
      </li>
    </ol>
    """
  end
end

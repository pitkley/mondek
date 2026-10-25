# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceLive do
  use MondekWeb, :live_view

  alias Mondek.{Maintenance, MaintenanceSchedules, MaintenanceSelection, MaintenanceTime}
  alias Phoenix.LiveView.JS

  @proposal_fields ~w(id revision name reason scope assignment_id source_id environment target_kind target_key selections timezone start_mode starts_local ends_local start_fold end_fold recurrence)
  @editable_fields ~w(name reason timezone start_mode starts_local ends_local start_fold end_fold)
  @scope_fields ~w(scope assignment_id source_id environment target_kind target_key)
  @selection_filter_fields ~w(kind search environment source_id runner_id)
  @max_draft_bytes 2_097_152

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mondek.PubSub, "monitoring")
      Process.send_after(self(), :tick, 2_000)
    end

    {:ok,
     assign(socket,
       navigation_counts: Mondek.Inspection.navigation_counts(now),
       now: now,
       page_title: "Maintenance",
       listing: %{},
       filters: %{},
       window: nil,
       series: nil,
       series_params: %{},
       series_cancel_preview: nil,
       proposal: nil,
       scope_options: [],
       preview: nil,
       review_token: nil,
       error: nil,
       notice: nil,
       draft_origin: nil,
       selection_filters: %{"kind" => "check", "page" => 1},
       selected_only: false,
       selected_page: 1,
       selected_rows: [],
       saved_selection_page: 1,
       settings_recovered: false,
       selection_recovered: false,
       candidates: %{},
       filter_choices: nil,
       cancel_open: false,
       cancel_reason: "",
       cancel_revision: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if socket.assigns.live_action == :series do
      filters = Map.take(params, ~w(occurrence_page result_page))

      case MaintenanceSchedules.get(params["id"], filters) do
        {:ok, series} ->
          same = socket.assigns.series && socket.assigns.series["id"] == params["id"]

          {:noreply,
           socket
           |> assign(
             series: series,
             series_params: Map.take(series, ~w(occurrence_page result_page)),
             window: nil,
             proposal: nil,
             cancel_reason: if(same, do: socket.assigns.cancel_reason, else: ""),
             cancel_open: same && socket.assigns.cancel_open,
             series_cancel_preview: if(same, do: socket.assigns.series_cancel_preview, else: nil),
             error: nil
           )
           |> load_series_selection()}

        {:error, reason} ->
          {:noreply,
           assign(socket, series: nil, window: nil, proposal: nil, error: error_message(reason))}
      end
    else
      regular_params(params, socket)
    end
  end

  defp regular_params(params, socket) do
    socket =
      assign(socket,
        series: nil,
        error: nil,
        notice: nil,
        preview: nil,
        review_token: nil,
        cancel_open: false,
        cancel_reason: "",
        cancel_revision: nil
      )

    case socket.assigns.live_action do
      :index ->
        filters = Map.take(params, ~w(status assignment_id stream_id page))

        {:noreply,
         socket |> assign(filters: filters, window: nil, proposal: nil) |> refresh_list()}

      :new ->
        socket =
          assign(socket,
            draft_origin: params["copy_series"] || params["check_id"] || "selection",
            settings_recovered: false,
            selection_recovered: false,
            selected_only: false,
            selected_page: 1,
            selection_filters: %{"kind" => "check", "page" => 1}
          )

        cond do
          params["copy_series"] ->
            case MaintenanceSchedules.get(params["copy_series"]) do
              {:ok, series} ->
                proposal =
                  series["proposal"] |> Map.take(@proposal_fields) |> Map.drop(~w(id revision))

                {:noreply,
                 socket
                 |> assign(
                   window: nil,
                   proposal: proposal,
                   scope_options: [
                     Map.put(Map.take(proposal, @scope_fields), "label", scope_label(series))
                   ],
                   notice:
                     "Copied the series into a new draft. Choose a future first window and review all dates. Existing windows are unchanged; cancel upcoming windows separately if needed."
                 )
                 |> load_candidates()
                 |> load_selected()}

              {:error, reason} ->
                {:noreply, assign(socket, proposal: nil, error: error_message(reason))}
            end

          params["check_id"] ->
            case Maintenance.seed(params["check_id"], params["stream_id"]) do
              {:ok, seed} ->
                {:noreply,
                 socket
                 |> assign(
                   window: nil,
                   proposal: Map.take(seed["proposal"], @proposal_fields),
                   scope_options: seed["scope_options"] || []
                 )
                 |> load_candidates()}

              {:error, reason} ->
                {:noreply, assign(socket, proposal: nil, error: error_message(reason))}
            end

          true ->
            {:noreply,
             socket
             |> assign(
               window: nil,
               proposal: MaintenanceSelection.proposal([]),
               scope_options: []
             )
             |> load_candidates()
             |> load_selected()}
        end

      :edit ->
        case Maintenance.get(params["id"]) do
          {:ok, window} ->
            {:noreply, socket |> assign(draft_origin: params["id"]) |> load_window(window)}

          {:error, reason} ->
            {:noreply, assign(socket, window: nil, proposal: nil, error: error_message(reason))}
        end
    end
  end

  @impl true
  def handle_info(:changed, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    now = Mondek.Monitoring.now()

    socket =
      assign(socket, now: now, navigation_counts: Mondek.Inspection.navigation_counts(now))

    {:noreply, refresh_current(socket)}
  end

  @impl true
  def handle_event("selection_change", form, socket) do
    {:noreply, change_selection(socket, form)}
  end

  def handle_event("recover_selection", form, socket) do
    with {:ok, captured} <- decode_draft(form["_proposal"]),
         true <- recovery_matches?(captured, socket.assigns),
         true <- captured["scope"] == "selection",
         {:ok, page} <- decode_selectors(form["_page_selections"], 25, 131_072) do
      proposal =
        Map.merge(socket.assigns.proposal, Map.take(captured, @scope_fields ++ ["selections"]))

      {:noreply,
       socket
       |> assign(proposal: proposal, selection_recovered: true)
       |> change_selection(form, page)
       |> assign(notice: "Draft restored. Preview again before saving.")}
    else
      _ ->
        {:noreply,
         assign(socket,
           error: "The selected checks or targets could not be restored. Reopen this draft."
         )}
    end
  end

  def handle_event(
        "include_more",
        _,
        %{assigns: %{window: nil, proposal: %{"scope" => scope}}} = socket
      )
      when scope in ["check", "target"] do
    selections = [Map.take(socket.assigns.proposal, @scope_fields)]

    proposal =
      Map.merge(
        socket.assigns.proposal,
        MaintenanceSelection.proposal(selections) |> Map.take(@scope_fields ++ ["selections"])
      )

    {:noreply,
     socket
     |> assign(proposal: proposal)
     |> invalidate_review()
     |> load_selected()
     |> load_candidates()}
  end

  def handle_event("include_more", _, socket), do: {:noreply, socket}

  def handle_event("selection_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, selected_only: view == "selected", selected_page: 1)}
  end

  def handle_event("selection_page", %{"page" => page}, socket) do
    if socket.assigns.selected_only do
      {:noreply,
       assign(socket,
         selected_page: min(positive_integer(page), selected_pages(socket.assigns.selected_rows))
       )}
    else
      filters = Map.put(socket.assigns.selection_filters, "page", positive_integer(page))
      {:noreply, socket |> assign(selection_filters: filters) |> load_candidates()}
    end
  end

  def handle_event("select_page", _, socket) do
    {:noreply, add_selections(socket, socket.assigns.candidates["items"] || [])}
  end

  def handle_event("select_matching", _, socket) do
    case MaintenanceSelection.all(socket.assigns.selection_filters) do
      {:ok, rows} -> {:noreply, add_selections(socket, rows)}
      {:error, reason} -> {:noreply, assign(socket, error: error_message(reason))}
    end
  end

  def handle_event("remove_selection", %{"key" => key}, socket) do
    selections =
      Enum.reject(selections(socket.assigns.proposal), &(MaintenanceSelection.key(&1) == key))

    {:noreply, put_selections(socket, selections)}
  end

  def handle_event("clear_selection", _, socket), do: {:noreply, put_selections(socket, [])}

  def handle_event("saved_selection_page", %{"page" => page}, socket) do
    {:noreply,
     assign(socket,
       saved_selection_page:
         min(positive_integer(page), selected_pages(socket.assigns.selected_rows))
     )}
  end

  def handle_event("edit", form, socket) do
    {:noreply, socket |> invalidate_review() |> keep_draft(form)}
  end

  def handle_event("recover", form, socket) do
    with {:ok, captured} <- decode_draft(form["_proposal"]),
         true <- recovery_matches?(captured, socket.assigns) do
      proposal = Map.take(captured, @proposal_fields)

      proposal =
        if socket.assigns.selection_recovered,
          do:
            Map.merge(
              proposal,
              Map.take(socket.assigns.proposal, @scope_fields ++ ["selections"])
            ),
          else: proposal

      socket =
        socket
        |> assign(proposal: proposal, settings_recovered: true)
        |> keep_draft(form)
        |> invalidate_review()
        |> load_selected()

      {:noreply, assign(socket, notice: recovery_notice(socket.assigns))}
    else
      _ ->
        {:noreply,
         assign(socket,
           error:
             "This draft does not belong to the selected maintenance scope. Reopen the window or check."
         )}
    end
  end

  def handle_event("preview", form, socket) do
    socket = keep_draft(socket, form)

    result =
      if socket.assigns.error,
        do: {:error, socket.assigns.error},
        else: preview_proposal(socket.assigns.proposal)

    case result do
      {:ok, preview} ->
        {:noreply,
         assign(socket,
           proposal: preview["proposal"] || socket.assigns.proposal,
           preview: preview,
           review_token: preview["review_token"],
           error: nil,
           notice: nil
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_current()
         |> assign(error: error_message(reason), preview: nil, review_token: nil)}
    end
  end

  def handle_event("save", form, socket) do
    with token when is_binary(token) <- socket.assigns.review_token,
         true <- token == form["_review_token"],
         {:ok, window} <- apply_proposal(token, socket.assigns.proposal) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Maintenance #{if repeating?(socket.assigns.proposal), do: "series", else: "window"} saved. Checks and recovery notifications continue."
       )
       |> push_navigate(
         to:
           if(repeating?(socket.assigns.proposal),
             do: series_path(window["id"]),
             else: window_path(window["id"])
           )
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_current()
         |> assign(error: error_message(reason), preview: nil, review_token: nil)}

      _ ->
        {:noreply,
         assign(socket,
           error: "Preview this draft before saving.",
           preview: nil,
           review_token: nil
         )}
    end
  end

  def handle_event("back", _, socket), do: {:noreply, invalidate_review(socket)}

  def handle_event("preview_page", %{"page" => page}, socket) do
    with old when is_map(old) <- socket.assigns.preview,
         {:ok, preview} <-
           preview_proposal(
             socket.assigns.proposal,
             positive_integer(page),
             old["occurrence_page"] || 1,
             socket.assigns.review_token
           ),
         true <- old["fingerprint"] == preview["fingerprint"] do
      {:noreply, assign(socket, preview: preview)}
    else
      _ ->
        {:noreply, socket |> invalidate_review() |> assign(error: error_message(:review_changed))}
    end
  end

  def handle_event("occurrence_preview_page", %{"page" => page}, socket) do
    result =
      with old when is_map(old) <- socket.assigns.preview,
           token when is_binary(token) <- socket.assigns.review_token do
        preview_proposal(
          socket.assigns.proposal,
          old["result_page"] || 1,
          positive_integer(page),
          token
        )
      else
        _ -> {:error, :invalid_review}
      end

    case result do
      {:ok, preview} ->
        {:noreply, assign(socket, preview: preview)}

      {:error, reason} ->
        {:noreply, socket |> invalidate_review() |> assign(error: error_message(reason))}
    end
  end

  def handle_event("series_cancel_edit", form, socket) do
    {:noreply, series_cancel_draft(socket, form)}
  end

  def handle_event("series_cancel_open", _, socket) do
    {:noreply,
     assign(socket,
       cancel_open: true,
       cancel_revision: socket.assigns.series["revision"],
       series_cancel_preview: nil,
       error: nil
     )}
  end

  def handle_event("series_cancel_back", _, socket),
    do: {:noreply, assign(socket, series_cancel_preview: nil, error: nil)}

  def handle_event("series_cancel_preview", form, socket) do
    socket = series_cancel_draft(socket, form)

    result =
      if socket.assigns.error,
        do: {:error, socket.assigns.error},
        else:
          MaintenanceSchedules.cancel_preview(
            socket.assigns.series["id"],
            socket.assigns.cancel_revision,
            socket.assigns.cancel_reason
          )

    case result do
      {:ok, preview} ->
        {:noreply, assign(socket, series_cancel_preview: preview)}

      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_current()
         |> assign(series_cancel_preview: nil, error: series_error_message(reason))}
    end
  end

  def handle_event("series_cancel_page", %{"page" => page}, socket) do
    preview = socket.assigns.series_cancel_preview

    case preview &&
           MaintenanceSchedules.cancel_preview(
             socket.assigns.series["id"],
             socket.assigns.cancel_revision,
             socket.assigns.cancel_reason,
             positive_integer(page),
             nil,
             preview["review_token"]
           ) do
      {:ok, preview} ->
        {:noreply, assign(socket, series_cancel_preview: preview)}

      _ ->
        {:noreply,
         socket
         |> refresh_current()
         |> assign(series_cancel_preview: nil, error: series_error_message(:review_changed))}
    end
  end

  def handle_event("series_cancel_apply", form, socket) do
    preview = socket.assigns.series_cancel_preview

    with true <- is_map(preview) && preview["review_token"] == form["_review_token"],
         {:ok, series} <-
           MaintenanceSchedules.cancel(
             socket.assigns.series["id"],
             preview["review_token"],
             socket.assigns.cancel_reason
           ) do
      series =
        case MaintenanceSchedules.get(series["id"], socket.assigns.series_params) do
          {:ok, current} -> current
          _ -> series
        end

      {:noreply,
       socket
       |> assign(
         series: series,
         series_cancel_preview: nil,
         cancel_open: false,
         notice:
           "Upcoming windows cancelled. Active windows, other maintenance and acknowledgements are unchanged.",
         error: nil
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_current()
         |> assign(series_cancel_preview: nil, error: series_error_message(reason))}

      _ ->
        {:noreply, assign(socket, error: "Review the upcoming windows before cancelling them.")}
    end
  end

  def handle_event("review_current", _, socket) do
    socket = refresh_current(socket)

    if socket.assigns.window do
      current =
        socket.assigns.window["proposal"] || Map.take(socket.assigns.window, @proposal_fields)

      fields =
        if socket.assigns.window["status"] == "active",
          do: @scope_fields ++ ~w(revision timezone start_mode starts_local start_fold),
          else: ~w(revision)

      {:noreply,
       socket
       |> assign(proposal: Map.merge(socket.assigns.proposal, Map.take(current, fields)))
       |> invalidate_review()
       |> assign(
         notice:
           "Current saved window reviewed. Your proposed name, reason and end time are preserved. Active windows keep their saved start and timezone; recheck the end time in your preview."
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_cancel", _, socket) do
    {:noreply,
     assign(socket,
       cancel_open: true,
       cancel_revision: socket.assigns.proposal["revision"],
       preview: nil,
       review_token: nil,
       error: nil
     )}
  end

  def handle_event("hide_cancel", _, socket), do: {:noreply, assign(socket, cancel_open: false)}

  def handle_event("edit_cancel", form, socket) do
    {:noreply, keep_cancel_draft(socket, form)}
  end

  def handle_event("cancel", form, socket) do
    socket = keep_cancel_draft(socket, form)

    result =
      if socket.assigns.error || !socket.assigns.cancel_open,
        do: {:error, socket.assigns.error || "Review the window before ending it."},
        else:
          Maintenance.cancel(
            socket.assigns.window["id"],
            integer(socket.assigns.cancel_revision),
            socket.assigns.cancel_reason
          )

    case result do
      {:ok, window} ->
        message =
          if socket.assigns.window["status"] == "active",
            do: "Maintenance ended.",
            else: "Maintenance window cancelled."

        {:noreply,
         socket
         |> put_flash(
           :info,
           message <> " Other maintenance windows and acknowledgements remain in effect."
         )
         |> push_navigate(to: window_path(window["id"]))}

      {:error, reason} ->
        {:noreply, socket |> refresh_current() |> assign(error: error_message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={:maintenance}
      page_title="Maintenance"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
      main_class="maintenance-page"
    >
      <.link :if={@live_action != :index} navigate="/maintenance" class="back">All maintenance windows</.link>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Notification maintenance</div><h1>
            {page_heading(@live_action, @window || @series)}
          </h1>
          <p>
            Hold failure notifications during planned work. Checks, measured health and recovery notifications continue.
          </p>
        </div>
        <.link :if={@live_action == :index} navigate="/maintenance/new" class="button primary">Schedule maintenance</.link>
      </div>
      <p :if={@error} id="maintenance-error" class="form-error" role="alert">{@error}</p>
      <p :if={@notice} id="maintenance-notice" class="notice notice-copy" role="status">
        {@notice}
      </p>
      <div
        :if={stale?(@window, @proposal)}
        class="notice notice-copy space-top"
        id="maintenance-stale"
      >
        This window changed after you started editing. Your draft is preserved.
        <button
          id="maintenance-review-current"
          type="button"
          class="button small"
          phx-click="review_current"
        >Review current saved window</button>
      </div>
      <.window_list :if={@live_action == :index} listing={@listing} filters={@filters} />
      <.series_detail
        :if={@series}
        series={@series}
        params={@series_params}
        cancel_open={@cancel_open}
        cancel_reason={@cancel_reason}
        cancel_revision={@cancel_revision}
        preview={@series_cancel_preview}
      />
      <.selection_chooser
        :if={@live_action == :new && @proposal}
        candidates={@candidates}
        filter_choices={@filter_choices || %{}}
        filters={@selection_filters}
        proposal={@proposal}
        selected_rows={@selected_rows}
        selected_only={@selected_only}
        selected_page={@selected_page}
        draft_origin={@draft_origin}
        preview={@preview}
      />
      <.saved_window :if={@window} window={@window} />
      <.saved_selection
        :if={
          (@series && @series["proposal"]["scope"] == "selection") ||
            (@window && @window["scope"] == "selection") ||
            (@preview && @proposal["scope"] == "selection")
        }
        rows={@selected_rows}
        page={@saved_selection_page}
        saved={not is_nil(@window) || not is_nil(@series)}
      />
      <.editor
        :if={@proposal && editable?(@window)}
        proposal={@proposal}
        window={@window}
        scope_options={@scope_options}
        preview={@preview}
        token={@review_token}
        stale={stale?(@window, @proposal)}
        draft_origin={@draft_origin}
      />
      <section
        :if={@window && editable?(@window)}
        class="panel space-top"
        id="maintenance-cancellation"
      >
        <div class="panel-body">
          <button
            :if={!@cancel_open}
            id="maintenance-cancel"
            type="button"
            class="button danger"
            phx-click="show_cancel"
            disabled={stale?(@window, @proposal)}
          >{cancel_label(@window)}</button>
          <form
            id="maintenance-cancel-form"
            style={if !@cancel_open, do: "display: none"}
            phx-change="edit_cancel"
            phx-auto-recover="edit_cancel"
            phx-submit="cancel"
          >
            <input type="hidden" name="_id" value={@window["id"]} />
            <input type="hidden" name="_open" value={to_string(@cancel_open)} />
            <input type="hidden" name="revision" value={@cancel_revision} />
            <h2>{cancel_label(@window)}</h2>
            <p class="space-top">
              This ends only this window. Failure notifications become eligible only when no other maintenance window or acknowledgement holds them. An attempt already underway may finish.
            </p>
            <div class="field space-top">
              <label for="maintenance-cancel-reason">Reason for ending or cancelling</label>
              <textarea id="maintenance-cancel-reason" name="reason" required maxlength="500">{@cancel_reason}</textarea>
            </div>
            <div class="form-actions">
              <button
                id="maintenance-confirm-cancel"
                class="button danger"
                disabled={integer(@cancel_revision) != @window["revision"]}
                phx-disable-with="Saving…"
              >Confirm {String.downcase(cancel_label(@window))}</button>
              <button type="button" class="button" phx-click="hide_cancel">Keep window</button>
            </div>
            <p
              :if={integer(@cancel_revision) != @window["revision"]}
              role="alert"
              class="form-error"
            >
              The window changed. Review it, then open this action again; your reason is preserved.
            </p>
          </form>
        </div>
      </section>
      <.history
        :if={@window}
        events={@window["history"] || []}
        total={@window["history_count"] || 0}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp window_list(assigns) do
    ~H"""
    <nav class="maintenance-tabs" aria-label="Maintenance views">
      <.link
        patch={list_path(@filters, %{"status" => "current", "page" => 1})}
        class="button"
        aria-current={if @filters["status"] != "history", do: "page"}
      >Active & upcoming</.link>
      <.link
        patch={list_path(@filters, %{"status" => "history", "page" => 1})}
        class="button"
        aria-current={if @filters["status"] == "history", do: "page"}
      >History</.link>
      <.link
        :if={@filters["assignment_id"] || @filters["stream_id"]}
        navigate="/maintenance"
        class="text-link"
      >Show every scope</.link>
    </nav>
    <p :if={(@listing["windows"] || []) == []} class="empty">No maintenance windows in this view.</p>
    <div class="maintenance-window-list" id="maintenance-list">
      <article
        :for={window <- @listing["windows"] || []}
        id={"maintenance-window-" <> window["id"]}
        class="panel"
      >
        <div class="panel-heading">
          <h2><.link navigate={entry_path(window)}>{window["name"]}</.link></h2><span class="badge">{status_label(
            window
          )}</span>
        </div>
        <div class="panel-body">
          <p>{scope_label(window)}</p><p class="space-top">
            {window["reason"]}
          </p>
          <.series_summary :if={window["kind"] == "series"} series={window} />
          <.times :if={window["kind"] != "series"} window={window} />
        </div>
      </article>
    </div>
    <nav :if={pages(@listing) > 1} class="pagination" aria-label="Maintenance pages">
      <.link
        :if={(@listing["page"] || 1) > 1}
        patch={list_path(@filters, %{"page" => @listing["page"] - 1})}
        class="button small"
      >Previous</.link>
      <span>Page {@listing["page"] || 1} of {pages(@listing)}</span>
      <.link
        :if={(@listing["page"] || 1) < pages(@listing)}
        patch={list_path(@filters, %{"page" => @listing["page"] + 1})}
        class="button small"
      >Next</.link>
    </nav>
    """
  end

  defp selection_chooser(assigns) do
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
                navigate={new_path(row["assignment_id"])}
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

  defp saved_selection(assigns) do
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

  defp saved_window(assigns) do
    ~H"""
    <section class="panel" id="maintenance-saved">
      <div class="panel-heading">
        <h2>Saved window</h2><span class="badge">{status_label(@window)}</span>
      </div>
      <div class="panel-body">
        <p
          :if={@window["series_id"]}
          id="maintenance-series-membership"
          class="notice notice-copy space-top"
        >
          Window {@window["series_index"]} of a weekly series.
          <.link navigate={series_path(@window["series_id"])} class="text-link">Inspect the series</.link>
          Editing or cancelling here changes only this window; the other dates stay scheduled.
        </p>
        <p>{@window["reason"]}</p><p class="space-top">{scope_label(@window)}</p><.times window={
          @window
        } />
        <p class="footnote space-top">
          Recorded by {@window["actor"] || "Local operator"}. Revision {@window["revision"]}. Saved UTC instants remain fixed across timezone database updates.
        </p>
        <p :if={!editable?(@window)} class="notice notice-copy space-top">
          This window is retained for history and can no longer be edited.
        </p>
        <p :if={@window["cancelled_at"]} class="space-top">
          {status_label(@window)} at {utc_time(@window["cancelled_at"])} by {@window["cancelled_by"] ||
            "Local operator"}. {@window["cancellation_reason"]}
        </p>
        <p class="footnote space-top" id="maintenance-match-count">
          Current matches: {count_label(@window["match_count"] || 0, "result")}.
        </p>
        <details
          class="space-top"
          id="maintenance-saved-matches"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Inspect currently matching results ({@window["match_count"] || 0})</summary>
          <.matches rows={@window["current_matches"] || []} />
          <p class="footnote">
            Showing {length(@window["current_matches"] || [])} of {@window["match_count"] || 0} currently matching results. This detail view shows at most 25 matches.
          </p>
        </details>
      </div>
    </section>
    """
  end

  defp editor(assigns) do
    assigns =
      assign(assigns,
        active: assigns.window && assigns.window["status"] == "active",
        start_choices:
          MaintenanceTime.choices(assigns.proposal["starts_local"], assigns.proposal["timezone"]),
        end_choices:
          MaintenanceTime.choices(assigns.proposal["ends_local"], assigns.proposal["timezone"])
      )

    ~H"""
    <section
      class="panel space-top"
      id="maintenance-settings"
      style={if @proposal["scope"] == "selection" && selections(@proposal) == [], do: "display: none"}
    >
      <div class="panel-heading">
        <h2>{if @preview, do: "Review maintenance", else: "Window settings"}</h2>
      </div><div class="panel-body">
        <form
          id="maintenance-form"
          phx-change="edit"
          phx-auto-recover="recover"
          phx-submit={if @preview, do: "save", else: "preview"}
        >
          <input type="hidden" name="_proposal" value={encoded_draft(@proposal, @draft_origin)} />
          <input :if={@preview} type="hidden" name="_review_token" value={@token} />
          <div :if={!@preview}>
            <div class="form-grid">
              <div class="field full">
                <label for="maintenance-name">Window name</label><input
                  id="maintenance-name"
                  name="window[name]"
                  value={@proposal["name"]}
                  maxlength="200"
                  required
                />
              </div>
              <div class="field full">
                <label for="maintenance-reason">Reason</label><textarea
                  id="maintenance-reason"
                  name="window[reason]"
                  maxlength="500"
                  required
                >{@proposal["reason"]}</textarea>
              </div>
              <div :if={@proposal["scope"] != "selection"} class="field full">
                <label for="maintenance-scope">Notification scope</label><select
                  id="maintenance-scope"
                  name="scope_choice"
                  disabled={not is_nil(@window)}
                >
                  <option
                    :for={option <- @scope_options}
                    value={scope_key(option)}
                    selected={same_scope?(option, @proposal)}
                  >
                    {option["label"] || scope_label(option)}
                  </option>
                </select><small>{scope_label(@proposal, @scope_options)}</small>
              </div>
              <div :if={@proposal["scope"] == "selection"} class="field full">
                <span class="field-label">Notification scope</span><p id="maintenance-selection-scope">
                  {scope_label(@proposal)}. All matching results are counted once, even when selections overlap.
                </p>
              </div>
            </div>
            <button
              :if={is_nil(@window) && @proposal["scope"] != "selection"}
              id="maintenance-include-more"
              type="button"
              class="button small space-top"
              phx-click="include_more"
            >Include more checks or targets</button>
            <p
              :if={@proposal["scope"] == "target"}
              class="notice notice-copy space-top"
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
            <p :if={@active} class="notice notice-copy space-top">
              This window has started. Its scope, timezone and start time are fixed; you can change its name, reason and end time.
            </p>
            <div class="form-grid space-top">
              <div :if={is_nil(@window)} class="field full">
                <label for="maintenance-repeat">Repeat</label>
                <select id="maintenance-repeat" name="repeat">
                  <option value="none" selected={!repeating?(@proposal)}>Does not repeat</option>
                  <option value="weekly" selected={repeating?(@proposal)}>Weekly series</option>
                </select>
              </div>
              <.recurrence_fields :if={repeating?(@proposal)} proposal={@proposal} />
              <div class="field full">
                <label for="maintenance-timezone">Timezone</label><input
                  id="maintenance-timezone"
                  name="window[timezone]"
                  value={@proposal["timezone"]}
                  list="maintenance-timezones"
                  maxlength="100"
                  required
                  readonly={@active}
                /><small>Use UTC or an IANA name. Both date fields use this timezone, regardless of your device settings.</small>
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
              <div class="field full">
                <label for="maintenance-start-mode">Start</label><select
                  id="maintenance-start-mode"
                  name="window[start_mode]"
                  disabled={@active}
                ><option value="scheduled" selected={@proposal["start_mode"] == "scheduled"}>
                  At a date and time
                </option><option
                  :if={!repeating?(@proposal)}
                  value="now"
                  selected={@proposal["start_mode"] == "now"}
                >
                  Now
                </option></select>
              </div>
              <div :if={@proposal["start_mode"] != "now"} class="field">
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
                  readonly={@active}
                />
                <.fold_choice
                  :if={!@active && !repeating?(@proposal) && @start_choices != []}
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
            </div>
            <div class="form-actions">
              <p>Preview exact times, current matches and overlapping windows before saving.</p><button
                id="maintenance-preview-button"
                class="button primary"
                disabled={@stale}
                phx-disable-with="Previewing…"
              >Preview maintenance</button>
            </div>
          </div>
          <div :if={@preview} id="maintenance-preview">
            <h3>{@proposal["name"]}</h3><p class="space-top">{@proposal["reason"]}</p><p class="space-top">
              {scope_label(@proposal, @scope_options)}
            </p>
            <.times
              :if={!repeating?(@proposal)}
              window={Map.merge(@proposal, Map.take(@preview, ~w(starts_at ends_at)))}
            />
            <.series_preview :if={repeating?(@proposal)} proposal={@proposal} preview={@preview} />
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
              class="space-top maintenance-results-disclosure"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>
                Inspect currently matching results ({get_in(@preview, ["counts", "matched_results"]) ||
                  0})
              </summary>
              <.matches rows={@preview["rows"] || []} />
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
              <h3>Overlapping windows</h3>
              <p :if={(@preview["overlaps"] || []) == []}>
                No overlapping maintenance windows currently match this scope.
              </p>
              <ul :if={(@preview["overlaps"] || []) != []} class="maintenance-candidates">
                <li :for={window <- @preview["overlaps"]}>
                  <.link navigate={window_path(window["id"])} class="text-link">{window["name"]}</.link><small>{utc_time(
                    window["starts_at"]
                  )} – {utc_time(window["ends_at"])}</small>
                </li>
              </ul>
              <p :if={(@preview["overlap_omitted"] || 0) > 0} class="footnote">
                Showing {length(@preview["overlaps"] || [])} of {@preview["overlap_total"]} overlapping windows.
                <.link navigate="/maintenance" class="text-link">Inspect maintenance</.link>
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
        Only failure notifications are held. Checks and recovery notifications continue. An attempt already underway may finish.
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
      <h3>Review every scheduled date</h3>
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
        <.occurrence_rows
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

  defp series_summary(assigns) do
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

  defp occurrence_rows(assigns) do
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
        <.link :if={@saved && row["id"]} navigate={window_path(row["id"])} class="text-link">{if editable?(
                                                                                                   row
                                                                                                 ),
                                                                                                 do:
                                                                                                   "Inspect or change this window",
                                                                                                 else:
                                                                                                   "Inspect this window"}</.link>
      </li>
    </ol>
    """
  end

  defp series_detail(assigns) do
    ~H"""
    <section class="panel" id="maintenance-series-saved">
      <div class="panel-heading">
        <h2>Saved maintenance series</h2><span class="badge">{status_label(@series)}</span>
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
            navigate={"/maintenance/new?copy_series=" <> @series["id"]}
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
        <h2>Cancel upcoming windows</h2>
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
        <h2 id="maintenance-series-windows-heading" tabindex="-1">
          Scheduled windows ({@series["occurrence_total"]})
        </h2>
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
              series_page_path(@series, @params, "occurrence_page", @series["occurrence_page"] - 1)
            }
            class="button small"
          >Previous dates</.link>
          <span>Page {@series["occurrence_page"]} of {@series["occurrence_pages"]}</span>
          <.link
            :if={@series["occurrence_page"] < @series["occurrence_pages"]}
            patch={
              series_page_path(@series, @params, "occurrence_page", @series["occurrence_page"] + 1)
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
          <summary>Inspect currently matching results</summary><.matches rows={@series["rows"] || []} />
          <nav
            :if={(@series["result_pages"] || 1) > 1}
            class="pagination"
            aria-label="Series current result pages"
          >
            <.link
              :if={@series["result_page"] > 1}
              patch={series_page_path(@series, @params, "result_page", @series["result_page"] - 1)}
              class="button small"
            >Previous results</.link>
            <span>Page {@series["result_page"]} of {@series["result_pages"]}</span>
            <.link
              :if={@series["result_page"] < @series["result_pages"]}
              patch={series_page_path(@series, @params, "result_page", @series["result_page"] + 1)}
              class="button small"
            >Next results</.link>
          </nav>
        </details>
      </div>
    </section>
    <section class="panel space-top" id="maintenance-series-history">
      <div class="panel-heading">
        <h2>Series history</h2>
      </div><div class="panel-body">
        <p>
          Showing {length(@series["history"] || [])} of {@series["history_count"] || 0} series decisions. Individual window pages retain their own edits and cancellations.
        </p>
        <article :for={event <- @series["history"] || []} class="maintenance-history-event">
          <h3>
            {series_event_label(event["kind"])}
          </h3>
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

  defp times(assigns) do
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

  defp matches(assigns) do
    ~H"""
    <div class="space-top maintenance-matches">
      <h3>Currently matching results</h3>
      <p :if={@rows == []}>No current results match.</p>
      <ul :if={@rows != []} class="maintenance-candidates">
        <li :for={row <- @rows}>
          <.link navigate={"/checks/" <> row["id"]} class="text-link">{row["label"] ||
            row["check_label"]}</.link>
          <small>Scheduled check: {row["check_label"]} · {row["environment"] ||
            "No declared environment"} · {row["runner_label"] || row["runner_id"]}</small>
          <small>Target: {target_label(row["target"] || %{})}</small>
        </li>
      </ul>
    </div>
    """
  end

  defp history(assigns) do
    ~H"""
    <section class="panel space-top" id="maintenance-history">
      <div class="panel-heading">
        <h2>Window history</h2>
      </div><div class="panel-body">
        <p :if={@events == []}>No retained events.</p>
        <p :if={@total > length(@events)} class="footnote">
          Showing the latest {length(@events)} of {@total} retained changes.
        </p>
        <div :for={event <- @events} class="maintenance-history-event">
          <h3>{event_label(event)}</h3><p>{event["reason"]}</p>
          <small>{event["actor"] || "Local operator"} · {utc_time(event["inserted_at"] || event["at"])} · revision {event[
            "revision"
          ]}</small>
          <details
            :if={is_map(event["snapshot"])}
            class="space-top"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Window at this revision</summary>
            <p class="space-top"><strong>{event["snapshot"]["name"]}</strong></p>
            <p>{scope_label(event["snapshot"])}</p>
            <a
              :if={event["snapshot"]["scope_window_id"]}
              href="#maintenance-saved-selection"
              class="text-link"
            >Inspect this window's fixed selection</a>
            <.times window={event["snapshot"]} />
          </details>
        </div>
      </div>
    </section>
    """
  end

  defp refresh_list(socket), do: assign(socket, listing: Maintenance.list(socket.assigns.filters))

  defp load_candidates(socket) do
    result = MaintenanceSelection.list(socket.assigns.selection_filters)

    assign(socket,
      candidates: result,
      filter_choices: socket.assigns.filter_choices || MaintenanceSelection.filter_choices(),
      selection_filters: Map.put(socket.assigns.selection_filters, "page", result["page"])
    )
  end

  defp load_selected(socket) do
    proposal = if socket.assigns.window, do: socket.assigns.window, else: socket.assigns.proposal
    rows = MaintenanceSelection.describe(selections(proposal))

    assign(socket,
      selected_rows: rows,
      selected_page: min(socket.assigns.selected_page, selected_pages(rows)),
      saved_selection_page: min(socket.assigns.saved_selection_page, selected_pages(rows))
    )
  end

  defp selections(%{"scope" => "selection", "selections" => selections}) when is_list(selections),
    do: selections

  defp selections(_), do: []
  defp selected_pages(rows), do: max(1, ceil(length(rows) / 25))
  defp selector_identity(row), do: Map.take(row, @scope_fields)

  defp add_selections(socket, rows),
    do:
      put_selections(
        socket,
        selections(socket.assigns.proposal) ++ Enum.map(rows, &Map.take(&1, @scope_fields))
      )

  defp put_selections(%{assigns: %{window: window}} = socket, _) when not is_nil(window),
    do: assign(socket, error: "A saved window's selection is fixed.")

  defp put_selections(socket, values) do
    values = Enum.uniq_by(values, &MaintenanceSelection.key/1)

    if MaintenanceSelection.valid?(values) do
      proposal =
        Map.put(socket.assigns.proposal, "selections", MaintenanceSelection.normalize(values))

      socket |> assign(proposal: proposal) |> invalidate_review() |> load_selected()
    else
      assign(socket,
        error:
          "A window can contain at most 512 valid checks or targets. Your selection is unchanged."
      )
    end
  end

  defp change_selection(socket, form, page_rows \\ nil) do
    keys = form["selected_keys"] || []

    with {:ok, page_rows} <-
           if(is_list(page_rows),
             do: {:ok, page_rows},
             else: decode_selectors(form["_page_selections"], 25, 131_072)
           ),
         true <-
           is_list(keys) && length(keys) <= 26 &&
             Enum.all?(keys, &(is_binary(&1) && byte_size(&1) <= 8_192)),
         {:ok, filters} <- selection_filters(form, socket.assigns.selection_filters) do
      visible = MapSet.new(page_rows, &MaintenanceSelection.key/1)
      chosen = MapSet.new(keys)

      retained =
        Enum.reject(
          selections(socket.assigns.proposal),
          &MapSet.member?(visible, MaintenanceSelection.key(&1))
        )

      added =
        Enum.filter(page_rows, &MapSet.member?(chosen, MaintenanceSelection.key(&1)))
        |> Enum.map(&Map.take(&1, @scope_fields))

      socket
      |> put_selections(retained ++ added)
      |> assign(
        selection_filters: filters,
        selected_only: form["_selected_only"] == "true",
        selected_page: positive_integer(form["_selected_page"] || socket.assigns.selected_page)
      )
      |> load_candidates()
      |> load_selected()
    else
      _ ->
        assign(socket,
          error: "Use a bounded selection and text filters. Your draft is unchanged."
        )
    end
  end

  defp selection_filters(form, current) do
    captured =
      case form["_filters"] do
        value when is_binary(value) and byte_size(value) <= 4_096 ->
          case Jason.decode(value) do
            {:ok, values} when is_map(values) -> values
            _ -> %{}
          end

        _ ->
          %{}
      end

    values = form["filters"] || %{}

    if is_map(values) &&
         Enum.all?(Map.take(values, @selection_filter_fields), fn {_, value} ->
           is_binary(value) && byte_size(value) <= 200
         end) do
      filters =
        Map.merge(
          Map.take(captured, @selection_filter_fields ++ ["page"]),
          Map.take(values, @selection_filter_fields)
        )

      if Enum.all?(Map.take(filters, @selection_filter_fields), fn {_, value} ->
           is_binary(value) && byte_size(value) <= 200
         end) do
        filters =
          Map.put(filters, "kind", if(filters["kind"] == "target", do: "target", else: "check"))

        previous = if captured == %{}, do: current, else: captured

        comparable = fn values ->
          Map.new(
            @selection_filter_fields,
            &{&1, values[&1] || if(&1 == "kind", do: "check", else: "")}
          )
        end

        page =
          if comparable.(filters) == comparable.(previous),
            do: positive_integer(captured["page"] || current["page"] || 1),
            else: 1

        {:ok, Map.put(filters, "page", page)}
      else
        :error
      end
    else
      :error
    end
  end

  defp encoded_draft(proposal, origin),
    do: proposal |> Map.put("_origin", origin) |> Jason.encode!()

  defp decode_draft(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_draft_bytes do
    with {:ok, captured} when is_map(captured) <- Jason.decode(encoded),
         true <-
           Enum.all?(Map.drop(captured, ["selections", "recurrence"]), fn {key, value} ->
             key in (@proposal_fields ++ ["_origin"]) &&
               (is_nil(value) || is_integer(value) ||
                  (is_binary(value) && byte_size(value) <= 2_000))
           end),
         true <- valid_recurrence_draft?(captured["recurrence"]),
         true <- MaintenanceSelection.valid?(captured["selections"] || []),
         true <- captured["scope"] == "selection" || (captured["selections"] || []) == [] do
      {:ok,
       Map.put(
         captured,
         "selections",
         MaintenanceSelection.normalize(captured["selections"] || [])
       )}
    else
      _ -> :error
    end
  end

  defp decode_draft(_), do: :error

  defp recovery_notice(%{window: nil}),
    do: "Draft restored. Preview again before saving; your reviewed revision is preserved."

  defp recovery_notice(%{window: window, proposal: proposal}) do
    current = window["proposal"] || window

    comparable = fn value ->
      Map.new(@proposal_fields, &{&1, value[&1]})
      |> Map.put("selections", MaintenanceSelection.normalize(selections(value)))
    end

    cond do
      comparable.(proposal) == comparable.(current) ->
        nil

      stale?(window, proposal) ->
        "Your draft was restored. Review the changed saved window before saving your edits."

      window["status"] == "active" ->
        "Your unsaved edits were restored. Saved maintenance remains in effect; review your edits before saving."

      window["status"] == "upcoming" ->
        "Your unsaved edits were restored. Saved maintenance is still scheduled; review your edits before saving."

      true ->
        "Your draft was restored. This maintenance window has ended and cannot be edited."
    end
  end

  defp decode_selectors(encoded, count, bytes) when is_binary(encoded) do
    with true <- byte_size(encoded) <= bytes,
         {:ok, values} when is_list(values) <- Jason.decode(encoded),
         true <- length(values) <= count && MaintenanceSelection.valid?(values) do
      {:ok, MaintenanceSelection.normalize(values)}
    else
      _ -> :error
    end
  end

  defp decode_selectors(_, _, _), do: :error

  defp refresh_current(socket) do
    cond do
      socket.assigns.live_action == :index ->
        refresh_list(socket)

      socket.assigns.series ->
        case MaintenanceSchedules.get(socket.assigns.series["id"], socket.assigns.series_params) do
          {:ok, series} ->
            socket |> assign(series: series) |> load_series_selection() |> refresh_series_cancel()

          _ ->
            socket
        end

      socket.assigns.window ->
        case Maintenance.get(socket.assigns.window["id"]) do
          {:ok, window} ->
            socket |> assign(window: window) |> load_selected() |> refresh_preview()

          _ ->
            socket
        end

      true ->
        socket |> load_selected() |> refresh_preview()
    end
  end

  defp refresh_preview(%{assigns: %{preview: nil}} = socket), do: socket

  defp refresh_preview(socket) do
    if stale?(socket.assigns.window, socket.assigns.proposal) do
      socket
    else
      case preview_proposal(
             socket.assigns.proposal,
             socket.assigns.preview["page"] || 1,
             socket.assigns.preview["occurrence_page"] || 1,
             socket.assigns.review_token
           ) do
        {:ok, preview} ->
          if preview["fingerprint"] == socket.assigns.preview["fingerprint"],
            do: socket,
            else: socket |> invalidate_review() |> assign(error: error_message(:review_changed))

        _ ->
          socket |> invalidate_review() |> assign(error: error_message(:review_changed))
      end
    end
  end

  defp load_window(socket, window) do
    proposal = Map.take(window["proposal"] || window, @proposal_fields)

    options =
      window["scope_options"] ||
        [Map.put(Map.take(proposal, @scope_fields), "label", scope_label(proposal))]

    socket
    |> assign(window: window, proposal: proposal, scope_options: options)
    |> load_selected()
  end

  defp keep_draft(%{assigns: %{proposal: nil}} = socket, _), do: socket

  defp keep_draft(socket, form) do
    values =
      case form["window"] do
        nil -> %{}
        fields when is_map(fields) -> Map.take(fields, @editable_fields)
        _ -> nil
      end

    if is_map(values) && valid_recurrence_form?(form) &&
         Enum.all?(values, fn {_, value} -> is_binary(value) and byte_size(value) <= 2_000 end) do
      old = socket.assigns.proposal
      # Native datetime-local values expose whole seconds. Preserve a saved
      # instant's finer precision when the operator did not change that field.
      values =
        Enum.reduce(~w(starts_local ends_local), values, fn field, values ->
          if Map.has_key?(values, field) && form_time(values[field]) == form_time(old[field]),
            do: Map.put(values, field, old[field]),
            else: values
        end)

      values =
        if socket.assigns.window && socket.assigns.window["status"] == "active",
          do: Map.drop(values, ~w(timezone start_mode starts_local start_fold)),
          else: values

      proposal = old |> Map.merge(values) |> merge_recurrence(form, socket.assigns.window)

      proposal =
        case Enum.find(
               socket.assigns.scope_options,
               &(proposal["scope"] != "selection" && is_nil(socket.assigns.window) &&
                   scope_key(&1) == form["scope_choice"])
             ) do
          nil -> proposal
          option -> Map.merge(proposal, Map.take(option, @scope_fields))
        end

      proposal =
        Enum.reduce(
          [{"starts_local", "start_fold"}, {"ends_local", "end_fold"}],
          proposal,
          fn {field, fold}, draft ->
            if old[field] != draft[field] || old["timezone"] != draft["timezone"],
              do: Map.put(draft, fold, "reject"),
              else: draft
          end
        )

      assign(socket, proposal: proposal, error: nil)
    else
      assign(socket, error: "Use text values of a reasonable length for the maintenance window.")
    end
  end

  defp keep_cancel_draft(socket, form) do
    if socket.assigns.window && form["_id"] == socket.assigns.window["id"] &&
         is_binary(form["reason"]) && byte_size(form["reason"]) <= 2_000 do
      assign(socket,
        cancel_open: form["_open"] == "true",
        cancel_reason: form["reason"],
        cancel_revision: integer(form["revision"]),
        error: nil
      )
    else
      assign(socket,
        error: "Review this window and enter a reason before ending or cancelling it."
      )
    end
  end

  defp recovery_matches?(captured, assigns) do
    current = assigns.proposal || %{}

    captured["id"] == current["id"] &&
      (is_nil(captured["_origin"]) || captured["_origin"] == assigns.draft_origin) &&
      cond do
        captured["scope"] == "selection" && is_nil(assigns.window) ->
          captured["_origin"] == assigns.draft_origin

        captured["scope"] == "selection" ->
          MaintenanceSelection.normalize(selections(captured)) ==
            MaintenanceSelection.normalize(selections(current))

        true ->
          Enum.any?(assigns.scope_options, &same_scope?(&1, captured))
      end
  end

  defp invalidate_review(socket),
    do: assign(socket, preview: nil, review_token: nil, error: nil, notice: nil)

  defp same_scope?(left, right),
    do:
      Map.take(left, @scope_fields) == Map.take(right, @scope_fields) &&
        MaintenanceSelection.normalize(selections(left)) ==
          MaintenanceSelection.normalize(selections(right))

  defp scope_key(scope) do
    @scope_fields
    |> Enum.map(&Map.get(scope, &1))
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp stale?(nil, _), do: false
  defp stale?(_, nil), do: false

  defp stale?(window, proposal) do
    fixed = @scope_fields ++ ~w(timezone start_mode starts_local start_fold)

    window["revision"] != integer(proposal["revision"]) ||
      (window["status"] == "active" &&
         Map.take(proposal, fixed) != Map.take(window["proposal"] || window, fixed))
  end

  defp editable?(nil), do: true
  defp editable?(window), do: window["status"] in ["active", "upcoming"]
  defp cancel_label(%{"status" => "active"}), do: "End maintenance now"
  defp cancel_label(_), do: "Cancel window"
  defp page_heading(:index, _), do: "Maintenance"
  defp page_heading(:new, _), do: "Schedule maintenance"
  defp page_heading(:series, nil), do: "Maintenance series"
  defp page_heading(_, window), do: (window || %{})["name"] || "Maintenance window"

  defp status_label(%{"status" => "cancelled"} = window), do: cancellation_label(window)

  defp status_label(%{"status" => status}), do: status_label(status)
  defp status_label("upcoming"), do: "Upcoming"
  defp status_label("active"), do: "Active"
  defp status_label("ended"), do: "Ended"
  defp status_label("cancelled"), do: "Cancelled"
  defp status_label("between"), do: "Scheduled"
  defp status_label("completed"), do: "Completed"
  defp status_label(_), do: "Unknown"

  defp cancellation_label(window) do
    case {parse_time(window["cancelled_at"]), parse_time(window["starts_at"])} do
      {%DateTime{} = ended, %DateTime{} = started} ->
        if DateTime.compare(ended, started) == :lt, do: "Cancelled", else: "Ended early"

      _ ->
        "Cancelled"
    end
  end

  defp event_label(%{"kind" => "cancelled", "snapshot" => snapshot}) when is_map(snapshot) do
    if cancellation_label(snapshot) == "Ended early",
      do: "Maintenance ended early",
      else: "Window cancelled before start"
  end

  defp event_label(%{"kind" => kind}), do: event_label(kind)
  defp event_label("created"), do: "Window created"
  defp event_label("updated"), do: "Window updated"
  defp event_label("cancelled"), do: "Window cancelled"
  defp event_label("expired"), do: "Window expired"
  defp event_label(_), do: "Window updated"

  defp scope_label(%{"scope" => "target"} = proposal),
    do:
      "Target #{proposal["target_kind"]}: #{proposal["target_key"]} · #{proposal["environment"] || "No declared environment"} · source #{proposal["source_id"] || "built-in checks"}"

  defp scope_label(%{"scope" => "selection"} = proposal) do
    count = proposal["selection_count"] || length(selections(proposal))

    prefix =
      if repeating?(proposal) || proposal["kind"] == "series",
        do: "Each window covers",
        else: "One window covering"

    "#{prefix} #{count} #{if count == 1, do: "selected check or target", else: "selected checks or targets"}"
  end

  defp scope_label(proposal),
    do:
      "#{proposal["check_label"] || "Selected scheduled check"} · all its results#{if proposal["runner_label"], do: " · " <> proposal["runner_label"], else: ""}"

  defp scope_label(proposal, options) do
    case {proposal["scope"], Enum.find(options, &same_scope?(&1, proposal))} do
      {"check", %{"label" => label}} -> label
      _ -> scope_label(proposal)
    end
  end

  defp target_label(target), do: target["label"] || "#{target["kind"]}: #{target["key"]}"
  defp count_label(count, label), do: "#{count} #{label}#{if count == 1, do: "", else: "s"}"
  defp repeating?(proposal), do: is_map(proposal) && is_map(proposal["recurrence"])
  defp valid_recurrence_draft?(nil), do: true

  defp valid_recurrence_draft?(rule) when is_map(rule),
    do:
      map_size(rule) <= 5 &&
        Enum.all?(rule, fn {k, v} ->
          k in ~w(frequency interval end_mode count until_date) &&
            (is_nil(v) || is_integer(v) || (is_binary(v) && byte_size(v) <= 100))
        end)

  defp valid_recurrence_draft?(_), do: false

  defp valid_recurrence_form?(form),
    do: form["repeat"] in [nil, "none", "weekly"] && valid_recurrence_draft?(form["recurrence"])

  defp merge_recurrence(proposal, _form, window) when not is_nil(window),
    do: Map.delete(proposal, "recurrence")

  defp merge_recurrence(proposal, %{"repeat" => "none"}, _),
    do: Map.delete(proposal, "recurrence")

  defp merge_recurrence(proposal, form, _) do
    if form["repeat"] == "weekly" || repeating?(proposal) do
      rule =
        Map.merge(
          proposal["recurrence"] ||
            %{
              "frequency" => "weekly",
              "interval" => 1,
              "end_mode" => "count",
              "count" => 4,
              "until_date" => nil
            },
          form["recurrence"] || %{}
        )

      rule =
        rule
        |> Map.put("interval", integer(rule["interval"]))
        |> Map.put(
          "count",
          if(rule["end_mode"] == "count", do: integer(rule["count"] || 4), else: nil)
        )
        |> Map.put(
          "until_date",
          if(rule["end_mode"] == "date", do: rule["until_date"] || "", else: nil)
        )

      proposal |> Map.put("recurrence", rule) |> Map.put("start_mode", "scheduled")
    else
      proposal
    end
  end

  defp preview_proposal(proposal, result_page \\ 1, occurrence_page \\ 1, token \\ nil) do
    if repeating?(proposal) do
      case MaintenanceSchedules.preview(proposal, occurrence_page, result_page, nil, token) do
        {:ok, preview} ->
          {:ok,
           Map.merge(preview, %{
             "page" => preview["result_page"],
             "pages" => preview["result_pages"],
             "page_size" => 25,
             "total" => preview["result_total"]
           })}

        error ->
          error
      end
    else
      Maintenance.preview(proposal, result_page, nil, token)
    end
  end

  defp apply_proposal(token, proposal) do
    if repeating?(proposal),
      do: MaintenanceSchedules.apply(token, proposal),
      else: Maintenance.apply(token, proposal)
  end

  defp repeat_label(rule) do
    interval = rule["interval"] || 1
    cadence = if interval == 1, do: "Every week", else: "Every #{interval} weeks"

    if rule["end_mode"] == "date",
      do: cadence <> " through " <> (rule["until_date"] || "—"),
      else: cadence <> " for " <> count_label(rule["count"] || 0, "window")
  end

  defp series_event_label("created"), do: "Series created"
  defp series_event_label("upcoming_cancelled"), do: "Upcoming windows cancelled"
  defp series_event_label("updated"), do: "Individual window changed"
  defp series_event_label("cancelled"), do: "Individual window cancelled"
  defp series_event_label("occurrence_updated"), do: "Individual window changed"
  defp series_event_label("occurrence_cancelled"), do: "Individual window cancelled"
  defp series_event_label(_), do: "Series updated"

  defp series_remaining?(series), do: (series["remaining_count"] || 0) > 0

  defp series_membership_copy("check"),
    do:
      "Future results from this same scheduled check instance join during each window. Replacement check instances are independent."

  defp series_membership_copy("target"),
    do:
      "Future results matching this exact source, monitored environment and target join during each window, across observers."

  defp series_membership_copy(_),
    do:
      "Each selected check stays with its scheduled instance and includes its future results. Each selected target follows exact matches across observers."

  defp series_error_message(reason) when reason in [:stale, :review_changed],
    do:
      "This series or its windows changed after review. Your reason is preserved. Review the current series and preview the cancellation again."

  defp series_error_message(reason), do: error_message(reason)

  defp duration_label(row) do
    with %DateTime{} = first <- parse_time(row["starts_at"]),
         %DateTime{} = last <- parse_time(row["ends_at"]),
         elapsed when elapsed > 0 and elapsed < 1_000_000 <-
           DateTime.diff(last, first, :microsecond) do
      "Less than 1 second"
    else
      _ -> duration(row["starts_at"], row["ends_at"])
    end
  end

  defp entry_path(%{"kind" => "series", "id" => id}), do: series_path(id)
  defp entry_path(entry), do: window_path(entry["id"])
  defp series_path(id), do: "/maintenance/series/" <> id

  defp series_page_path(series, params, key, page),
    do: series_path(series["id"]) <> "?" <> URI.encode_query(Map.put(params, key, page))

  defp load_series_selection(socket) do
    rows = MaintenanceSelection.describe(selections(socket.assigns.series["proposal"]))

    assign(socket,
      selected_rows: rows,
      saved_selection_page: min(socket.assigns.saved_selection_page, selected_pages(rows))
    )
  end

  defp series_cancel_draft(socket, form) do
    if socket.assigns.series && form["_id"] == socket.assigns.series["id"] &&
         is_binary(form["reason"]) && byte_size(form["reason"]) <= 2_000 do
      assign(socket,
        cancel_open: true,
        cancel_reason: form["reason"],
        cancel_revision: integer(form["revision"]),
        series_cancel_preview: nil,
        error: nil
      )
    else
      assign(socket,
        error: "Review this series and enter a reason before cancelling upcoming windows."
      )
    end
  end

  defp refresh_series_cancel(%{assigns: %{series_cancel_preview: nil}} = socket), do: socket

  defp refresh_series_cancel(socket) do
    old = socket.assigns.series_cancel_preview

    case MaintenanceSchedules.cancel_preview(
           socket.assigns.series["id"],
           socket.assigns.cancel_revision,
           socket.assigns.cancel_reason,
           old["page"] || 1,
           nil,
           old["review_token"]
         ) do
      {:ok, _} ->
        socket

      _ ->
        assign(socket,
          series_cancel_preview: nil,
          error:
            "The series or upcoming windows changed after review. Your reason is preserved; review the cancellation again."
        )
    end
  end

  defp new_path(id), do: "/maintenance/new?" <> URI.encode_query(%{"check_id" => id})
  defp window_path(id), do: "/maintenance/" <> id

  defp list_path(filters, changes),
    do: "/maintenance?" <> URI.encode_query(Map.merge(filters, changes))

  defp pages(result), do: max(1, ceil((result["total"] || 0) / max(1, result["page_size"] || 25)))
  defp positive_integer(value), do: max(1, integer(value))
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> -1
    end
  end

  defp integer(_), do: -1

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end

  defp parse_time(%DateTime{} = value), do: value
  defp parse_time(_), do: nil
  defp form_time(value) when is_binary(value) and byte_size(value) == 16, do: value <> ":00"
  defp form_time(value) when is_binary(value), do: String.slice(value, 0, 19)
  defp form_time(_), do: ""

  defp utc_time(value) do
    case parse_time(value) do
      nil -> "—"
      time -> Calendar.strftime(time, "%d %b %Y, %H:%M:%S UTC")
    end
  end

  defp local_time(value, zone) do
    with time when not is_nil(time) <- parse_time(value),
         {:ok, local} <-
           DateTime.shift_zone(
             time,
             if(zone in [nil, "UTC"], do: "Etc/UTC", else: zone),
             Tz.TimeZoneDatabase
           ) do
      Calendar.strftime(local, "%a %d %b %Y, %H:%M:%S %Z (%z)")
    else
      _ -> "—"
    end
  end

  defp duration(first, last) do
    with %DateTime{} = first <- parse_time(first), %DateTime{} = last <- parse_time(last) do
      seconds = DateTime.diff(last, first)

      [
        {div(seconds, 86_400), "day"},
        {div(rem(seconds, 86_400), 3_600), "hour"},
        {div(rem(seconds, 3_600), 60), "minute"},
        {rem(seconds, 60), "second"}
      ]
      |> Enum.reject(fn {count, _} -> count == 0 end)
      |> Enum.map_join(", ", fn {count, unit} ->
        "#{count} #{unit}#{if count == 1, do: "", else: "s"}"
      end)
    else
      _ -> "—"
    end
  end

  defp error_message({:invalid, message}), do: error_message(message)

  defp error_message(:not_found),
    do:
      "This check or maintenance window is not available. Choose an active check or return to maintenance history."

  defp error_message(:stale),
    do:
      "This window changed after you reviewed it. Your draft is preserved. Review the current saved window before continuing."

  defp error_message(:review_changed),
    do:
      "The scope or overlapping windows changed after your preview. Your draft is preserved. Preview again before saving."

  defp error_message(:review_expired),
    do:
      "This preview expired after 15 minutes. Your draft is preserved. Preview it again before saving."

  defp error_message(:invalid_review),
    do:
      "This preview is no longer valid. Your draft is preserved. Preview it again before saving."

  defp error_message(:retired),
    do:
      "This check has been retired. Choose an active check to schedule new maintenance. Existing windows remain in history."

  defp error_message(value) when is_binary(value), do: value

  defp error_message(_),
    do:
      "The maintenance window could not be saved. Review its scope and times, then preview again."
end

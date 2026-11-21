# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceLive do
  use MondekWeb, :live_view

  alias Mondek.{Maintenance, MaintenanceSchedules, MaintenanceSelection}
  import MondekWeb.MaintenancePresentation

  alias MondekWeb.{
    InvestigationStack,
    InvestigationTrail,
    PreviewDetail,
    PreviewMaintenanceChooser,
    PreviewMaintenanceEditor,
    PreviewMaintenanceDetails
  }

  @proposal_fields ~w(id revision name reason scope assignment_id source_id environment target_kind target_key selections timezone start_mode starts_local ends_local start_fold end_fold recurrence)
  @editable_fields ~w(name reason timezone start_mode starts_local ends_local start_fold end_fold)
  @recurrence_fields ~w(frequency interval end_mode count until_date)
  @recurrence_unused_fields Enum.map(@recurrence_fields, &("_unused_" <> &1))
  @scope_fields ~w(scope assignment_id source_id environment target_kind target_key)
  @selection_filter_fields ~w(kind search environment source_id runner_id)
  @choice_fields [
    {"kind", "Choose by", "grid"},
    {"environment", "Environment", "globe"},
    {"source_id", "Source", "code"},
    {"runner_id", "Runner", "server"}
  ]
  @max_draft_bytes 2_097_152
  @preview_filters [
    {"status", "Status", "clock", [{"current", "Active & upcoming"}, {"history", "History"}]},
    {"scope", "Scope", "map-pin",
     [
       {"check", "Scheduled check"},
       {"target", "Target"},
       {"selection", "Selected checks and targets"}
     ]},
    {"kind", "Type", "grid", [{"window", "One-off window"}, {"series", "Recurring series"}]}
  ]

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mondek.PubSub, "monitoring")
      Process.send_after(self(), :tick, 2_000)
    end

    {:ok,
     assign(socket,
       investigation_params: %{},
       investigation_host: "/maintenance",
       investigation_context: "maintenance",
       investigation_owner: nil,
       investigation_active: false,
       investigation_promoted: false,
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
  def handle_params(params, uri, socket) do
    uri = URI.parse(uri)

    owner =
      {socket.assigns.live_action, owner_identity(params["id"]),
       owner_identity(params["check_id"]), owner_identity(params["stream_id"]),
       owner_identity(params["copy_series"]),
       not is_nil(MondekWeb.BrowserNavigation.return_path(params["return_to"]))}

    same_owner = owner == socket.assigns.investigation_owner
    trail = InvestigationTrail.resolve(params)
    host = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    socket =
      assign(socket,
        investigation_params: params,
        investigation_host: host,
        investigation_context:
          "maintenance:" <> Base.url_encode64(:erlang.term_to_binary(owner), padding: false),
        investigation_owner: owner,
        investigation_active: trail != [],
        investigation_promoted: not is_nil(InvestigationTrail.promoted(params)),
        same_maintenance_owner: same_owner
      )

    socket =
      assign(socket,
        preview_drawer:
          socket.assigns.live_action in [:edit, :series] &&
            !String.ends_with?(uri.path, "/full") && trail == [],
        return_to: MondekWeb.BrowserNavigation.return_path(params["return_to"]),
        window_picker: nil
      )

    if socket.assigns.live_action == :series do
      socket = socket |> assign(filters: window_filters(params)) |> refresh_list()

      filters = Map.take(params, ~w(occurrence_page result_page history_page))

      case MaintenanceSchedules.get(params["id"], filters) do
        {:ok, series} ->
          same = socket.assigns.series && socket.assigns.series["id"] == params["id"]

          {:noreply,
           socket
           |> assign(
             series: series,
             series_params: Map.take(series, ~w(occurrence_page result_page history_page)),
             window: nil,
             proposal: nil,
             cancel_reason: if(same, do: socket.assigns.cancel_reason, else: ""),
             cancel_open: same && socket.assigns.cancel_open,
             cancel_revision: if(same, do: socket.assigns.cancel_revision),
             series_cancel_preview: if(same, do: socket.assigns.series_cancel_preview),
             error: if(same, do: socket.assigns.error),
             notice: if(same, do: socket.assigns.notice)
           )
           |> load_series_selection()
           |> refresh_series_cancel()}

        {:error, reason} ->
          {:noreply,
           assign(socket, series: nil, window: nil, proposal: nil, error: error_message(reason))}
      end
    else
      regular_params(params, socket)
    end
  end

  defp draft_origin(%{"check_id" => check, "stream_id" => stream})
       when is_binary(check) and is_binary(stream), do: check <> ":" <> stream

  defp draft_origin(params), do: params["copy_series"] || params["check_id"] || "selection"

  defp owner_identity(value) when is_binary(value) and byte_size(value) <= 128, do: value
  defp owner_identity(_), do: ""

  defp regular_params(
         _params,
         %{assigns: %{live_action: :new, same_maintenance_owner: true, proposal: proposal}} =
           socket
       )
       when is_map(proposal),
       do: {:noreply, refresh_current(socket)}

  defp regular_params(
         %{"id" => id} = params,
         %{assigns: %{live_action: :edit, window: %{"id" => id}}} = socket
       ) do
    {:noreply, socket |> assign(filters: window_filters(params)) |> refresh_current()}
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
        cancel_revision: nil,
        saved_selection_page: 1,
        settings_recovered: false,
        selection_recovered: false
      )

    case socket.assigns.live_action do
      :index ->
        filters = window_filters(params)

        {:noreply,
         socket |> assign(filters: filters, window: nil, proposal: nil) |> refresh_list()}

      :new ->
        socket =
          assign(socket,
            filters: window_filters(params),
            draft_origin: draft_origin(params),
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
                   proposal: initial_proposal(seed, socket.assigns.return_to),
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
        socket = assign(socket, filters: window_filters(params))
        socket = if socket.assigns.preview_drawer, do: refresh_list(socket), else: socket

        case Maintenance.get(params["id"]) do
          {:ok, window} ->
            {:noreply, socket |> assign(draft_origin: params["id"]) |> load_window(window)}

          {:error, reason} ->
            {:noreply, assign(socket, window: nil, proposal: nil, error: error_message(reason))}
        end
    end
  end

  defp window_scope_filters(params) do
    for key <- ~w(status assignment_id stream_id page),
        value = params[key],
        is_binary(value) && String.valid?(value) && byte_size(value) <= 128,
        key not in ~w(assignment_id stream_id) || match?({:ok, _}, Ecto.UUID.cast(value)),
        into: %{},
        do: {key, value}
  end

  defp window_filters(params) do
    filters =
      Map.merge(
        window_scope_filters(params),
        Mondek.OverviewFilters.params(Map.take(params, ["search"]))
      )

    Enum.reduce(@preview_filters, filters, fn {field, _, _, choices}, acc ->
      value = params[field]

      if List.keymember?(choices, value, 0) || {field, value} == {"status", "all"},
        do: Map.put(acc, field, value),
        else: Map.delete(acc, field)
    end)
  end

  defp initial_proposal(seed, nil), do: Map.take(seed["proposal"], @proposal_fields)

  defp initial_proposal(seed, _return_to) do
    check = Enum.find(seed["scope_options"], &(&1["scope"] == "check"))
    seed["proposal"] |> Map.take(@proposal_fields) |> Map.merge(Map.take(check, @scope_fields))
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
  def handle_event(event, _params, %{assigns: %{investigation_active: true}} = socket)
      when event not in ["recover", "recover_selection", "edit_cancel", "series_cancel_edit"],
      do: {:noreply, socket}

  def handle_event("search", params, %{assigns: %{live_action: :new}} = socket) do
    filter_choices_for_draft(socket, %{
      "search" => Mondek.OverviewFilters.params(params)["search"]
    })
  end

  def handle_event(
        "filter_remove",
        %{"field" => field},
        %{assigns: %{live_action: :new}} = socket
      )
      when field in @selection_filter_fields do
    filter_choices_for_draft(socket, %{field => default_choice_filter(field)})
  end

  def handle_event(
        "filter_open",
        %{"field" => field},
        %{assigns: %{live_action: :new}} = socket
      ) do
    case List.keyfind(@choice_fields, field, 0) do
      {^field, _, _} ->
        picker = choice_picker(socket.assigns, field, "")
        selected = Enum.find(picker.options, &(&1.key == socket.assigns.selection_filters[field]))

        {:noreply,
         assign(socket,
           window_picker: %{picker | value: if(selected, do: selected.label, else: "")}
         )}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "search",
        params,
        socket
      ) do
    search = Mondek.OverviewFilters.params(params)["search"]

    if search == socket.assigns.filters["search"],
      do: {:noreply, socket},
      else: patch_preview_list(socket, %{"search" => search})
  end

  def handle_event("filter_open", %{"field" => field}, socket) do
    case List.keyfind(@preview_filters, field, 0) do
      {^field, _, _, choices} ->
        label =
          List.keyfind(choices, window_filter_value(socket.assigns.filters, field), 0, {nil, ""})
          |> elem(1)

        {:noreply, assign(socket, window_picker: %{window_picker(field, "") | value: label})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "filter_query",
        %{"search" => search},
        %{assigns: %{window_picker: %{field: field}}} = socket
      )
      when is_binary(search),
      do:
        {:noreply,
         assign(socket,
           window_picker: filter_picker(socket.assigns, field, String.slice(search, 0, 100))
         )}

  def handle_event(
        "filter_first",
        %{"search" => search},
        %{assigns: %{window_picker: %{field: field}}} = socket
      )
      when is_binary(search) do
    case filter_picker(socket.assigns, field, String.slice(search, 0, 100)).options do
      [%{key: key} | _] -> apply_picker_filter(socket, %{field => key})
      [] -> {:noreply, socket}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{window_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: apply_picker_filter(socket, %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{window_picker: %{field: field}}} = socket
      ),
      do:
        apply_picker_filter(socket, %{
          field =>
            if(socket.assigns.live_action == :new,
              do: default_choice_filter(field),
              else: cleared_window_filter(field)
            )
        })

  def handle_event(
        "filter_close",
        params,
        socket
      ) do
    socket = assign(socket, :window_picker, nil)

    socket =
      if params["reopen"],
        do: push_event(socket, "preview-filter-ready", picker_target(socket.assigns)),
        else: socket

    {:noreply, socket}
  end

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
           saved_destination(
             socket.assigns,
             window["id"],
             if(repeating?(socket.assigns.proposal), do: :series, else: :window)
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
           if(preview["stops_generation"],
             do: "Future scheduling cancelled. Active windows keep their saved end time.",
             else:
               "Upcoming windows cancelled. Active windows, other maintenance and acknowledgements are unchanged."
           ),
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
         |> push_navigate(to: saved_destination(socket.assigns, window["id"], :window))}

      {:error, reason} ->
        {:noreply, socket |> refresh_current() |> assign(error: error_message(reason))}
    end
  end

  defp picker_target(%{live_action: :new}), do: %{id: "maintenance-choice-search"}
  defp picker_target(_), do: %{}

  defp default_choice_filter("kind"), do: "check"
  defp default_choice_filter(_), do: nil

  defp apply_picker_filter(%{assigns: %{live_action: :new}} = socket, changes),
    do: filter_choices_for_draft(socket, changes)

  defp apply_picker_filter(socket, changes), do: patch_preview_list(socket, changes)

  defp filter_choices_for_draft(socket, changes) do
    filters =
      socket.assigns.selection_filters
      |> Map.merge(changes)
      |> Map.reject(fn {_, value} -> is_nil(value) end)
      |> Map.put("page", 1)

    {:noreply,
     socket
     |> assign(selection_filters: filters, window_picker: nil)
     |> load_candidates()
     |> push_event("preview-filter-ready", picker_target(socket.assigns))}
  end

  defp filter_picker(%{live_action: :new} = assigns, field, search),
    do: choice_picker(assigns, field, search)

  defp filter_picker(_, field, search), do: window_picker(field, search)

  defp choice_picker(_assigns, field, search) do
    {^field, title, _} = List.keyfind(@choice_fields, field, 0)

    options =
      for {key, label} <-
            choice_filter_options(MaintenanceSelection.filter_choices(search), field),
          String.contains?(String.downcase(label <> " " <> key), String.downcase(search)) do
        %{key: key, kind: "", label: label, show_key: false}
      end

    %{field: field, title: title, value: search, options: options}
  end

  defp choice_fields, do: @choice_fields

  defp choice_chips(filters, choices) do
    for {field, name, _} <- @choice_fields,
        key = filters[field],
        key do
      option = List.keyfind(choice_filter_options(choices, field), key, 0)

      {_, label} =
        option ||
          List.keyfind(
            choice_filter_options(MaintenanceSelection.filter_choices(key), field),
            key,
            0,
            {key, key}
          )

      %{field: field, name: name, label: label, removable: key != default_choice_filter(field)}
    end
  end

  defp choice_filter_options(_, "kind"),
    do: [
      {"check", "Scheduled checks"},
      {"stable_check", "Stable checks"},
      {"check_target", "Stable check targets"},
      {"target", "Monitored targets"}
    ]

  defp choice_filter_options(choices, field) do
    key =
      %{"environment" => "environments", "source_id" => "sources", "runner_id" => "runners"}[
        field
      ]

    for choice <- choices[key] || [], do: {choice["id"], choice["label"] || choice["id"]}
  end

  defp patch_preview_list(socket, changes) do
    {:noreply,
     socket
     |> push_patch(to: preview_list_path(socket.assigns.filters, Map.put(changes, "page", nil)))
     |> push_event("preview-filter-ready", %{})}
  end

  defp window_filter_value(filters, "status"), do: filters["status"] || "current"
  defp window_filter_value(filters, field), do: filters[field]
  defp cleared_window_filter("status"), do: "all"
  defp cleared_window_filter(_), do: nil

  defp window_picker(field, search) do
    {^field, title, _, choices} = List.keyfind(@preview_filters, field, 0)

    options =
      for {key, label} <- choices,
          String.contains?(String.downcase(label), String.downcase(search)) do
        %{key: key, kind: "", label: label, show_key: false}
      end

    %{field: field, title: title, value: search, options: options}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="maintenance-preview-shell"
      class="preview-shell"
      phx-hook="MaintenancePanel"
      data-maintenance-entity={(@window || @series || %{})["id"]}
      data-maintenance-surface={if @preview_drawer, do: "drawer", else: "page"}
      data-selection={
        if @investigation_active,
          do: InvestigationTrail.selection(@investigation_params),
          else: if(@preview_drawer, do: (@window || @series || %{})["id"] || "unavailable")
      }
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "maintenance-heading")}
      data-panel-background={
        if @investigation_active,
          do:
            ".preview-masthead,.preview-sidebar,.preview-skip,#maintenance-owner-body,#main-content > .preview-list"
      }
    >
      <MondekWeb.PreviewLayouts.navigation active={:maintenance} />
      <main id="main-content" class="preview-main preview-maintenance" tabindex="-1">
        <.preview_windows :if={@live_action == :index || @preview_drawer} {assigns} />
        <PreviewDetail.surface
          :if={@preview_drawer}
          path={if @window || @series, do: presentation_path(assigns, :drawer)}
        >
          <div class="preview-panel-tools">
            <.link
              patch={preview_list_path(@filters, %{})}
              data-overview-close
              class="pf-v6-c-button pf-m-link"
            >Close details ×</.link>
            <.link
              :if={@window || @series}
              patch={presentation_path(assigns, :page)}
              class="pf-v6-c-button pf-m-link"
            >Open as page</.link>
            <.link :if={@return_to} navigate={@return_to} class="pf-v6-c-button pf-m-link">Back to incident</.link>
          </div>
          <header class="preview-incident-intro">
            <PreviewDetail.heading level={2} id="overview-panel-title" size="xl">
              {(@window || @series || %{})["name"] || "Window unavailable"}
            </PreviewDetail.heading>
          </header>
          <div class="preview-maintenance-workflow">
            <.maintenance_content {assigns} show_heading={false} />
          </div>
        </PreviewDetail.surface>
        <div
          :if={@live_action != :index && !@preview_drawer}
          id="maintenance-owner-body"
          class="preview-maintenance-workflow"
          hidden={@investigation_promoted}
          inert={@investigation_active}
          aria-hidden={if @investigation_active, do: "true"}
        >
          <div class="preview-maintenance-back">
            <.link patch={preview_list_path(@filters, %{})}>← All maintenance windows</.link>
            <.link :if={@window || @series} patch={presentation_path(assigns, :drawer)}>Open fly-over</.link>
            <.link :if={@return_to} navigate={@return_to}>Back to incident</.link>
          </div>
          <.maintenance_content {assigns} />
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          context={@investigation_context}
          back={
            InvestigationTrail.path(@investigation_host, [], %{"surface" => nil, "page_entity" => nil})
          }
        />
      </main>
    </div>
    """
  end

  defp maintenance_content(assigns) do
    assigns = assign_new(assigns, :show_heading, fn -> true end)

    assigns =
      assign(assigns,
        show_entity_heading: assigns.show_heading && not is_nil(assigns.window || assigns.series),
        show_workflow_heading: assigns.show_heading && is_nil(assigns.window || assigns.series),
        section_level: if(assigns.preview_drawer, do: 3, else: 2)
      )

    ~H"""
    <header :if={@show_entity_heading} class="preview-incident-intro">
      <PreviewDetail.heading level={1} size="xl" id="maintenance-heading">
        {(@window || @series)["name"]}
      </PreviewDetail.heading>
    </header>
    <div :if={@show_workflow_heading} class="page-heading">
      <div>
        <div class="eyebrow">Notification maintenance</div><h1 id="maintenance-heading" tabindex="-1">
          {page_heading(@live_action, @window || @series)}
        </h1>
        <p>
          Hold failure notifications during planned work. Checks, measured health and recovery notifications continue.
        </p>
      </div>
      <.link :if={@live_action == :index} navigate="/maintenance/new" class="button primary">Schedule maintenance</.link>
    </div>
    <p :if={@error} id="maintenance-error" class="form-error" role="alert">{@error}</p>
    <p :if={Phoenix.Flash.get(@flash, :info)} class="notice" role="status">
      {Phoenix.Flash.get(@flash, :info)}
    </p>
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
    <PreviewMaintenanceDetails.series_detail
      :if={@series}
      series={@series}
      params={@series_params}
      cancel_open={@cancel_open}
      cancel_reason={@cancel_reason}
      cancel_revision={@cancel_revision}
      preview={@series_cancel_preview}
      return_to={@return_to}
      list_filters={@filters}
      current_path={@investigation_host}
      section_level={@section_level}
      series_path={presentation_path(assigns, if(@preview_drawer, do: :drawer, else: :page))}
    />
    <PreviewMaintenanceChooser.selection_chooser
      :if={@live_action == :new && @proposal}
      candidates={@candidates}
      filter_choices={@filter_choices || %{}}
      fields={choice_fields()}
      chips={choice_chips(@selection_filters, @filter_choices || %{})}
      picker={@window_picker}
      filters={@selection_filters}
      proposal={@proposal}
      selected_rows={@selected_rows}
      selected_only={@selected_only}
      selected_page={@selected_page}
      draft_origin={@draft_origin}
      preview={@preview}
      return_to={@return_to}
    />
    <PreviewMaintenanceDetails.preview_window_details
      :if={@window}
      window={@window}
      context={navigation_context(assigns, :window)}
      current_path={@investigation_host}
      section_level={@section_level}
    />
    <PreviewMaintenanceDetails.saved_selection
      :if={
        (@series && @series["proposal"]["scope"] == "selection") ||
          (@window && @window["scope"] == "selection") ||
          (@preview && @proposal["scope"] == "selection")
      }
      rows={@selected_rows}
      page={@saved_selection_page}
      saved={not is_nil(@window) || not is_nil(@series)}
    />
    <PreviewMaintenanceEditor.editor
      :if={@proposal && editable?(@window)}
      proposal={@proposal}
      window={@window}
      scope_options={@scope_options}
      preview={@preview}
      token={@review_token}
      stale={stale?(@window, @proposal)}
      draft_origin={@draft_origin}
      return_to={@return_to}
      current_path={@investigation_host}
      section_level={@section_level}
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
          <.dynamic_tag tag_name={"h#{@section_level}"}>{cancel_label(@window)}</.dynamic_tag>
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
    """
  end

  defp preview_windows(assigns) do
    chips =
      for {field, name, _, choices} <- @preview_filters,
          value = window_filter_value(assigns.filters, field),
          {^value, label} <- List.wrap(List.keyfind(choices, value, 0)),
          do: %{field: field, name: name, label: label}

    fields = Enum.map(@preview_filters, fn {field, title, icon, _} -> {field, title, icon} end)
    assigns = assign(assigns, window_chips: chips, window_fields: fields)

    ~H"""
    <section class="preview-list" aria-labelledby="maintenance-heading">
      <header class="preview-heading">
        <h1 id="maintenance-heading" class="pf-v6-c-title pf-m-2xl">Maintenance</h1>
        <.link navigate="/maintenance/new" class="pf-v6-c-button pf-m-primary">Schedule maintenance</.link>
      </header>
      <div class="preview-maintenance-filter">
        <MondekWeb.PreviewFilters.filter_picker
          picker={@window_picker}
          chips={@window_chips}
          fields={@window_fields}
          search={@filters["search"]}
          remove={
            fn field ->
              preview_list_path(@filters, %{field => cleared_window_filter(field), "page" => nil})
            end
          }
          clear_search={preview_list_path(@filters, %{"search" => nil, "page" => nil})}
          form_label="Filter maintenance windows"
          label="Search maintenance windows"
          placeholder="Search or filter maintenance"
        />
        <.link
          :if={@filters["assignment_id"] || @filters["stream_id"]}
          patch={preview_list_path(Map.drop(@filters, ~w(assignment_id stream_id page)), %{})}
        >Show all scopes</.link>
      </div>
      <section class="preview-table-group" aria-labelledby="maintenance-windows-heading">
        <h2 id="maintenance-windows-heading" class="preview-section-heading">
          Windows and series <span class="pf-v6-c-badge pf-m-read">{@listing["total"] || 0}</span>
        </h2>
        <p :if={@listing["windows"] == []} class="preview-empty">No maintenance matches this view.</p>
        <table
          :if={@listing["windows"] != []}
          class="pf-v6-c-table preview-table preview-maintenance-table"
          aria-label="Maintenance windows and series"
        >
          <thead class="pf-v6-c-table__thead">
            <tr class="pf-v6-c-table__tr">
              <th class="pf-v6-c-table__th" scope="col">Window</th>
              <th class="pf-v6-c-table__th" scope="col">Status</th>
              <th class="pf-v6-c-table__th" scope="col">Scope</th>
              <th class="pf-v6-c-table__th" scope="col">Schedule</th>
            </tr>
          </thead>
          <tbody class="pf-v6-c-table__tbody">
            <tr
              :for={window <- @listing["windows"]}
              class={[
                "pf-v6-c-table__tr",
                (@window || @series || %{})["id"] == window["id"] && "preview-selected"
              ]}
              data-overview-row
            >
              <td class="pf-v6-c-table__td">
                <.link
                  patch={
                    if (@window || @series || %{})["id"] == window["id"],
                      do: preview_list_path(@filters, %{}),
                      else: preview_window_path(window, @filters)
                  }
                  id={"open-window-#{window["id"]}"}
                  data-overview-open
                  class="preview-result-link"
                >{window["name"]}</.link>
                <p class="preview-caption">{window["reason"]}</p>
              </td>
              <td class="pf-v6-c-table__td">
                <span class={[
                  "pf-v6-c-label",
                  window["status"] == "active" && "pf-m-green",
                  window["status"] in ["upcoming", "between"] && "pf-m-blue"
                ]}>
                  <span class="pf-v6-c-label__content">{status_label(window)}</span>
                </span>
              </td>
              <td class="pf-v6-c-table__td">{scope_label(window)}</td>
              <td class="pf-v6-c-table__td">
                <%= if window["kind"] == "series" do %>
                  <PreviewMaintenanceDetails.series_summary series={window} />
                <% else %>
                  <span class="preview-caption">Starts</span> {utc_time(window["starts_at"])}<br />
                  <span class="preview-caption">Ends</span> {utc_time(window["ends_at"])}
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
        <MondekWeb.PreviewPagination.pagination
          page={@listing["page"]}
          size={@listing["page_size"]}
          total={@listing["total"]}
          label="Maintenance pages"
          url={fn page -> preview_list_path(@filters, %{"page" => page}) end}
        />
      </section>
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

  defp add_selections(socket, rows),
    do:
      put_selections(
        socket,
        selections(socket.assigns.proposal) ++ Enum.map(rows, &selector_identity/1)
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
    restore_filters = is_list(page_rows)

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
        |> Enum.map(&selector_identity/1)

      socket = put_selections(socket, retained ++ added)

      if restore_filters do
        socket
        |> assign(
          selection_filters: filters,
          selected_only: form["_selected_only"] == "true",
          selected_page: positive_integer(form["_selected_page"] || socket.assigns.selected_page)
        )
        |> load_candidates()
        |> load_selected()
      else
        socket
      end
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
        kind = filters["kind"]

        filters =
          Map.put(
            filters,
            "kind",
            if(kind in ~w(stable_check check_target target), do: kind, else: "check")
          )

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
        socket = if socket.assigns.preview_drawer, do: refresh_list(socket), else: socket

        case MaintenanceSchedules.get(socket.assigns.series["id"], socket.assigns.series_params) do
          {:ok, series} ->
            socket |> assign(series: series) |> load_series_selection() |> refresh_series_cancel()

          _ ->
            socket
        end

      socket.assigns.window ->
        socket = if socket.assigns.preview_drawer, do: refresh_list(socket), else: socket

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
    form =
      case form do
        %{"recurrence" => fields} when is_map(fields) ->
          Map.put(form, "recurrence", Map.drop(fields, @recurrence_unused_fields))

        _ ->
          form
      end

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

  defp stale?(nil, _), do: false
  defp stale?(_, nil), do: false

  defp stale?(window, proposal) do
    fixed = @scope_fields ++ ~w(timezone start_mode starts_local start_fold)

    window["revision"] != integer(proposal["revision"]) ||
      (window["status"] == "active" &&
         Map.take(proposal, fixed) != Map.take(window["proposal"] || window, fixed))
  end

  defp page_heading(:index, _), do: "Maintenance"
  defp page_heading(:new, _), do: "Schedule maintenance"
  defp page_heading(:series, nil), do: "Maintenance series"
  defp page_heading(_, window), do: (window || %{})["name"] || "Maintenance window"

  defp valid_recurrence_draft?(nil), do: true

  defp valid_recurrence_draft?(rule) when is_map(rule),
    do:
      map_size(rule) <= 5 &&
        Enum.all?(rule, fn {k, v} ->
          k in @recurrence_fields &&
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

  defp series_error_message(reason) when reason in [:stale, :review_changed],
    do:
      "This series or its windows changed after review. Your reason is preserved. Review the current series and preview the cancellation again."

  defp series_error_message(reason), do: error_message(reason)

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

  defp saved_destination(assigns, id, kind) do
    surface = if assigns.preview_drawer, do: :drawer, else: :page
    preview_entity_path(kind, id, surface, navigation_context(assigns, kind))
  end

  defp presentation_path(assigns, surface) do
    {kind, id} =
      if assigns.series,
        do: {:series, assigns.series["id"]},
        else: {:window, assigns.window["id"]}

    preview_entity_path(kind, id, surface, navigation_context(assigns, kind))
  end

  defp navigation_context(assigns, kind) do
    params = Map.put(assigns.filters, "return_to", assigns.return_to)

    if kind == :series,
      do: Map.merge(params, Map.filter(assigns.series_params, fn {_, value} -> value > 1 end)),
      else: params
  end

  def preview_return_path(path, params) do
    case Regex.run(~r"\A/maintenance/(?:(series)/)?([a-f0-9-]{36})(/full)?\z", path,
           capture: :all_but_first
         ) do
      [kind, id | suffix] ->
        kind = if kind == "series", do: :series, else: :window
        surface = if suffix == ["/full"], do: :page, else: :drawer
        filters = window_filters(params)

        pages =
          if kind == :series do
            params
            |> Map.take(~w(occurrence_page result_page history_page))
            |> Map.filter(fn {_, value} -> Regex.match?(~r"\A[1-9][0-9]{0,6}\z", value) end)
          else
            %{}
          end

        return_to =
          case params["return_to"] do
            "/maintenance/" <> _ -> nil
            path -> MondekWeb.NextIncidentsLive.return_path(path)
          end

        preview_entity_path(
          kind,
          id,
          surface,
          Map.put(Map.merge(filters, pages), "return_to", return_to)
        )

      _ ->
        nil
    end
  end

  defp preview_window_path(window, filters) do
    kind = if window["kind"] == "series", do: :series, else: :window
    preview_entity_path(kind, window["id"], :drawer, filters)
  end

  defp preview_list_path(filters, changes) do
    query =
      filters
      |> Map.merge(changes)
      |> Map.reject(fn {key, value} -> is_nil(value) || {key, value} == {"status", "current"} end)
      |> URI.encode_query()

    "/maintenance" <> if(query == "", do: "", else: "?" <> query)
  end

  defp positive_integer(value), do: max(1, integer(value))
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> -1
    end
  end

  defp integer(_), do: -1

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

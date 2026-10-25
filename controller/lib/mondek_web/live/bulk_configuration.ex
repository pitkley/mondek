# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BulkConfiguration do
  @moduledoc "Bounded, reviewed configuration edits for source-declared compatible checks."
  use Phoenix.LiveComponent

  alias Mondek.{Monitoring, Parameters}
  alias MondekWeb.ParameterForm

  @maximum_selection 512
  @maximum_draft_bytes 16_384
  @maximum_recovery_bytes 180_000

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       rows: [],
       filters: %{},
       return_to: "/configuration",
       now: nil,
       phase: :selection,
       selection: %{},
       compatibility: nil,
       parameter_schema: nil,
       schema_fingerprint: nil,
       prepare_token: nil,
       review_token: nil,
       draft: %{},
       draft_error: nil,
       mixed_fields: [],
       resolved_fields: [],
       prepared: nil,
       preview: nil,
       receipts: [],
       progress: nil,
       page: 1,
       error: nil,
       stale_ids: [],
       notice: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    previous_now = socket.assigns.now
    socket = assign(socket, Map.take(assigns, [:id, :rows, :filters, :return_to, :now]))

    socket =
      if socket.assigns.phase == :saved && socket.assigns.now != previous_now,
        do: refresh_progress(socket),
        else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("edit", %{"_target" => ["selected", id]} = form, socket) do
    socket = keep_form_draft(socket, form)
    value = get_in(form, ["selected", id])

    if value in [nil, ""] do
      {:noreply, replace_selection(socket, Map.delete(socket.assigns.selection, id))}
    else
      with {:ok, revision} <- positive_integer(value),
           {:ok, check} <- rendered_check(socket, id, revision),
           :ok <- selectable(check, socket.assigns.compatibility),
           :ok <- within_limit(Map.put_new(socket.assigns.selection, id, revision)) do
        socket =
          socket
          |> establish_compatibility(check)
          |> replace_selection(Map.put_new(socket.assigns.selection, id, revision))

        {:noreply, socket}
      else
        {:error, reason} -> {:noreply, fail(socket, reason)}
      end
    end
  end

  def handle_event("edit", form, socket) do
    socket = keep_form_draft(socket, form)

    {:noreply,
     socket
     |> assign(review_token: nil, preview: nil, error: socket.assigns.draft_error)
     |> maybe_edit_phase()}
  end

  def handle_event("select_page", %{"selection" => encoded}, socket) do
    with {:ok, selected} <- decode_selection(encoded),
         {:ok, socket, selected} <- add_rendered_selection(socket, selected),
         :ok <- within_limit(selected) do
      {:noreply, replace_selection(socket, selected)}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("select_matching", _params, socket) do
    with {:ok, prepared} <- Monitoring.prepare_bulk_configuration(selection_records(socket)),
         filters =
           Map.merge(socket.assigns.filters, %{
             "source_id" => prepared["source_id"],
             "parameter_contract" => prepared["parameter_contract"],
             "schema_fingerprint" => prepared["schema_fingerprint"]
           }),
         {:ok, result} <- Monitoring.select_bulk_configuration(filters),
         {:ok, matching} <- checked_selection(result["selection"]),
         selected = Map.merge(matching, socket.assigns.selection),
         :ok <- within_limit(selected) do
      message =
        "Captured #{result["eligible_count"]} compatible checks from these filters. " <>
          "#{result["excluded_count"]} matching checks were excluded. New checks are not added automatically."

      {:noreply, socket |> replace_selection(selected) |> assign(notice: message)}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("clear", _params, socket) do
    {:ok, fresh} = mount(socket)
    {:noreply, assign(fresh, Map.take(socket.assigns, [:id, :rows, :filters, :return_to, :now]))}
  end

  def handle_event("remove_affected", _params, socket) do
    selection = Map.drop(socket.assigns.selection, socket.assigns.stale_ids)

    {:noreply,
     socket
     |> replace_selection(selection)
     |> assign(
       notice:
         "Removed the affected checks. Proposed values are preserved; review the remaining selection before saving."
     )}
  end

  def handle_event("prepare", _params, socket) do
    case Monitoring.prepare_bulk_configuration(selection_records(socket)) do
      {:ok, prepared} ->
        {:noreply,
         socket
         |> accept_prepared(prepared)
         |> assign(
           phase: :edit,
           error: nil,
           notice: nil,
           review_token: nil,
           preview: nil,
           page: 1
         )}

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("back", _params, socket),
    do:
      {:noreply,
       assign(socket, phase: :edit, review_token: nil, preview: nil, error: nil, page: 1)}

  def handle_event("submit", form, %{assigns: %{phase: :edit}} = socket) do
    socket = keep_form_draft(socket, form)

    with {:ok, typed} <- typed_draft(socket),
         {:ok, preview} <-
           Monitoring.preview_bulk_configuration(socket.assigns.prepare_token, typed) do
      {:noreply,
       assign(socket,
         phase: :preview,
         draft: typed,
         preview: preview,
         review_token: preview["review_token"],
         error: nil,
         notice: nil,
         page: 1
       )}
    else
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("submit", form, %{assigns: %{phase: :preview}} = socket) do
    with true <- form["_review_token"] == socket.assigns.review_token,
         {:ok, typed} <- typed_draft(socket),
         {:ok, saved} <-
           Monitoring.apply_bulk_configuration(socket.assigns.review_token, typed) do
      socket =
        assign(socket,
          phase: :saved,
          receipts: saved["receipts"],
          selection: %{},
          prepare_token: nil,
          review_token: nil,
          preview: nil,
          prepared: nil,
          error: nil,
          page: 1,
          notice:
            "Saved #{saved["changed_count"]} checks together. #{saved["unchanged_count"]} already had these values and received no new version."
        )

      {:noreply, refresh_progress(socket)}
    else
      false -> {:noreply, fail(socket, :review_required)}
      {:error, reason} -> {:noreply, fail(socket, reason)}
    end
  end

  def handle_event("submit", _form, socket), do: {:noreply, fail(socket, :review_required)}

  def handle_event("page", %{"page" => value}, socket) do
    with {:ok, page} <- positive_integer(value) do
      case socket.assigns.phase do
        :preview ->
          with {:ok, typed} <- typed_draft(socket),
               {:ok, preview} <-
                 Monitoring.preview_bulk_configuration(socket.assigns.prepare_token, typed, page) do
            # Keep the original reviewed token and expiry while inspecting another page.
            {:noreply, assign(socket, preview: preview, page: preview["page"], error: nil)}
          else
            {:error, reason} -> {:noreply, fail(socket, reason)}
          end

        :saved ->
          {:noreply, refresh_progress(assign(socket, page: page))}

        _ ->
          {:noreply, socket}
      end
    else
      _ -> {:noreply, fail(socket, :invalid_page)}
    end
  end

  def handle_event("recover", form, socket) do
    with true <- byte_size(Jason.encode!(form)) <= @maximum_recovery_bytes,
         {:ok, captured_selection} <- decode_selection(form["_selection"]),
         {:ok, selection} <- recover_visible_selection(captured_selection, form["selected"]),
         {:ok, draft} <- decode_map(form["_draft"], @maximum_draft_bytes),
         {:ok, resolved} <- decode_list(form["_resolved"], 64) do
      socket =
        socket
        |> assign(selection: selection, draft: draft, resolved_fields: resolved)
        |> keep_form_draft(form)

      # A browser-only membership change must never reuse a token for the old set.
      form =
        if selection != captured_selection, do: Map.put(form, "_prepare_token", ""), else: form

      recover_context(socket, form)
    else
      _ -> {:noreply, fail(socket, :invalid_recovery)}
    end
  end

  # Form recovery restores the frozen selection, never a query or newer revisions.
  # Reloading the schema may issue a new prepare token; discard it and retain the
  # original token/expiry. An explicit Prepare action is required to renew review.
  defp recover_context(socket, %{"_phase" => "saved", "_receipts" => encoded}) do
    with {:ok, receipts} <- decode_receipts(encoded) do
      {:noreply,
       socket
       |> assign(phase: :saved, receipts: receipts, notice: "Restored saved-version progress.")
       |> refresh_progress()}
    else
      _ -> {:noreply, fail(socket, :invalid_recovery)}
    end
  end

  defp recover_context(%{assigns: %{selection: selection}} = socket, _form)
       when map_size(selection) == 0,
       do: {:noreply, socket}

  defp recover_context(socket, form) do
    case Monitoring.prepare_bulk_configuration(selection_records(socket)) do
      {:ok, prepared} ->
        if form["_schema_fingerprint"] in [nil, "", prepared["schema_fingerprint"]] do
          original_token = form["_prepare_token"]
          phase = if original_token in [nil, ""], do: :selection, else: :edit

          {:noreply,
           socket
           |> accept_prepared(prepared)
           |> assign(
             phase: phase,
             prepare_token: original_token,
             review_token: nil,
             preview: nil,
             notice:
               "Selection and proposed values restored. Review changes again before saving.",
             error: nil
           )}
        else
          {:noreply, fail(socket, :schema_changed)}
        end

      {:error, reason} ->
        {:noreply, fail(socket, reason)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        selected_count: map_size(assigns.selection),
        active_bulk_flow:
          map_size(assigns.selection) > 0 || assigns.phase != :selection ||
            assigns.compatibility != nil || map_size(assigns.draft) > 0,
        show_bulk_tools:
          map_size(assigns.selection) > 0 || assigns.phase == :saved ||
            Enum.any?(assigns.rows, &(selectable(&1, assigns.compatibility) == :ok)),
        page_selection: page_selection(assigns),
        locked:
          assigns.phase in [:preview, :saved] ||
            (is_nil(assigns.compatibility) && map_size(assigns.draft) > 0),
        recovery_selection: Jason.encode!(selection_records(assigns)),
        recovery_draft: Jason.encode!(assigns.draft),
        recovery_resolved: Jason.encode!(assigns.resolved_fields),
        recovery_receipts: Jason.encode!(assigns.receipts)
      )

    ~H"""
    <div id={@id}>
      <form
        id="bulk-configuration-form"
        phx-change="edit"
        phx-submit="submit"
        phx-auto-recover="recover"
        phx-target={@myself}
      >
        <input type="hidden" name="_selection" value={@recovery_selection} />
        <input type="hidden" name="_schema_fingerprint" value={@schema_fingerprint} />
        <input type="hidden" name="_prepare_token" value={@prepare_token} />
        <input type="hidden" name="_review_token" value={@review_token} />
        <input type="hidden" name="_draft" value={@recovery_draft} />
        <input type="hidden" name="_resolved" value={@recovery_resolved} />
        <input type="hidden" name="_receipts" value={@recovery_receipts} />
        <input type="hidden" name="_phase" value={@phase} />

        <div :if={@show_bulk_tools} class="panel-body bulk-toolbar">
          <h3>Configure compatible checks together</h3>
          <p :if={!@active_bulk_flow} id="bulk-start-guidance" class="footnote">
            Open a check to edit its parameters, or select a checkbox below to configure compatible checks together.
          </p>
          <p :if={@active_bulk_flow} class="footnote" id="bulk-exception-guidance">
            Changing values creates instance exceptions that override matching rules. Checks whose values already match stay unchanged. Use
            <.link navigate="/configuration/rules" class="text-link">Configuration rules</.link>
            for settings that should apply to future checks.
          </p>
          <p :if={@active_bulk_flow} id="bulk-selection-count" role="status">
            {@selected_count} selected across inventory pages · maximum 512
          </p>
          <div :if={@active_bulk_flow} class="form-actions">
            <button
              type="button"
              class="button small"
              phx-click="select_page"
              phx-target={@myself}
              phx-value-selection={@page_selection}
              disabled={@locked || @page_selection == "[]"}
            >Add compatible checks on this page</button>
            <button
              type="button"
              class="button small"
              phx-click="select_matching"
              phx-target={@myself}
              disabled={@locked || @selected_count == 0}
            >Add all compatible matches</button>
            <button
              type="button"
              class="button small"
              phx-click="clear"
              phx-target={@myself}
              disabled={
                @selected_count == 0 && @phase != :saved && @compatibility == nil &&
                  map_size(@draft) == 0
              }
            >Clear selection and draft</button>
            <button
              :if={@phase in [:selection, :edit]}
              type="button"
              class="button primary"
              phx-click="prepare"
              phx-target={@myself}
              disabled={@selected_count == 0}
            >Review selected checks</button>
          </div>
          <details
            :if={@compatibility}
            id="config-bulk-compatibility"
            class="space-top"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary>Why these checks can be edited together</summary><p class="footnote">
              Source {@compatibility.source_id} declares shared parameter contract {@compatibility.parameter_contract}. Their full schemas, units, bounds, choices and comparisons match. Selection is fixed when you add checks.
            </p>
          </details>
          <p :if={@active_bulk_flow && !@compatibility} class="footnote space-top">
            Select the first check below to choose which settings you want to edit together.
          </p>
        </div>

        <div
          :if={!@show_bulk_tools && @rows != []}
          class="panel-body"
          id="bulk-individual-guidance"
        >
          <h3>Configure these checks individually</h3>
          <p :if={!@compatibility} class="footnote">
            Open a check below to review its settings. Editable settings are saved for that check; source-owned settings are changed in the consumer.
          </p>
          <p :if={@compatibility} class="footnote">
            No checks on this page share the settings in your draft. Inspect a check individually, change the filters, or clear the draft to choose another group.
          </p>
        </div>

        <div
          :if={!@show_bulk_tools && (@compatibility != nil || map_size(@draft) > 0)}
          class="panel-body"
        >
          <button
            type="button"
            class="button small space-top"
            phx-click="clear"
            phx-target={@myself}
          >Clear selection and draft</button>
        </div>

        <div :if={@error} class="form-error panel-body" id="bulk-error" role="alert">{@error}</div>
        <div :if={@error && @stale_ids != []} class="panel-body" id="bulk-affected-checks">
          <h3>{length(@stale_ids)} selected checks changed</h3>
          <p>
            Inspect their current configuration in a new tab, or remove these checks from this edit. The other selected checks and proposed values stay in place.
          </p>
          <ul>
            <li :for={id <- Enum.take(@stale_ids, 25)}>
              <.link href={configuration_path(id, @return_to)} target="_blank" rel="noopener">{id} (opens in a new tab)</.link>
            </li>
          </ul>
          <p :if={length(@stale_ids) > 25} class="footnote">
            Showing 25 of {length(@stale_ids)} affected checks.
          </p>
          <button
            type="button"
            class="button small space-top"
            phx-click="remove_affected"
            phx-target={@myself}
          >Remove affected checks</button>
        </div>
        <p :if={@notice} class="notice notice-copy panel-body" id="bulk-notice" role="status">
          {@notice}
        </p>

        <div :if={@phase == :selection && map_size(@draft) > 0} class="panel-body">
          <h3>Preserved proposed values</h3><p>
            Review the selected checks to restore their current schema. These values have not been submitted again.
          </p>
          <dl class="kv-list">
            <div :for={{key, value} <- Enum.sort(@draft)} class="kv">
              <dt>{key}</dt><dd>{ParameterForm.input_value(value)}</dd>
            </div>
          </dl>
        </div>

        <div :if={@phase == :edit && @parameter_schema} class="panel-body" id="bulk-editor">
          <h3>One complete parameter set for {@selected_count} checks</h3>
          <p>
            This selection covers {expected_results(@prepared["selected_result_count"])}. Shared current values are filled in; every differing value needs your explicit choice.
          </p>
          <ParameterForm.fields
            id_prefix="bulk-param"
            schema={@parameter_schema}
            values={@draft}
            mixed_fields={@mixed_fields}
            resolved_fields={@resolved_fields}
            error={@error}
            error_id="bulk-error"
          />
          <div class="form-actions">
            <p>
              Review expires after 15 minutes. Inventory pages, filters and reconnect preserve this draft. Leaving Configuration or reloading the page discards an unsaved draft.
            </p><button type="submit" class="button primary" phx-disable-with="Reviewing…">Preview changes</button>
          </div>
        </div>

        <div :if={@phase == :preview && @preview} class="panel-body" id="bulk-preview">
          <h3>Review before saving</h3>
          <p id="bulk-preview-summary">
            {@preview["changed_count"]} checks will change; {@preview["unchanged_count"]} already have these values. {@preview[
              "affected_results"
            ]
            |> expected_results()} affected by changed checks.
          </p>
          <p>
            Saving updates this complete set together. Changed checks receive instance exceptions that take precedence over matching rules. Runners prepare and activate each check independently; measurements can arrive at different times.
          </p>
          <.review_rows rows={@preview["rows"]} schema={@parameter_schema} return_to={@return_to} />
          <.pages context={@preview} target={@myself} />
          <div class="form-actions">
            <button type="button" class="button" phx-click="back" phx-target={@myself}>Back to proposed values</button><button
              type="submit"
              class="button primary"
              disabled={@error != nil}
              phx-disable-with="Saving reviewed checks…"
            >Save reviewed checks</button>
          </div>
        </div>

        <div :if={@phase == :saved} class="panel-body" id="bulk-progress">
          <h3>Saved configuration progress</h3>
          <p>
            These stages refer to the exact versions saved by this edit. Saving together does not make runner adoption simultaneous.
          </p>
          <p :if={@progress} role="status">{progress_summary(@progress)}</p>
          <div :if={@progress} class="table-wrap">
            <table class="inventory-table">
              <thead>
                <tr>
                  <th scope="col">Scheduled check</th><th scope="col">Saved version</th><th scope="col">
                    Progress
                  </th>
                </tr>
              </thead><tbody>
                <tr :for={row <- @progress["rows"]} id={"bulk-progress-" <> row["id"]}>
                  <td>
                    <.link navigate={configuration_path(row["id"], @return_to)}>{check_label(row)}</.link><div class="sub">
                      {runner_label(row)}
                    </div>
                  </td><td>{row["target_generation"]}</td><td>{stage_label(row["stage"])}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <.pages :if={@progress} context={@progress} target={@myself} />
          <p class="footnote space-top">
            Measured means fresh complete evidence arrived for that saved version. It can be stale now; inspect check results for current health and freshness. Superseded means a later configuration replaced it; this view does not infer that the saved version ran.
          </p>
        </div>

        <div :if={@rows == []} class="empty">
          <h3>No matching checks</h3><p>
            Change the filters to find checks.
            <span :if={@selected_count > 0}>Your existing selection is preserved.</span>
          </p>
        </div>
        <div :if={@rows != []} class="table-wrap" id="bulk-instance-inventory">
          <table class="inventory-table">
            <thead>
              <tr>
                <th scope="col">Select</th><th scope="col">Scheduled check</th><th scope="col">
                  Runner / source
                </th><th scope="col">Parameters</th><th scope="col">Configuration</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={check <- @rows} id={"configuration-row-" <> check["id"]}>
                <td>
                  <input type="hidden" name={"selected[" <> check["id"] <> "]"} value="" />
                  <input
                    type="checkbox"
                    id={"bulk-select-" <> check["id"]}
                    name={"selected[" <> check["id"] <> "]"}
                    value={check["revision"]}
                    checked={Map.has_key?(@selection, check["id"])}
                    disabled={
                      @locked ||
                        (!Map.has_key?(@selection, check["id"]) &&
                           selectable(check, @compatibility) != :ok)
                    }
                    aria-label={"Select " <> check_label(check) <> " on " <> runner_label(check)}
                    aria-describedby={"bulk-eligibility-" <> check["id"]}
                  />
                </td>
                <td>
                  <.link navigate={configuration_path(check["id"], @return_to)}><strong>{check_label(
                    check
                  )}</strong></.link><div class="sub">
                    {expected_results(length(check["expected_keys"] || []))} · every {MondekWeb.Duration.format_seconds(
                      check["interval_seconds"]
                    )}
                  </div>
                </td>
                <td>
                  {runner_label(check)}
                  <div class="sub">{check["source_id"] || "Legacy controller configuration"}</div><div
                    :if={check["environment"]}
                    class="sub"
                  >
                    {environment_name(check)}
                  </div>
                </td>
                <td id={"bulk-eligibility-" <> check["id"]}>
                  {selection_explanation(check, @compatibility)}
                </td>
                <td>{configuration_stage(check)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </form>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :schema, :map, required: true
  attr :return_to, :string, required: true

  defp review_rows(assigns) do
    ~H"""
    <div class="table-wrap space-top">
      <table class="inventory-table">
        <thead>
          <tr>
            <th scope="col">Scheduled check / targets</th><th scope="col">Reviewed version</th><th scope="col">
              Currently saved → proposed values
            </th>
          </tr>
        </thead><tbody>
          <tr :for={row <- @rows} id={"bulk-review-" <> row["id"]}>
            <td>
              <.link href={configuration_path(row["id"], @return_to)} target="_blank" rel="noopener">{check_label(
                row
              )} (opens in a new tab)</.link><div class="sub">
                {runner_label(row)} · {environment_name(row)}
              </div><ul class="result-links">
                <li :for={output <- row["outputs"] || []}>
                  {output["label"] || output["key"]} · {target_name(output["target"])}
                </li>
              </ul>
            </td>
            <td>
              {row["revision"]}
              <div :if={!row["changed"]} class="sub">Already current; no new version</div>
            </td>
            <td>
              <dl class="kv-list">
                <div :for={{key, _field} <- Enum.sort(@schema["fields"] || %{})} class="kv">
                  <dt>{ParameterForm.field_label(@schema, key)}</dt><dd>
                    {ParameterForm.input_value(row["current_params"][key])} → {ParameterForm.input_value(
                      row["proposed_params"][key]
                    )}
                  </dd>
                </div>
              </dl>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :context, :map, required: true
  attr :target, :any, required: true

  defp pages(assigns) do
    assigns =
      assign(assigns,
        pages: max(1, ceil(assigns.context["total"] / assigns.context["page_size"]))
      )

    ~H"""
    <div class="pagination space-top">
      <button
        type="button"
        class="button small"
        phx-click="page"
        phx-value-page={@context["page"] - 1}
        phx-target={@target}
        disabled={@context["page"] <= 1}
      >Previous review page</button><span>Page {@context["page"]} of {@pages} · {@context["total"]} checks</span><button
        type="button"
        class="button small"
        phx-click="page"
        phx-value-page={@context["page"] + 1}
        phx-target={@target}
        disabled={@context["page"] >= @pages}
      >Next review page</button>
    </div>
    """
  end

  defp accept_prepared(socket, prepared) do
    assign(socket,
      compatibility: %{
        source_id: prepared["source_id"],
        parameter_contract: prepared["parameter_contract"],
        schema: prepared["parameter_schema"]
      },
      parameter_schema: prepared["parameter_schema"],
      schema_fingerprint: prepared["schema_fingerprint"],
      prepare_token: prepared["prepare_token"],
      prepared: prepared,
      draft: Map.merge(prepared["common_params"], socket.assigns.draft),
      mixed_fields: prepared["mixed_fields"]
    )
  end

  defp replace_selection(socket, selection) do
    socket =
      assign(socket,
        selection: selection,
        phase: :selection,
        prepare_token: nil,
        review_token: nil,
        preview: nil,
        prepared: nil,
        error: nil,
        stale_ids: [],
        notice: nil,
        page: 1
      )

    socket
  end

  defp keep_form_draft(socket, form) do
    params = form["params"] || %{}

    proposed = if is_map(params), do: Map.merge(socket.assigns.draft, params), else: nil

    if scalar_params?(proposed) && byte_size(Jason.encode!(proposed)) <= @maximum_draft_bytes do
      resolved =
        if is_map(form["resolved"]),
          do: for({key, value} <- form["resolved"], value == "true", do: key),
          else: socket.assigns.resolved_fields

      assign(socket, draft: proposed, resolved_fields: resolved, draft_error: nil)
    else
      assign(socket,
        draft_error: error_message(:parameter_too_large),
        error: error_message(:parameter_too_large)
      )
    end
  end

  defp typed_draft(socket) do
    cond do
      socket.assigns.draft_error ->
        {:error, socket.assigns.draft_error}

      is_map(socket.assigns.parameter_schema) ->
        ParameterForm.parse(
          socket.assigns.parameter_schema,
          socket.assigns.draft,
          socket.assigns.mixed_fields,
          socket.assigns.resolved_fields
        )

      true ->
        {:error, :review_required}
    end
  end

  defp maybe_edit_phase(%{assigns: %{phase: :preview}} = socket), do: assign(socket, phase: :edit)
  defp maybe_edit_phase(socket), do: socket

  defp refresh_progress(socket) do
    case Monitoring.bulk_configuration_status(socket.assigns.receipts, socket.assigns.page) do
      {:ok, progress} -> assign(socket, progress: progress, page: progress["page"])
      {:error, reason} -> fail(socket, reason)
    end
  end

  defp rendered_check(socket, id, revision) do
    case Enum.find(socket.assigns.rows, &(&1["id"] == id)) do
      %{"revision" => ^revision} = check -> {:ok, check}
      _ -> {:error, :selection_changed}
    end
  end

  defp selectable(check, group) do
    cond do
      check["retired_at"] != nil || check["retired"] == true ->
        {:error, :retired}

      check["params_owner"] != "ui" ->
        {:error, :source_owned}

      check["parameter_contract"] in [nil, ""] ->
        {:error, :no_contract}

      check["source_id"] in [nil, ""] ->
        {:error, :no_contract}

      group &&
          (group.source_id != check["source_id"] ||
             group.parameter_contract != check["parameter_contract"] ||
             group.schema != Parameters.normalized_schema(check["parameter_schema"])) ->
        {:error, :incompatible}

      true ->
        :ok
    end
  end

  defp establish_compatibility(%{assigns: %{compatibility: nil}} = socket, check),
    do:
      assign(socket,
        compatibility: %{
          source_id: check["source_id"],
          parameter_contract: check["parameter_contract"],
          schema: Parameters.normalized_schema(check["parameter_schema"])
        }
      )

  defp establish_compatibility(socket, _), do: socket

  defp page_selection(%{compatibility: nil}), do: "[]"

  defp page_selection(assigns) do
    group = assigns.compatibility

    assigns.rows
    |> Enum.filter(&(selectable(&1, group) == :ok))
    |> Enum.map(&Map.take(&1, ["id", "revision"]))
    |> Jason.encode!()
  end

  defp add_rendered_selection(socket, selected) do
    Enum.reduce_while(selected, {:ok, socket, socket.assigns.selection}, fn {id, revision},
                                                                            {:ok, socket, acc} ->
      with {:ok, row} <- rendered_check(socket, id, revision),
           :ok <- selectable(row, socket.assigns.compatibility) do
        {:cont, {:ok, establish_compatibility(socket, row), Map.put_new(acc, id, revision)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp selection_records(%{assigns: assigns}), do: selection_records(assigns)

  defp selection_records(%{selection: selection}),
    do:
      Enum.map(Enum.sort(selection), fn {id, revision} ->
        %{"id" => id, "revision" => revision}
      end)

  defp decode_selection(encoded) do
    with {:ok, values} <- decode_list(encoded, @maximum_selection), do: checked_selection(values)
  end

  defp checked_selection(values) when is_list(values) and length(values) <= @maximum_selection do
    Enum.reduce_while(values, {:ok, %{}}, fn
      %{"id" => id, "revision" => revision}, {:ok, result}
      when is_binary(id) and byte_size(id) <= 64 and is_integer(revision) and revision > 0 ->
        if Map.has_key?(result, id),
          do: {:halt, {:error, :invalid_selection}},
          else: {:cont, {:ok, Map.put(result, id, revision)}}

      _, _ ->
        {:halt, {:error, :invalid_selection}}
    end)
  end

  defp checked_selection(_), do: {:error, :invalid_selection}

  defp recover_visible_selection(selection, nil), do: {:ok, selection}

  defp recover_visible_selection(selection, visible)
       when is_map(visible) and map_size(visible) <= 100 do
    Enum.reduce_while(visible, {:ok, selection}, fn
      {id, value}, {:ok, selected} when is_binary(id) and byte_size(id) <= 64 ->
        if value == "" do
          # Only submitted page keys can be unchecked; off-page selections remain.
          {:cont, {:ok, Map.delete(selected, id)}}
        else
          case positive_integer(value) do
            {:ok, revision} -> {:cont, {:ok, Map.put_new(selected, id, revision)}}
            _ -> {:halt, {:error, :invalid_selection}}
          end
        end

      _, _ ->
        {:halt, {:error, :invalid_selection}}
    end)
    |> case do
      {:ok, selected} -> with :ok <- within_limit(selected), do: {:ok, selected}
      error -> error
    end
  end

  defp recover_visible_selection(_, _), do: {:error, :invalid_selection}

  defp decode_receipts(encoded) do
    with {:ok, receipts} <- decode_list(encoded, @maximum_selection),
         true <-
           Enum.all?(receipts, fn
             %{
               "id" => id,
               "revision" => revision,
               "target_generation" => generation,
               "changed" => changed
             } ->
               is_binary(id) && byte_size(id) <= 64 && is_integer(revision) && revision > 0 &&
                 is_integer(generation) && generation > 0 && is_boolean(changed)

             _ ->
               false
           end) do
      {:ok, receipts}
    else
      _ -> {:error, :invalid_recovery}
    end
  end

  defp decode_map(encoded, maximum) when is_binary(encoded) and byte_size(encoded) <= maximum do
    case Jason.decode(encoded) do
      {:ok, result} when is_map(result) ->
        if scalar_params?(result), do: {:ok, result}, else: {:error, :invalid_recovery}

      _ ->
        {:error, :invalid_recovery}
    end
  end

  defp decode_map(_, _), do: {:error, :invalid_recovery}

  defp decode_list(encoded, maximum)
       when is_binary(encoded) and byte_size(encoded) <= @maximum_recovery_bytes do
    case Jason.decode(encoded) do
      {:ok, result} when is_list(result) and length(result) <= maximum -> {:ok, result}
      _ -> {:error, :invalid_recovery}
    end
  end

  defp decode_list(_, _), do: {:error, :invalid_recovery}

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_selection}
    end
  end

  defp positive_integer(_), do: {:error, :invalid_selection}

  defp within_limit(selection) when map_size(selection) <= @maximum_selection, do: :ok
  defp within_limit(_), do: {:error, :selection_too_large}

  defp scalar_params?(params) when is_map(params) and map_size(params) <= 32,
    do:
      Enum.all?(params, fn {key, value} ->
        is_binary(key) && byte_size(key) <= 128 &&
          (is_binary(value) || is_number(value) || is_boolean(value))
      end)

  defp scalar_params?(_), do: false

  defp fail(socket, {:stale, ids} = reason),
    do: assign(socket, error: error_message(reason), stale_ids: ids)

  defp fail(socket, reason), do: assign(socket, error: error_message(reason), stale_ids: [])

  defp error_message(:selection_too_large),
    do: "Select at most 512 checks. Narrow the inventory filters before adding more."

  defp error_message(:parameter_too_large),
    do: "The complete parameter set must fit within 16 KiB."

  defp error_message(:no_contract),
    do: "This check has no declared shared parameter contract. Review it individually."

  defp error_message(:source_owned),
    do:
      "The source owns these parameters. Publish changes from the runner's consumer configuration."

  defp error_message(:incompatible),
    do: "Select checks with the same source, declared parameter meaning, and complete schema."

  defp error_message(:retired),
    do: "A selected check was retired. Remove it from this edit and review the remaining checks."

  defp error_message({:invalid, message}), do: message
  defp error_message({:stale, _ids}), do: error_message(:stale)

  defp error_message(reason) when reason in [:expired, :token_expired, :review_expired],
    do:
      "This review expired. Proposed values are preserved. Review selected checks again before saving."

  defp error_message(:review_changed), do: error_message(:stale)
  defp error_message(:invalid_review), do: error_message(:review_required)

  defp error_message(reason)
       when reason in [:stale, :conflict, :selection_changed, :schema_changed],
       do:
         "The selected checks changed since review. Proposed values are preserved. Inspect their current versions, reselect changed checks, and review again; a previous save may already have completed."

  defp error_message(:review_required), do: "Review the complete proposed values before saving."

  defp error_message(:invalid_recovery),
    do:
      "This draft could not be restored safely. Inspect current configuration before making another edit."

  defp error_message(reason) when is_binary(reason), do: reason

  defp error_message(_),
    do:
      "The reviewed edit could not continue. Proposed values are preserved; inspect the selected checks and review again."

  defp selection_explanation(check, group) do
    case selectable(check, group) do
      :ok -> "Can edit together"
      {:error, :source_owned} -> "Source owned"
      {:error, :no_contract} -> "Individual edit only"
      {:error, :retired} -> "Retired; history retained"
      {:error, :incompatible} -> "Different settings; edit separately"
    end
  end

  defp configuration_stage(%{"configuration_stage" => stage}), do: String.capitalize(stage)

  defp configuration_stage(check) do
    desired = check["desired_generation"]

    measured =
      if check["source_id"],
        do: check["observed_generation"],
        else: get_in(check, ["current", "confirmed_generation"])

    cond do
      check["retired_at"] -> "Retired"
      desired && measured == desired -> "Measured"
      desired && check["active_generation"] == desired -> "Active"
      desired && check["prepared_generation"] == desired -> "Prepared"
      true -> "Saved"
    end
  end

  defp progress_summary(progress) do
    for stage <- ~w(pending prepared active measured superseded retired missing),
        count = progress[stage] || get_in(progress, ["counts", stage]) || 0,
        count > 0 do
      "#{count} #{String.downcase(stage_label(stage))}"
    end
    |> Enum.join(" · ")
  end

  defp stage_label("pending"), do: "Pending"
  defp stage_label("prepared"), do: "Prepared"
  defp stage_label("active"), do: "Active; awaiting measurement"
  defp stage_label("measured"), do: "Measured"
  defp stage_label("superseded"), do: "Superseded"
  defp stage_label("retired"), do: "Retired"
  defp stage_label("missing"), do: "No longer retained"
  defp stage_label(_), do: "Not reported"

  defp configuration_path(id, return_to),
    do: "/configuration/" <> id <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp check_label(check), do: check["label"] || check["id"]

  defp runner_label(check),
    do: check["runner_label"] || check["runner_id"] || "Runner not retained"

  defp target_name(%{"label" => label, "key" => key}) when is_binary(label) and label != key,
    do: label <> " (" <> key <> ")"

  defp target_name(target) when is_map(target),
    do: target["label"] || target["key"] || "Target not recorded"

  defp target_name(_), do: "Target not recorded"

  defp expected_results(1), do: "1 expected result"
  defp expected_results(count), do: "#{count} expected results"

  defp environment_name(check) do
    id = check["environment"]
    label = check["environment_label"] || id
    if label && id && label != id, do: label <> " (" <> id <> ")", else: label || "No environment"
  end
end

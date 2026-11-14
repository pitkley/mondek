# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationLive do
  use MondekWeb, :live_view

  alias MondekWeb.{
    BulkConfiguration,
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    PreviewDetail,
    PreviewFilters,
    PreviewLayouts,
    ScalarFilterPicker
  }

  import MondekWeb.EvidencePresentation
  alias Mondek.ConfigurationRules
  alias Mondek.Monitoring
  alias MondekWeb.AgentPrompts
  alias MondekWeb.ConfigurationValues
  alias MondekWeb.ParameterForm
  alias Phoenix.LiveView.JS

  import MondekWeb.MonitoringUI,
    only: [
      page_projection: 1,
      controller_origin: 1,
      source_check?: 1,
      source_label: 1,
      owner_label: 1,
      runner_label: 1,
      environment_name: 1,
      parameter_value: 1,
      parameter_label: 1,
      retired?: 1,
      measured_target: 1,
      config_status: 1,
      configuration_message: 1,
      integer: 1,
      error_message: 1,
      return_label: 2,
      knowledge: 1
    ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1000)

    {:ok,
     socket
     |> assign(
       selected_id: nil,
       return_to: nil,
       controller_url: MondekWeb.Endpoint.url(),
       filters: %{},
       listing: nil,
       drafts: %{},
       errors: %{},
       stale_ids: MapSet.new(),
       feedback: %{},
       instance_review: nil,
       exception_review: nil,
       filter_picker: nil,
       investigation_params: %{},
       investigation_host: "/configuration",
       investigation_open: false,
       investigation_page: false
     )
     |> refresh()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :onboarding}} = socket),
    do: {:noreply, push_navigate(socket, to: "/configuration")}

  def handle_params(params, uri, socket) do
    same_entity = socket.assigns.selected_id == params["id"]
    local = URI.parse(uri)
    filters = configuration_filters(params)

    socket =
      socket
      |> assign(
        selected_id: params["id"],
        return_to: BrowserNavigation.return_path(params["return_to"]),
        controller_url: controller_origin(uri),
        filters: filters,
        page_title: "Configuration",
        investigation_params: params,
        investigation_host: local.path <> if(local.query, do: "?" <> local.query, else: ""),
        investigation_open: InvestigationTrail.resolve(params) != [],
        investigation_page: !is_nil(InvestigationTrail.promoted(params)),
        filter_picker: if(filters == socket.assigns.filters, do: socket.assigns.filter_picker)
      )

    socket =
      if same_entity,
        do: socket,
        else:
          assign(socket,
            drafts: %{},
            errors: %{},
            stale_ids: MapSet.new(),
            feedback: %{},
            instance_review: nil,
            exception_review: nil
          )

    socket = refresh(socket)
    assignment = get_in(socket.assigns.check_inspection || %{}, ["assignment"])

    drafts =
      if assignment,
        do: Map.put_new(socket.assigns.drafts, assignment["id"], draft(assignment)),
        else: socket.assigns.drafts

    {:noreply, assign(socket, drafts: drafts)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  @impl true
  def handle_event("recover_editor", %{"_id" => id, "params" => params} = form, socket) do
    revision = integer(form["_revision"])

    valid_params =
      is_map(params) && map_size(params) <= 32 &&
        Enum.all?(params, fn {key, value} ->
          is_binary(key) && String.valid?(key) && byte_size(key) <= 128 &&
            ((is_binary(value) && String.valid?(value)) || is_number(value) || is_boolean(value))
        end)

    if id == socket.assigns.selected_id && is_integer(revision) && revision > 0 && valid_params &&
         byte_size(Jason.encode!(params)) <= 16_384 do
      {:noreply,
       assign(socket,
         drafts: Map.put(socket.assigns.drafts, id, %{revision: revision, params: params}),
         instance_review: nil,
         exception_review: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event(event, params, socket)
      when event in ~w(edit reload cancel_instance_review confirm_instance_save save preview_exception_reset cancel_exception_reset reset_exception) do
    id = params["_id"] || params["id"] || socket.assigns.selected_id

    if socket.assigns.investigation_open || is_nil(socket.assigns.selected_id) ||
         id != socket.assigns.selected_id,
       do: {:noreply, socket},
       else: handle_editor_event(event, params, socket)
  end

  def handle_event("search", %{"search" => value}, socket),
    do: patch_configuration_filters(socket, %{"search" => ScalarFilterPicker.text(value)})

  def handle_event("filter_open", %{"field" => field}, socket) do
    case configuration_picker(field, "") do
      nil ->
        {:noreply, socket}

      picker ->
        {:noreply,
         assign(socket,
           filter_picker: %{
             picker
             | value: configuration_selected_label(socket.assigns.filters, field)
           }
         )}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket),
    do: {:noreply, ready_filters(socket)}

  def handle_event("filter_close", _, socket), do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do:
        patch_configuration_filters(ready_filters(socket), %{
          field => if(field == "status", do: "all", else: "")
        })

  def handle_event("filter_remove", %{"field" => field}, socket),
    do:
      patch_configuration_filters(ready_filters(socket), %{
        field => if(field == "status", do: "all", else: "")
      })

  def handle_event(
        event,
        %{"search" => value},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ["filter_query", "filter_first"] do
    picker = configuration_picker(field, value)

    case {event, picker.options} do
      {"filter_first", [option | _]} ->
        patch_configuration_filters(ready_filters(socket), %{field => option.key})

      _ ->
        {:noreply, assign(socket, filter_picker: picker)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_configuration_filters(ready_filters(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp handle_editor_event("edit", %{"_id" => id, "params" => params} = form, socket) do
    # LiveView recovers the browser's form after a new server process mounts.
    # Keep the reviewed revision with those values across that recovery.
    reviewed = %{revision: integer(form["_revision"]), params: params}

    {:noreply,
     assign(socket,
       instance_review: nil,
       drafts: Map.put(socket.assigns.drafts, id, reviewed),
       feedback: Map.delete(socket.assigns.feedback, id)
     )}
  end

  defp handle_editor_event("reload", %{"id" => id}, socket) do
    socket = refresh(socket)
    assignment = Monitoring.assignment_detail(id) || %{}

    {:noreply,
     assign(socket,
       drafts: Map.put(socket.assigns.drafts, id, draft(assignment)),
       errors: Map.delete(socket.assigns.errors, id),
       stale_ids: MapSet.delete(socket.assigns.stale_ids, id),
       feedback: Map.delete(socket.assigns.feedback, id)
     )}
  end

  defp handle_editor_event("cancel_instance_review", _, socket),
    do: {:noreply, assign(socket, instance_review: nil)}

  defp handle_editor_event(
         "confirm_instance_save",
         _,
         %{assigns: %{instance_review: nil}} = socket
       ),
       do: {:noreply, socket}

  defp handle_editor_event("confirm_instance_save", _, socket) do
    review = socket.assigns.instance_review

    case ConfigurationRules.apply_instance(review["review_token"]) do
      {:ok, saved} ->
        {:noreply,
         socket
         |> refresh()
         |> assign(
           instance_review: nil,
           drafts: Map.put(socket.assigns.drafts, saved["id"], draft(saved)),
           feedback:
             Map.put(
               socket.assigns.feedback,
               saved["id"],
               if(saved["revision"] == review["revision"],
                 do: "These values are already saved. No new configuration version was created.",
                 else:
                   "Settings saved. Inspect configuration adoption above for activation and measurement progress."
               )
             )
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           instance_review: nil,
           errors: Map.put(socket.assigns.errors, review["id"], error_message(reason))
         )}
    end
  end

  defp handle_editor_event("save", %{"_id" => id} = form, socket) do
    params = form["params"] || %{}
    reviewed = %{revision: integer(form["_revision"]), params: params}

    socket =
      assign(socket,
        drafts: Map.put(socket.assigns.drafts, id, reviewed),
        feedback: Map.delete(socket.assigns.feedback, id),
        stale_ids: MapSet.delete(socket.assigns.stale_ids, id)
      )

    assignment = Monitoring.assignment_detail(id) || %{}

    result =
      if assignment["revision"] != reviewed.revision do
        {:error, :stale}
      else
        with {:ok, typed} <- typed_assignment_params(assignment, params),
             do: ConfigurationRules.preview_instance(id, reviewed.revision, typed)
      end

    case result do
      {:ok, preview} ->
        {:noreply, assign(socket, instance_review: preview)}

      {:error, :stale} ->
        {:noreply,
         assign(socket,
           stale_ids: MapSet.put(socket.assigns.stale_ids, id),
           errors:
             Map.put(
               socket.assigns.errors,
               id,
               "This configuration changed after you opened it. Reload current values, review the change, then save again."
             )
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, errors: Map.put(socket.assigns.errors, id, error_message(reason)))}
    end
  end

  defp handle_editor_event(
         "preview_exception_reset",
         %{"id" => id, "revision" => revision},
         socket
       ) do
    case ConfigurationRules.preview_reset(id, integer(revision)) do
      {:ok, preview} ->
        {:noreply, assign(socket, exception_review: Map.put(preview, "assignment_id", id))}

      {:error, reason} ->
        {:noreply,
         assign(socket, errors: Map.put(socket.assigns.errors, id, error_message(reason)))}
    end
  end

  defp handle_editor_event("cancel_exception_reset", _params, socket),
    do: {:noreply, assign(socket, exception_review: nil)}

  defp handle_editor_event("reset_exception", %{"_review_token" => token}, socket) do
    preview = socket.assigns.exception_review

    result =
      if preview && preview["review_token"] == token,
        do: ConfigurationRules.reset_exception(token),
        else: {:error, :review_required}

    case result do
      {:ok, _} ->
        id = preview["assignment_id"]
        socket = refresh(socket)
        assignment = Monitoring.assignment_detail(id) || %{}

        {:noreply,
         assign(socket,
           instance_review: nil,
           exception_review: nil,
           drafts: Map.put(socket.assigns.drafts, id, draft(assignment)),
           errors: Map.delete(socket.assigns.errors, id),
           feedback:
             Map.put(
               socket.assigns.feedback,
               id,
               "Instance exception removed. This check now follows its matching rule or defaults from code; inspect configuration adoption for progress."
             )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(exception_review: nil)
         |> put_flash(
           :error,
           "The reviewed configuration changed or expired. Preview removing the exception again. " <>
             error_message(reason)
         )}
    end
  end

  defp handle_editor_event(_, _, socket), do: {:noreply, socket}

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = %{"now" => Monitoring.iso(at)}

    socket =
      assign(socket, snapshot: snapshot, now: parse_time(snapshot["now"]) || DateTime.utc_now())

    id = socket.assigns.selected_id

    listing =
      if socket.assigns.live_action == :configuration,
        do: Monitoring.list_checks(socket.assigns.filters)

    detail =
      if socket.assigns.live_action == :configuration_detail && id,
        do: Monitoring.assignment_inspection(id, at)

    detail =
      if detail,
        do: Map.put(detail, "policy_values", Mondek.ConfigurationPolicy.value_details(id))

    snapshot =
      if listing,
        do: Map.put(snapshot, "environments", get_in(listing, [:facets, "environments"]) || []),
        else: snapshot

    assign(socket,
      listing: page_projection(listing),
      check_inspection: detail,
      snapshot: snapshot
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="configuration-shell"
      phx-hook="OverviewPanel"
      data-selection={InvestigationTrail.selection(@investigation_params)}
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "configuration-heading")}
      data-panel-background=".preview-masthead,.preview-sidebar,#configuration-page-background"
    >
      <PreviewLayouts.navigation active={:configuration} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <div
          id="configuration-page-background"
          class="configuration-workspace"
          hidden={@investigation_page}
          inert={@investigation_open}
        >
          <div
            :for={key <- [:info, :error]}
            :if={Phoenix.Flash.get(@flash, key)}
            class="ui-feedback"
            role={if key == :error, do: "alert", else: "status"}
          >
            {Phoenix.Flash.get(@flash, key)}
          </div>
          <.inventory :if={@live_action == :configuration} {assigns} />
          <.configuration :if={@live_action == :configuration_detail} {assigns} />
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={nil}
          initial={[]}
          context={{"configuration", @selected_id || "inventory"}}
          back={
            InvestigationTrail.path(@investigation_host, [], %{"surface" => nil, "page_entity" => nil})
          }
          controller_url={@controller_url}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp inventory(assigns) do
    assigns =
      assign(assigns,
        filter_fields: configuration_fields(),
        filter_chips: configuration_chips(assigns.filters)
      )

    ~H"""
    <section class="preview-list" aria-labelledby="configuration-heading">
      <header class="preview-heading">
        <h1 id="configuration-heading" class="pf-v6-c-title pf-m-2xl">Configuration</h1>
        <div class="configuration-actions">
          <.link
            navigate="/configuration/rules/new"
            id="new-shared-rule"
            class="pf-v6-c-button pf-m-primary"
          >New shared rule</.link>
          <.link
            navigate="/configuration/rules"
            id="configuration-rules-link"
            class="pf-v6-c-button pf-m-secondary"
          >Saved rules</.link>
          <.link
            navigate="/configuration/history"
            id="configuration-history-link"
            class="pf-v6-c-button pf-m-link"
          >History &amp; Git</.link>
        </div>
      </header>
      <p id="configuration-scope-guidance" class="configuration-section-note">
        Open a scheduled check to edit its settings. Selected exceptions cover these instances only, not future checks. Use a shared rule to include future checks.
      </p>
      <div class="configuration-filter-toolbar">
        <PreviewFilters.filter_picker
          picker={@filter_picker}
          chips={@filter_chips}
          fields={@filter_fields}
          search={@filters["search"]}
          remove={
            fn field ->
              configuration_path(
                Map.put(@filters, field, if(field == "status", do: "all", else: ""))
                |> Map.delete("page")
              )
            end
          }
          clear_search={configuration_path(Map.delete(@filters, "search") |> Map.delete("page"))}
          form_label="Filter scheduled checks"
          label="Search scheduled checks"
          placeholder="Search or filter scheduled checks"
        />
      </div>
      <section
        class="preview-table-group"
        id="check-inventory"
        aria-labelledby="check-inventory-heading"
      >
        <h2 id="check-inventory-heading" class="preview-section-heading">
          Scheduled checks <span class="pf-v6-c-badge pf-m-read">{@listing["total"]} matching</span>
        </h2>
        <.live_component
          module={BulkConfiguration}
          id="bulk-configuration"
          rows={@listing["items"]}
          filters={@filters}
          return_to={configuration_path(@filters)}
          now={@now}
          enabled={!@investigation_open}
        />
        <div class="configuration-pagination pagination">
          <MondekWeb.PreviewPagination.pagination
            page={@listing["page"]}
            size={@listing["page_size"]}
            total={@listing["total"]}
            label="Scheduled check pages"
            url={fn page -> configuration_path(Map.put(@filters, "page", page)) end}
          />
        </div>
      </section>
      <PreviewDetail.card id="configuration-adoption-summary" title="Configuration adoption" level={2}>
        <p class="configuration-section-note">
          <strong>{@listing["total"]} matching</strong>
          · {@listing["configuration_summary"]["scope_total"]} before the adoption filter · {@listing[
            "configuration_summary"
          ]["global_total"]} active checks across the installation.
        </p>
        <PreviewDetail.facts label="Installation-wide configuration adoption">
          <tr :for={{stage, name} <- configuration_stage_names()}>
            <th scope="row">{name}</th>
            <td>
              <.link patch={
                configuration_path(%{"configuration_stage" => stage, "status" => "active"})
              }>{@listing["configuration_summary"]["global_counts"][stage]} installation-wide</.link>
            </td>
            <td>{configuration_stage_hint(stage)}</td>
          </tr>
        </PreviewDetail.facts>
        <details id="configuration-stage-help" phx-mounted={JS.ignore_attributes("open")}>
          <summary>What these stages mean</summary>
          <p class="configuration-section-note">
            Each stage follows the desired saved version. Measured means fresh complete evidence arrived for that version; inspect results for current health and freshness. Counts are installation-wide. Selecting a stage clears other filters.
          </p>
        </details>
      </PreviewDetail.card>
      <div class="configuration-help"><ConfigurationValues.workflow /></div>
    </section>
    """
  end

  defp configuration(assigns) do
    assignment = (assigns.check_inspection || %{})["assignment"] || %{}

    assigns =
      assign(assigns,
        assignment: assignment,
        current_draft: assigns.drafts[assignment["id"]] || draft(assignment),
        current_error: assigns.errors[assignment["id"]]
      )

    ~H"""
    <div class="configuration-editor">
      <header class="preview-heading configuration-detail-heading">
        <h1 id="configuration-heading" class="pf-v6-c-title pf-m-2xl">
          {if @assignment == %{}, do: "Check not found", else: label(@assignment)}
        </h1>
        <.link navigate={@return_to || "/configuration"} class="back pf-v6-c-button pf-m-link">← {return_label(
          @return_to,
          "All scheduled checks"
        )}</.link>
      </header>
      <p :if={@assignment == %{}} class="configuration-section-note">
        This check is not in the retained inventory.
      </p>
      <%= if @assignment != %{} do %>
        <PreviewDetail.card id="configuration-scope" title="Scheduled check" level={2}>
          <PreviewDetail.facts label="Scheduled check scope">
            <tr>
              <th scope="row">Monitored subject</th><td>{configuration_subject(@assignment)}</td>
            </tr>
            <tr>
              <th scope="row">Monitored environment</th><td>{environment_name(@assignment)}</td>
            </tr>
            <tr>
              <th scope="row">Observing runner</th><td>
                <.link
                  :if={@assignment["runner_id"]}
                  patch={
                    investigation_path(@investigation_host, {"runner", @assignment["runner_id"]})
                  }
                >{runner_label(@assignment)}</.link><span :if={!@assignment["runner_id"]}>{runner_label(
                  @assignment
                )}</span>
              </td>
            </tr>
            <tr>
              <th scope="row">Settings owner</th><td>{owner_label(@assignment)}</td>
            </tr>
            <tr>
              <th scope="row">Applies to</th><td>
                {length(@assignment["streams"] || [])} results from one execution. Names, targets and membership are defined in code.
              </td>
            </tr>
          </PreviewDetail.facts>
        </PreviewDetail.card>
        <PreviewDetail.card
          :if={!retired?(@assignment)}
          id="configuration-adoption-status"
          title={
            if config_status(@assignment) == "measured",
              do: "Saved version measured",
              else: "Saved version is still being adopted"
          }
          level={2}
        >
          <p
            id={"configuration-progress-" <> @assignment["id"]}
            role="status"
            class="configuration-section-note"
          >
            {configuration_message(@assignment)}
          </p>
          <p :if={config_status(@assignment) != "measured"} class="configuration-section-note">
            Existing results keep the version that produced them.
            <a href="#configuration-results">Inspect results</a><span :if={@assignment["runner_id"]}> or <.link patch={investigation_path(@investigation_host, {"runner", @assignment["runner_id"]})}>check runner status</.link></span>.
          </p>
          <details id="configuration-adoption-versions" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Configuration adoption stages</summary>
            <div class="stages">
              <PreviewDetail.facts label="Configuration versions">
                <tr>
                  <th scope="row">Saved</th><td>v{@assignment["desired_generation"]}</td>
                </tr>
                <tr>
                  <th scope="row">Prepared</th><td>{version(@assignment["prepared_generation"])}</td>
                </tr>
                <tr>
                  <th scope="row">Active</th><td>{version(@assignment["active_generation"])}</td>
                </tr>
                <tr>
                  <th scope="row">Measured</th><td>{version(@assignment["observed_generation"])}</td>
                </tr>
              </PreviewDetail.facts>
            </div>
          </details>
        </PreviewDetail.card>
        <div class="config-grid">
          <PreviewDetail.card id={"configuration-" <> @assignment["id"]} title="Parameters" level={2}>
            <div class="configuration-card-body">
              <p :if={source_check?(@assignment) && editable?(@assignment)} id="delegated-parameters">
                Edits here are saved as an instance exception for this scheduled check. Shared rules and code defaults no longer apply until that exception is removed; it does not follow a replacement observer.
              </p>
              <div :if={editable?(@assignment)} class="configuration-actions">
                <.link
                  :if={@assignment["parameter_contract"]}
                  id="create-durable-rule"
                  navigate={"/configuration/rules/new?" <> URI.encode_query(%{"check_id" => @assignment["id"], "return_to" => @investigation_host})}
                  class="pf-v6-c-button pf-m-secondary"
                >Configure similar checks</.link>
                <button
                  :if={is_map(@assignment["instance_exception"])}
                  id="remove-instance-exception"
                  type="button"
                  class="pf-v6-c-button pf-m-secondary"
                  phx-click="preview_exception_reset"
                  phx-value-id={@assignment["id"]}
                  phx-value-revision={@assignment["revision"]}
                >Remove exception and use rules/defaults</button>
                <.link
                  :if={get_in(@assignment, ["discovery", "kind"]) == "manager"}
                  navigate={"/configuration/discovery/" <> @assignment["id"]}
                  class="pf-v6-c-button pf-m-secondary"
                >Configure resource discovery</.link>
              </div>
              <p :if={!editable?(@assignment)} id="source-owned-parameters">
                {if retired?(@assignment),
                  do: "This check is retired. These are its last saved values.",
                  else:
                    "These settings are owned by the source. Change them in the monitoring project and publish a new complete inventory."}
              </p>
              <form
                :if={editable?(@assignment)}
                id={"form-" <> @assignment["id"]}
                phx-change="edit"
                phx-submit="save"
                phx-auto-recover="recover_editor"
              >
                <input type="hidden" name="_id" value={@assignment["id"]} />
                <input type="hidden" name="_revision" value={@current_draft.revision} />
                <div
                  :if={
                    @current_draft.revision != @assignment["revision"] &&
                      !MapSet.member?(@stale_ids, @assignment["id"])
                  }
                  id="configuration-editor-updated"
                  class="configuration-inline-feedback"
                  role="status"
                >
                  Saved settings changed while this form was open. Your draft keeps version {@current_draft.revision}; the current saved version is {@assignment[
                    "revision"
                  ]}.
                  <button
                    type="button"
                    class="pf-v6-c-button pf-m-secondary"
                    phx-click="reload"
                    phx-value-id={@assignment["id"]}
                  >Reload current values and discard draft</button>
                </div>
                <div
                  :if={@current_error}
                  id={"error-" <> @assignment["id"]}
                  class="configuration-inline-feedback"
                  role="alert"
                >
                  {@current_error}
                  <button
                    :if={MapSet.member?(@stale_ids, @assignment["id"])}
                    type="button"
                    class="pf-v6-c-button pf-m-secondary"
                    phx-click="reload"
                    phx-value-id={@assignment["id"]}
                  >Reload current values and discard draft</button>
                </div>
                <ParameterForm.fields
                  id_prefix={@assignment["id"]}
                  schema={@assignment["parameter_schema"]}
                  values={@current_draft.params}
                  error={@current_error}
                  error_id={"error-" <> @assignment["id"]}
                />
                <div class="configuration-form-actions">
                  <span class="preview-caption">Reviewing saved version {@current_draft.revision}</span><button
                    class="pf-v6-c-button pf-m-primary"
                    phx-disable-with="Reviewing…"
                  >Review settings for this check</button>
                </div>
              </form>
            </div>
            <.parameter_values
              :if={!editable?(@assignment)}
              assignment={@assignment}
              values={@assignment["params"] || %{}}
              label="Saved parameter values"
            />
            <section
              :if={@instance_review && @instance_review["id"] == @assignment["id"]}
              id="instance-save-review"
              class="configuration-review"
            >
              <h3>Review settings for this check</h3>
              <p>
                Save this complete parameter set for this check only. Unchanged values are pinned too; future rules and defaults do not merge field by field. Saving does not mean activation or measurement.
              </p>
              <.parameter_values
                assignment={@assignment}
                values={@instance_review["proposed_params"]}
                current={@instance_review["current_params"]}
                label="Reviewed parameter changes"
              />
              <div class="configuration-form-actions">
                <button
                  type="button"
                  class="pf-v6-c-button pf-m-secondary"
                  phx-click="cancel_instance_review"
                >Back to editing</button><button
                  id="confirm-instance-save"
                  class="pf-v6-c-button pf-m-primary"
                  phx-click="confirm_instance_save"
                  phx-disable-with="Saving…"
                >Save reviewed settings</button>
              </div>
            </section>
            <section
              :if={@exception_review && @exception_review["assignment_id"] == @assignment["id"]}
              id="exception-reset-preview"
              class="configuration-review"
            >
              <h3>Remove this instance exception</h3><p>
                These complete values will come from the matching rule or defaults from code. Future rule changes will apply to this check.
              </p>
              <.parameter_values
                assignment={@assignment}
                values={@exception_review["proposed_params"] || %{}}
                label="Values after removing exception"
              />
              <form id="exception-reset-form" phx-submit="reset_exception">
                <input type="hidden" name="_review_token" value={@exception_review["review_token"]} /><div class="configuration-form-actions">
                  <button
                    type="button"
                    class="pf-v6-c-button pf-m-secondary"
                    phx-click="cancel_exception_reset"
                  >Keep exception</button><button
                    class="pf-v6-c-button pf-m-primary"
                    phx-disable-with="Removing…"
                  >Confirm removal</button>
                </div>
              </form>
            </section>
            <div
              :if={@feedback[@assignment["id"]]}
              id="configuration-saved-actions"
              class="configuration-inline-feedback"
            >
              <p id={"feedback-" <> @assignment["id"]} role="status">
                {@feedback[@assignment["id"]]}
              </p>
              <.link navigate="/configuration/history" class="pf-v6-c-button pf-m-link">View configuration history</.link>
            </div>
          </PreviewDetail.card>
          <PreviewDetail.card
            id="configuration-results"
            title="Results from this check"
            level={2}
            tabindex="-1"
          >
            <table class="preview-incident-fact-table" aria-label="Results from this scheduled check">
              <thead>
                <tr>
                  <th scope="col">Result / target</th><th scope="col">Measurement</th>
                </tr>
              </thead><tbody>
                <tr :for={stream <- @assignment["streams"] || []}>
                  <th scope="row">
                    <.link patch={investigation_path(@investigation_host, {"result", stream["id"]})}>{label(
                      stream
                    )}</.link><span class="preview-caption configuration-secondary">{target_label(
                      stream["target"]
                    )}</span>
                  </th><td><.badge value={knowledge(stream)} /></td>
                </tr>
              </tbody>
            </table>
            <p :if={(@assignment["streams"] || []) == []} class="configuration-section-note">
              No measured results yet. Expected: {Enum.join(@assignment["expected_keys"] || [], ", ")}.
            </p>
            <p class="configuration-section-note">
              <.link patch={investigation_path(@investigation_host, {"execution", @assignment["id"]})}>Inspect shared execution and control history</.link>
            </p>
          </PreviewDetail.card>
        </div>
        <PreviewDetail.card id="configuration-origin" title="Saved values and defaults" level={2}>
          <PreviewDetail.facts label="Configuration provenance">
            <tr>
              <th scope="row">Current values</th><td>
                <ConfigurationValues.origin value={@assignment["configuration_origin"] || %{}} />
              </td>
            </tr><tr>
              <th scope="row">Precedence</th><td>
                Instance exception → highest-priority matching rule → defaults from code. Each supplies the complete parameter set.
              </td>
            </tr>
          </PreviewDetail.facts>
          <ConfigurationValues.comparison
            assignment={@assignment}
            values={(@check_inspection || %{})["policy_values"] || %{}}
          />
          <details
            :if={is_map(@assignment["source_defaults"])}
            id="config-source-defaults"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Defaults from code</summary><.parameter_values
              assignment={@assignment}
              values={@assignment["source_defaults"]}
              label="Defaults from code"
            />
          </details>
        </PreviewDetail.card>
        <PreviewDetail.card id="config-source-context" title="Source and execution" level={2}>
          <PreviewDetail.facts label="Source and execution">
            <tr>
              <th scope="row">Source</th><td>{source_label(@assignment)}</td>
            </tr>
            <tr>
              <th scope="row">Check key</th><td>{@assignment["source_key"]}</td>
            </tr>
            <tr>
              <th scope="row">Runs every</th><td>
                {MondekWeb.Duration.format_seconds(@assignment["interval_seconds"])}
              </td>
            </tr>
            <tr>
              <th scope="row">Timeout</th><td>
                {MondekWeb.Duration.format_seconds(@assignment["timeout_seconds"])}
              </td>
            </tr>
            <tr>
              <th scope="row">Freshness limit</th><td>
                {MondekWeb.Duration.format_seconds(@assignment["freshness_seconds"])}
              </td>
            </tr>
          </PreviewDetail.facts>
          <details id="check-source-revisions" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Technical source identity</summary><PreviewDetail.facts label="Technical source identity">
              <tr>
                <th scope="row">Assignment</th><td>{@assignment["id"]}</td>
              </tr><tr>
                <th scope="row">Source revision</th><td>{@assignment["source_revision"]}</td>
              </tr><tr>
                <th scope="row">Definition revision</th><td>{@assignment["definition_revision"]}</td>
              </tr>
            </PreviewDetail.facts>
          </details>
        </PreviewDetail.card>
        <AgentPrompts.library
          id={"configuration-agent-prompts-" <> @assignment["id"]}
          kinds={[:check, :retirement]}
          context={
            %{
              "check_id" => @assignment["id"],
              "check_key" => @assignment["source_key"],
              "check_name" => label(@assignment),
              "source_id" => @assignment["source_id"]
            }
          }
        />
      <% end %>
    </div>
    """
  end

  attr :assignment, :map, required: true
  attr :values, :map, required: true
  attr :current, :any, default: nil
  attr :label, :string, required: true

  defp parameter_values(assigns) do
    ~H"""
    <PreviewDetail.facts label={@label}>
      <tr :for={{key, value} <- Enum.sort(@values)}>
        <th scope="row">
          {schema_label(@assignment, key)}<span :if={
            get_in(@assignment, ["parameter_schema", "fields", key, "unit"])
          }> ({get_in(@assignment, ["parameter_schema", "fields", key, "unit"])})</span>
        </th>
        <td>
          <span :if={@current}>{parameter_value(@current[key])} → </span>{parameter_value(value)}<strong :if={
            @current && value != @current[key]
          }> · Changed</strong>
        </td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  defp configuration_subject(assignment) do
    targets =
      (assignment["outputs"] || [])
      |> Enum.map(& &1["target"])
      |> Enum.filter(&is_map/1)
      |> Enum.uniq_by(&{&1["kind"], &1["key"]})

    case targets do
      [target] -> target_label(target)
      [] -> measured_target(assignment)
      targets -> "#{length(targets)} declared targets in one shared execution"
    end
  end

  defp version(nil), do: "Not yet"
  defp version(value), do: "v#{value}"
  defp investigation_path(host, identity), do: InvestigationTrail.path(host, [identity])

  defp configuration_path(filters),
    do:
      MondekWeb.InvestigationNavigation.filter_path(
        :configuration,
        Map.reject(filters, fn {key, value} -> key == "status" && value == "active" end)
      )

  defp configuration_fields,
    do: [
      {"status", "Inventory", "info"},
      {"configuration_stage", "Adoption", "clock"},
      {"environment", "Environment", "globe"},
      {"runner_id", "Runner", "server"}
    ]

  defp configuration_filters(params) do
    filters =
      for key <- ~w(search environment runner_id page selected_page),
          value = params[key],
          is_binary(value) && String.valid?(value) && !String.contains?(value, <<0>>) &&
            byte_size(value) <= 800 && value != "",
          into: %{},
          do: {key, value}

    filters =
      Map.put(
        filters,
        "status",
        if(params["status"] in ~w(active retired all), do: params["status"], else: "active")
      )

    if params["configuration_stage"] in ~w(saved prepared active measured),
      do: Map.put(filters, "configuration_stage", params["configuration_stage"]),
      else: filters
  end

  defp configuration_choices("status", _),
    do: [{"active", "Active checks"}, {"retired", "Retired checks"}, {"all", "All checks"}]

  defp configuration_choices("configuration_stage", _), do: configuration_stage_names()

  defp configuration_choices("runner_id", query),
    do: Enum.map(Mondek.ObserverFilters.options("runner_id", query), &{&1.key, &1.label})

  defp configuration_choices("environment", query),
    do:
      Enum.map(
        Mondek.OverviewFilters.options("environment", query, nil, :checks),
        &{&1.key, &1.label}
      )

  defp configuration_picker(field, value),
    do:
      ScalarFilterPicker.draft(
        configuration_fields(),
        &configuration_choices(&1, value),
        field,
        value
      )

  defp configuration_selected_label(filters, field) do
    case field do
      "runner_id" ->
        case Mondek.ObserverFilters.options(field, "", {filters[field], ""}) do
          [item | _] -> item.label
          _ -> filters[field] || ""
        end

      "environment" ->
        case Mondek.OverviewFilters.options(field, "", {filters[field], ""}, :checks) do
          [item | _] -> item.label
          _ -> filters[field] || ""
        end

      _ ->
        ScalarFilterPicker.label(configuration_choices(field, ""), filters[field])
    end
  end

  defp configuration_chips(filters),
    do:
      for(
        {field, name, _} <- configuration_fields(),
        filters[field] not in [nil, "", "all"],
        do: %{field: field, name: name, label: configuration_selected_label(filters, field)}
      )

  defp ready_filters(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp patch_configuration_filters(socket, changes),
    do:
      {:noreply,
       push_patch(socket,
         to:
           configuration_path(
             configuration_filters(
               socket.assigns.filters
               |> Map.merge(changes)
               |> Map.delete("page")
             )
           )
       )}

  defp configuration_stage_hint("saved"), do: "Waiting for preparation"
  defp configuration_stage_hint("prepared"), do: "Waiting for activation"
  defp configuration_stage_hint("active"), do: "Waiting for measurement"

  defp configuration_stage_hint("measured"),
    do: "Complete evidence arrived; current evidence may be stale"

  defp editable?(check),
    do:
      !retired?(check) &&
        check["params_owner"] == "ui"

  defp schema_label(check, key),
    do: get_in(check, ["parameter_schema", "fields", key, "label"]) || parameter_label(key)

  defp typed_assignment_params(assignment, params),
    do: ParameterForm.parse(assignment["parameter_schema"], params)

  defp configuration_stage_names,
    do: [
      {"saved", "Saved"},
      {"prepared", "Prepared"},
      {"active", "Active"},
      {"measured", "Measured"}
    ]

  defp draft(assignment),
    do: %{revision: assignment["revision"], params: assignment["params"] || %{}}
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationLive do
  use MondekWeb, :live_view
  alias MondekWeb.BulkConfiguration
  import MondekWeb.EvidencePresentation
  alias Mondek.ConfigurationRules
  alias Mondek.Monitoring
  alias MondekWeb.AgentPrompts
  alias MondekWeb.ConfigurationValues
  alias MondekWeb.ParameterForm
  alias Phoenix.LiveView.JS
  import MondekWeb.MonitoringUI
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
       exception_review: nil
     )
     |> refresh()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :onboarding}} = socket),
    do: {:noreply, push_navigate(socket, to: "/configuration")}

  def handle_params(params, uri, socket) do
    socket =
      socket
      |> assign(
        selected_id: params["id"],
        return_to: safe_return_path(params["return_to"]),
        controller_url: controller_origin(uri),
        filters: inventory_params(params, socket.assigns.live_action),
        page_title: page_name(socket.assigns.live_action)
      )

    socket =
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

    socket =
      assign(socket,
        drafts: if(assignment, do: %{assignment["id"] => draft(assignment)}, else: %{})
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1000)
    {:noreply, refresh(socket)}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      params
      |> Map.take(~w(search runner_id environment health freshness status configuration_stage))
      |> Map.merge(result_page_size_filter(socket.assigns.filters, socket.assigns.live_action))

    {:noreply,
     push_patch(socket, to: filter_path(socket.assigns.live_action, filters), replace: true)}
  end

  def handle_event("recover_filters", params, socket) do
    mode = socket.assigns.live_action

    # Recovered controls include empty inputs and the selected default status,
    # while the URL may omit both. Replaying those values is not a filter edit
    # and must not discard the current result page or rewrite its return URL.
    if comparable_inventory_filters(params, mode) ==
         comparable_inventory_filters(socket.assigns.filters, mode) do
      {:noreply, socket}
    else
      handle_event("filter", params, socket)
    end
  end

  def handle_event("edit", %{"_id" => id, "params" => params} = form, socket) do
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

  def handle_event("reload", %{"id" => id}, socket) do
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

  def handle_event("cancel_instance_review", _, socket),
    do: {:noreply, assign(socket, instance_review: nil)}

  def handle_event("confirm_instance_save", _, %{assigns: %{instance_review: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_instance_save", _, socket) do
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

  def handle_event("save", %{"_id" => id} = form, socket) do
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

  def handle_event("preview_exception_reset", %{"id" => id, "revision" => revision}, socket) do
    case ConfigurationRules.preview_reset(id, integer(revision)) do
      {:ok, preview} ->
        {:noreply, assign(socket, exception_review: Map.put(preview, "assignment_id", id))}

      {:error, reason} ->
        {:noreply,
         assign(socket, errors: Map.put(socket.assigns.errors, id, error_message(reason)))}
    end
  end

  def handle_event("cancel_exception_reset", _params, socket),
    do: {:noreply, assign(socket, exception_review: nil)}

  def handle_event("reset_exception", %{"_review_token" => token}, socket) do
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

  defp refresh(socket) do
    at = Monitoring.now()
    snapshot = Monitoring.overview(at)

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
    <MondekWeb.Layouts.app
      active={@live_action}
      page_title={page_name(@live_action)}
      snapshot={@snapshot}
      now={@now}
      flash={@flash}
    >
      <.inventory
        :if={@live_action == :configuration}
        listing={@listing}
        mode={@live_action}
        filters={@filters}
        snapshot={@snapshot}
        now={@now}
      />
      <.configuration
        :if={@live_action == :configuration_detail}
        inspection={@check_inspection}
        now={@now}
        drafts={@drafts}
        errors={@errors}
        stale_ids={@stale_ids}
        feedback={@feedback}
        instance_review={@instance_review}
        exception_review={@exception_review}
        return_to={@return_to}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp inventory(assigns) do
    ~H"""
    <div class="page-heading">
      <div>
        <div class="eyebrow">Runner-provided inventory</div>
        <h1>Configuration</h1>
        <p>
          Review effective settings and instance exceptions, or create shared rules for present and future checks.
        </p>
      </div>
      <.link
        navigate="/configuration/rules"
        class="button primary"
        id="configuration-rules-link"
      >Configuration rules</.link>
    </div>
    <p class="space-top">
      <.link
        navigate="/configuration/history"
        class="button secondary"
        id="configuration-history-link"
      >Configuration history and Git access</.link>
    </p>
    <section class="configuration-intents" aria-label="Choose what to configure">
      <div class="panel panel-body">
        <h2>Share settings across similar checks</h2>
        <p>
          A shared rule covers matching checks now and when new ones appear. Choose a group declared by your check code, then review its scope and values.
        </p>
        <.link
          navigate="/configuration/rules/new"
          class="button primary space-top"
          id="new-shared-rule"
        >New shared rule</.link>
      </div>
      <div class="panel panel-body">
        <h2>Change individual checks</h2>
        <p>
          Find a check below to inspect its effective values or create an instance exception. Selecting several checks creates exceptions for those instances only, not future checks.
        </p>
        <a href="#check-inventory" class="button space-top">Find individual checks</a>
      </div>
    </section>
    <ConfigurationValues.workflow />
    <.setup :if={get_in(@snapshot, ["coverage", "active"]) == 0 && @filters["status"] != "retired"} />
    <.inventory_filters filters={@filters} mode={@mode} snapshot={@snapshot} />
    <section class="panel" id="check-inventory">
      <div class="panel-heading">
        <h2 id="check-inventory-heading">Scheduled checks</h2>
        <span class="badge">{@listing["total"]} matching</span>
      </div>
      <.live_component
        module={BulkConfiguration}
        id="bulk-configuration"
        rows={@listing["items"]}
        filters={@filters}
        return_to={filter_path(@mode, @filters)}
        now={@now}
      />
      <.pagination listing={@listing} filters={@filters} mode={@mode} />
    </section>
    <details
      class="panel config-adoption-summary space-top"
      id="configuration-adoption-summary"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>Installation-wide configuration adoption</summary>
      <p>
        <strong>{@listing["total"]} matching</strong>
        · {@listing["configuration_summary"]["scope_total"]} before the adoption filter · {@listing[
          "configuration_summary"
        ]["global_total"]} active checks across the installation.
      </p>
      <p class="config-adoption-context">
        Across all active checks · Selecting a stage clears other filters.
      </p>
      <nav class="config-adoption-counts" aria-label="Configuration adoption across the installation">
        <.link
          :for={{stage, name} <- configuration_stage_names()}
          patch={filter_path(:configuration, %{"configuration_stage" => stage, "status" => "active"})}
          class={"config-adoption-count " <> if(stage == "measured", do: "config-adoption-measured", else: "")}
        >
          <span>{name}</span><span class="config-adoption-number">{@listing["configuration_summary"][
            "global_counts"
          ][stage]}</span>
          <small>{configuration_stage_hint(stage)}</small>
        </.link>
      </nav>
      <details id="configuration-stage-help" phx-mounted={JS.ignore_attributes("open")}>
        <summary>About configuration stages</summary>
        <p id="configuration-adoption-help">
          Counts above cover all active checks; choose a stage to view that installation-wide set. Stages follow the desired version. Measured means fresh complete evidence arrived; it can be stale now.
        </p>
        <p>
          Source-owned settings follow the same stages. Retired checks appear only with All adoption stages.
          For a waiting version, inspect its results and
          <.link navigate="/runners">runner diagnostics</.link>
          for collection, preparation or connection problems.
        </p>
      </details>
    </details>
    <p class="footnote space-top">
      Search and filters apply to the full stored inventory. Silence or a failed inventory refresh does not retire expected results.
    </p>
    """
  end

  defp configuration(assigns) do
    assignment = (assigns.inspection || %{})["assignment"] || %{}

    result_return_to =
      if Regex.match?(~r"\A/(checks|resources)/", URI.parse(assigns.return_to || "").path || "") do
        MondekWeb.InvestigationNavigation.safe_return_path(
          URI.decode_query(URI.parse(assigns.return_to).query || "")["return_to"]
        )
      else
        assigns.return_to
      end

    assigns = assign(assigns, assignment: assignment, result_return_to: result_return_to)

    ~H"""
    <.link navigate={@return_to || "/configuration"} class="back"><.icon name="back" size={13} />{return_label(
      @return_to,
      "All scheduled checks"
    )}</.link>
    <div :if={@assignment == %{}} class="notice warn">
      This check is not in the retained inventory.
    </div>
    <div :if={@assignment != %{}}>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Scheduled check configuration</div><h1>{label(@assignment)}</h1>
          <dl class="result-context">
            <div>
              <dt>Monitored subject</dt><dd>{measured_target(@assignment)}</dd>
            </div><div>
              <dt>Monitored environment</dt><dd>{environment_name(@assignment)}</dd>
            </div><div>
              <dt>Observing runner</dt><dd>{runner_label(@assignment)}</dd>
            </div>
          </dl>
        </div><.badge value={config_status(@assignment)} />
      </div>
      <section
        :if={!retired?(@assignment)}
        class={"panel config-adoption-status " <> if(config_status(@assignment) == "measured", do: "config-adoption-complete", else: "config-adoption-waiting")}
        id="configuration-adoption-status"
        aria-labelledby="configuration-adoption-heading"
      >
        <h2 id="configuration-adoption-heading">
          {if config_status(@assignment) == "measured",
            do: "Saved version measured",
            else: "Saved version is still being adopted"}
        </h2>
        <p id={"configuration-progress-" <> @assignment["id"]} role="status">
          {configuration_message(@assignment)}
        </p>
        <p :if={config_status(@assignment) != "measured"} class="config-adoption-next">
          Existing results keep the version that produced them.
          <a href="#configuration-results">Inspect results</a>
          or <.link navigate={
            if @assignment["runner_id"],
              do: MondekWeb.RunnersLive.detail_path(@assignment["runner_id"]),
              else: "/runners"
          }>check runner status</.link>.
        </p>
        <details
          id="configuration-adoption-versions"
          class="config-adoption-versions"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Configuration adoption stages</summary>
          <.stages assignment={@assignment} show_message={false} />
        </details>
      </section>
      <p :if={get_in(@assignment, ["discovery", "kind"]) == "manager"} class="space-bottom">
        <.link navigate={"/configuration/discovery/" <> @assignment["id"]} class="button primary">Configure resource discovery</.link>
      </p>
      <div class="config-grid">
        <section class="panel config-card" id={"configuration-" <> @assignment["id"]}>
          <div class="panel-heading">
            <h2>Parameters</h2><span class="badge">{owner_label(@assignment)}</span>
          </div>
          <div class="panel-body">
            <section
              :if={source_check?(@assignment) && editable?(@assignment)}
              id="configuration-scope"
              class="parameter-intro"
            >
              <h3>Change settings for this check</h3>
              <p>
                This form changes {length(@assignment["streams"] || [])} {if length(
                                                                               @assignment["streams"] ||
                                                                                 []
                                                                             ) == 1,
                                                                             do: "result",
                                                                             else: "results"} from this check on {runner_label(
                  @assignment
                )}.
                This exception belongs to this scheduled instance. If it manages automatic discovery, its settings also apply to resources it discovers later. It does not follow a replacement observer.
              </p>
              <div class="form-actions">
                <.link
                  :if={@assignment["parameter_contract"]}
                  id="create-durable-rule"
                  navigate={"/configuration/rules/new?" <> URI.encode_query(Map.reject(%{"check_id" => @assignment["id"], "return_to" => @return_to}, fn {_, value} -> is_nil(value) end))}
                  class="button small"
                >Configure similar checks</.link>
                <span class="footnote">Shared settings can include future checks.</span>
                <button
                  :if={is_map(@assignment["instance_exception"])}
                  id="remove-instance-exception"
                  type="button"
                  class="button small"
                  phx-click="preview_exception_reset"
                  phx-value-id={@assignment["id"]}
                  phx-value-revision={@assignment["revision"]}
                >Remove exception and use rules/defaults</button>
              </div>
              <p :if={!@assignment["parameter_contract"]} class="footnote">
                To share settings through rules, declare a parameter contract in this check's Python code.
              </p>
            </section>

            <section
              :if={@exception_review && @exception_review["assignment_id"] == @assignment["id"]}
              id="exception-reset-preview"
              class="notice notice-copy space-top"
            >
              <h3>Remove this instance exception</h3><p>
                The following values will come from the matching rule or defaults from code. Future rule changes will apply to this check.
              </p>
              <dl class="kv-list">
                <div
                  :for={{key, value} <- Enum.sort(@exception_review["proposed_params"] || %{})}
                  class="kv"
                >
                  <dt>
                    {schema_label(@assignment, key)}<span :if={
                      get_in(@assignment, ["parameter_schema", "fields", key, "unit"])
                    }> ({get_in(@assignment, ["parameter_schema", "fields", key, "unit"])})</span>
                  </dt><dd>{parameter_value(value)}</dd>
                </div>
              </dl>
              <form id="exception-reset-form" phx-submit="reset_exception">
                <input type="hidden" name="_review_token" value={@exception_review["review_token"]} /><div class="form-actions">
                  <button type="button" class="button small" phx-click="cancel_exception_reset">Keep exception</button><button
                    class="button primary"
                    phx-disable-with="Removing…"
                  >Confirm removal</button>
                </div>
              </form>
            </section>
            <p
              :if={editable?(@assignment) && source_check?(@assignment)}
              class="parameter-intro"
              id="delegated-parameters"
            >
              These values override shared rules for this check until you remove the exception.
            </p>
            <p :if={!editable?(@assignment)} class="notice notice-copy" id="source-owned-parameters">
              {if retired?(@assignment),
                do: "This check is retired. These are its last saved values.",
                else:
                  "This parameter set is owned by the source. Change it in the runner's consumer configuration and publish a new complete inventory."}
            </p>
            <form
              :if={editable?(@assignment)}
              id={"form-" <> @assignment["id"]}
              phx-change="edit"
              phx-submit="save"
            >
              <input type="hidden" name="_id" value={@assignment["id"]} />
              <input
                type="hidden"
                name="_revision"
                value={(@drafts[@assignment["id"]] || draft(@assignment)).revision}
              />
              <div
                :if={
                  (@drafts[@assignment["id"]] || draft(@assignment)).revision !=
                    @assignment["revision"] &&
                    !MapSet.member?(@stale_ids, @assignment["id"])
                }
                id="configuration-editor-updated"
                class="notice warn notice-copy space-bottom"
                role="status"
              >
                <p>
                  Saved settings changed while this form was open. The fields below retain version {(@drafts[
                                                                                                       @assignment[
                                                                                                         "id"
                                                                                                       ]
                                                                                                     ] ||
                                                                                                       draft(
                                                                                                         @assignment
                                                                                                       )).revision}; current saved settings
                  are version {@assignment["revision"]}. Your draft has been kept.
                </p>
                <button
                  type="button"
                  class="button small"
                  phx-click="reload"
                  phx-value-id={@assignment["id"]}
                >Reload current values and discard draft</button>
              </div>
              <div
                :if={@errors[@assignment["id"]]}
                id={"error-" <> @assignment["id"]}
                class="form-error"
                role="alert"
              >
                {@errors[@assignment["id"]]}
                <div class="space-top">
                  <button
                    :if={MapSet.member?(@stale_ids, @assignment["id"])}
                    type="button"
                    class="button small"
                    phx-click="reload"
                    phx-value-id={@assignment["id"]}
                  >Reload current values and discard draft</button>
                </div>
              </div>
              <.schema_fields
                :if={source_check?(@assignment)}
                assignment={@assignment}
                draft={@drafts[@assignment["id"]] || draft(@assignment)}
                error={@errors[@assignment["id"]]}
              />
              <div class="form-actions">
                <p>
                  Reviewing saved version {(@drafts[@assignment["id"]] || draft(@assignment)).revision}
                </p>
                <button class="button primary" phx-disable-with="Saving…">Review settings for this check</button>
              </div>
            </form>
            <section
              :if={@instance_review && @instance_review["id"] == @assignment["id"]}
              id="instance-save-review"
              class="notice space-top"
            >
              <h3>Review settings for this check</h3>
              <p>
                {measured_target(@assignment)} · {environment_name(@assignment)} · observed by {runner_label(
                  @assignment
                )}.
              </p>
              <p>
                This saves the complete parameter set for this check only. Unchanged values are pinned too; future rules and code defaults do not merge field by field. Saving does not mean activation, measurement or accepted discovery inventory.
              </p>
              <dl class="kv-list">
                <div :for={{key, value} <- Enum.sort(@instance_review["proposed_params"])} class="kv">
                  <dt>
                    {schema_label(@assignment, key)}<span :if={
                      get_in(@assignment, ["parameter_schema", "fields", key, "unit"])
                    }> ({get_in(@assignment, ["parameter_schema", "fields", key, "unit"])})</span>
                  </dt><dd>
                    {parameter_value(value)}
                    <strong :if={value != @instance_review["current_params"][key]}>Changed</strong>
                  </dd>
                </div>
              </dl>
              <button type="button" class="button" phx-click="cancel_instance_review">Back to editing</button>
              <button
                id="confirm-instance-save"
                class="button primary"
                phx-click="confirm_instance_save"
                phx-disable-with="Saving…"
              >Save reviewed settings</button>
            </section>
            <p
              :if={@feedback[@assignment["id"]]}
              id={"feedback-" <> @assignment["id"]}
              role="status"
              class="notice space-top"
            >
              {@feedback[@assignment["id"]]}
            </p>
            <div
              :if={@feedback[@assignment["id"]]}
              class="form-actions"
              id="configuration-saved-actions"
            >
              <.link :if={@return_to} navigate={@return_to} class="button primary">{return_label(
                @return_to,
                "Return to monitoring"
              )}</.link>
              <.link navigate="/configuration/history" class="button secondary">View configuration history</.link>
            </div>
            <details
              :if={source_check?(@assignment) && editable?(@assignment)}
              id="configuration-origin"
              class="parameter-intro space-top"
              phx-mounted={JS.ignore_attributes("open")}
            >
              <summary>Current settings, shared rules and defaults</summary>
              <p>
                <span :if={get_in(@assignment, ["configuration_origin", "kind"]) == "rule"}>From rule <.link navigate={
                  detail_path(
                    "/configuration/rules/" <> @assignment["configuration_origin"]["rule_id"],
                    @return_to
                  )
                }>{@assignment["configuration_origin"]["rule_name"]}</.link>.</span>
                <span :if={get_in(@assignment, ["configuration_origin", "kind"]) == "exception"}>From an instance exception. This check's complete parameter set takes precedence over matching rules.</span>
                <span :if={
                  get_in(@assignment, ["configuration_origin", "kind"]) not in ["rule", "exception"]
                }>Defaults from code. Matching rules can supply reusable settings.</span>
              </p>
              <ConfigurationValues.comparison
                assignment={@assignment}
                values={(@inspection || %{})["policy_values"] || %{}}
              />
              <details
                :if={is_map(@assignment["source_defaults"])}
                id="config-source-defaults"
                class="space-top"
                phx-mounted={JS.ignore_attributes("open")}
              >
                <summary>Defaults from code</summary><dl class="kv-list">
                  <div :for={{key, value} <- Enum.sort(@assignment["source_defaults"])} class="kv">
                    <dt>{schema_label(@assignment, key)}</dt><dd>{parameter_value(value)}</dd>
                  </div>
                </dl>
              </details>
              <ConfigurationValues.workflow />
            </details>
            <dl :if={!editable?(@assignment)} class="kv-list space-top">
              <div :for={{key, value} <- Enum.sort(@assignment["params"] || %{})} class="kv">
                <dt>{schema_label(@assignment, key)}</dt><dd>{parameter_value(value)}</dd>
              </div>
            </dl>
          </div>
        </section><aside class="stack">
          <section
            class="panel"
            id="configuration-results"
            tabindex="-1"
            aria-labelledby="configuration-results-heading"
          >
            <div class="panel-heading">
              <h2 id="configuration-results-heading">Results from this check</h2>
            </div><div class="panel-body">
              <ul class="result-links">
                <li :for={stream <- @assignment["streams"] || []}>
                  <.link navigate={detail_path("/checks/" <> stream["id"], @result_return_to)}>{label(
                    stream
                  )}</.link><span>{target_label(stream["target"])}</span><.badge value={
                    knowledge(stream)
                  } />
                </li>
              </ul>
              <p :if={(@assignment["streams"] || []) == []}>
                {Enum.join(@assignment["expected_keys"] || [], ", ")}
              </p>
              <p class="footnote space-top">
                These results share one execution and one parameter set. Their names, targets and membership are defined in code.
              </p>
              <.link navigate={"/resources/" <> @assignment["id"]} class="text-link space-top">Inspect shared execution and control history</.link>
            </div>
          </section>
          <details
            id="config-source-context"
            class="panel disclosure config-source-context"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Source, schedule &amp; technical details</summary>
            <.source_details assignment={@assignment} />
          </details>
        </aside>
      </div>
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
    </div>
    """
  end

  defp configuration_stage_hint("saved"), do: "Waiting for preparation"
  defp configuration_stage_hint("prepared"), do: "Waiting for activation"
  defp configuration_stage_hint("active"), do: "Waiting for measurement"
  defp configuration_stage_hint("measured"), do: "Complete evidence received"

  defp schema_fields(assigns) do
    ~H"""
    <ParameterForm.fields
      id_prefix={@assignment["id"]}
      schema={@assignment["parameter_schema"]}
      values={@draft.params}
      error={@error}
      error_id={"error-" <> @assignment["id"]}
    />
    """
  end

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

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DiscoveryConfigurationLive do
  use MondekWeb, :live_view
  alias Mondek.{ConfigurationRules, DiscoveryConfiguration, Inspection, Monitoring}

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    ParameterForm,
    PreviewDetail,
    PreviewLayouts
  }

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, 1_000)
    end

    {:ok,
     assign(socket,
       page_title: "Resource discovery",
       now: Monitoring.now(),
       context: nil,
       receipt: nil,
       error: nil,
       review: nil,
       reviewed_context: nil,
       proposal: nil,
       values: %{},
       draft_schema: %{},
       scope: "local",
       revision: nil,
       return_to: "/checks",
       manager_id: nil,
       subject_result_id: nil,
       owner_identity: nil,
       investigation_host: nil,
       investigation_params: %{},
       investigation_selection: "",
       investigation_page: false,
       investigation_active: false,
       investigation_heading: "discovery-config-heading",
       id: nil
     )}
  end

  def handle_params(params, uri, socket) do
    identity = {socket.assigns.live_action, params["id"]}
    same_entity = socket.assigns.owner_identity == identity
    local = URI.parse(uri)

    socket =
      assign(socket,
        id: params["id"],
        owner_identity: identity,
        return_to: BrowserNavigation.return_path(params["return_to"]) || "/checks",
        investigation_host: local.path <> if(local.query, do: "?" <> local.query, else: ""),
        investigation_params: params,
        investigation_selection: InvestigationTrail.selection(params),
        investigation_page: not is_nil(InvestigationTrail.promoted(params)),
        investigation_active: InvestigationTrail.resolve(params) != [],
        investigation_heading: InvestigationTrail.heading(params, "discovery-config-heading")
      )

    socket = refresh(socket)
    {:noreply, if(same_entity, do: socket, else: adopt_current(socket))}
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    now = Monitoring.now()

    if socket.assigns.live_action == :receipt do
      assign(socket,
        now: now,
        receipt: DiscoveryConfiguration.receipt(socket.assigns.id),
        context: nil,
        subject_result_id: nil
      )
    else
      context = DiscoveryConfiguration.context(socket.assigns.id)

      results =
        if context,
          do: Inspection.streams_for((context.resource || context.manager)["id"], now),
          else: []

      assign(socket,
        now: now,
        context: context,
        receipt: nil,
        subject_result_id: get_in(List.first(results) || %{}, ["id"])
      )
    end
  end

  defp adopt_current(socket) do
    manager = socket.assigns.context && socket.assigns.context.manager

    assign(socket,
      review: nil,
      reviewed_context: nil,
      proposal: nil,
      error: nil,
      manager_id: manager && manager["id"],
      revision: manager && manager["revision"],
      values: (manager && manager["params"]) || %{},
      draft_schema: (manager && manager["parameter_schema"]) || %{},
      scope: if(manager && exact_rule?(manager), do: "host", else: "local")
    )
  end

  def handle_event("recover", form, socket), do: edit(form, socket)

  def handle_event(_, _, %{assigns: %{investigation_active: true}} = socket),
    do: {:noreply, socket}

  def handle_event("edit", form, socket), do: edit(form, socket)

  def handle_event("toggle_resource", _, socket) do
    d = resource(socket.assigns.context)

    if shortcut?(d, socket.assigns.draft_schema) do
      toggle_resource(socket, d)
    else
      {:noreply,
       assign(socket,
         error: "This resource name cannot be represented by an exact selection shortcut.",
         review: nil
       )}
    end
  end

  def handle_event("review", _, %{assigns: %{context: nil}} = socket),
    do:
      {:noreply,
       assign(socket,
         error: "Discovery relationship unavailable. Reopen current settings before reviewing.",
         review: nil
       )}

  def handle_event("review", form, socket) do
    socket = refresh(socket)
    manager = socket.assigns.context && socket.assigns.context.manager

    result =
      with {:ok, draft} <- normalized_draft(form, socket.assigns),
           true <- is_map(manager),
           true <-
             manager["id"] == socket.assigns.manager_id &&
               draft.manager_id == socket.assigns.manager_id,
           true <-
             manager["revision"] == socket.assigns.revision &&
               draft.revision == socket.assigns.revision,
           true <- manager["parameter_schema"] == socket.assigns.draft_schema,
           {:ok, params} <- ParameterForm.parse(socket.assigns.draft_schema, draft.values) do
        if draft.scope == "host" do
          with {:ok, proposal} <- DiscoveryConfiguration.host_proposal(manager, params),
               {:ok, preview} <- ConfigurationRules.preview(proposal),
               do: {:ok, preview, proposal, draft}
        else
          with {:ok, preview} <-
                 ConfigurationRules.preview_instance(
                   manager["id"],
                   socket.assigns.revision,
                   params
                 ),
               do: {:ok, preview, nil, draft}
        end
      end

    case result do
      {:ok, preview, proposal, draft} ->
        {:noreply,
         assign(socket,
           review: preview,
           reviewed_context: socket.assigns.context,
           proposal: proposal,
           values: draft.values,
           scope: draft.scope,
           error: nil
         )}

      {:error, :malformed_draft} ->
        {:noreply, reject_draft(socket)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error(reason), review: nil, reviewed_context: nil)}

      _ ->
        {:noreply, assign(socket, error: error(:stale), review: nil, reviewed_context: nil)}
    end
  end

  def handle_event("save", _, %{assigns: %{context: nil}} = socket),
    do:
      {:noreply,
       assign(socket,
         error: "Discovery relationship changed. Reopen current settings and review again.",
         review: nil
       )}

  def handle_event("save", _, %{assigns: %{review: nil}} = socket),
    do: {:noreply, assign(socket, error: "Review this change before saving.")}

  def handle_event("save", _, socket) do
    socket = refresh(socket)

    result =
      if context_signature(socket.assigns.context) ==
           context_signature(socket.assigns.reviewed_context) do
        DiscoveryConfiguration.save(
          socket.assigns.reviewed_context,
          socket.assigns.scope,
          socket.assigns.review,
          socket.assigns.proposal
        )
      else
        {:error, :stale}
      end

    case result do
      {:ok, receipt} ->
        {:noreply, push_navigate(socket, to: "/configuration/discovery/changes/" <> receipt.id)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error(reason), review: nil, reviewed_context: nil)}
    end
  end

  def handle_event("back", _, socket),
    do: {:noreply, assign(socket, review: nil, reviewed_context: nil)}

  def handle_event("reload", _, socket), do: {:noreply, socket |> refresh() |> adopt_current()}
  def handle_event(_, _, socket), do: {:noreply, socket}

  defp edit(form, socket) do
    case normalized_draft(form, socket.assigns) do
      {:ok, draft} ->
        {:noreply,
         assign(socket,
           manager_id: draft.manager_id,
           revision: draft.revision,
           values: draft.values,
           scope: draft.scope,
           review: nil,
           reviewed_context: nil,
           proposal: nil,
           error: nil
         )}

      _ ->
        {:noreply, reject_draft(socket)}
    end
  end

  defp reject_draft(socket),
    do:
      assign(socket,
        error: "This draft could not be recovered. Reload current values and review again.",
        review: nil,
        reviewed_context: nil,
        proposal: nil
      )

  defp normalized_draft(form, assigns) when is_map(form) do
    fields = assigns.draft_schema["fields"] || %{}
    values = Map.get(form, "params", %{})

    # LiveView marks untouched inputs with empty _unused_ keys on change/recovery.
    values =
      if is_map(values) && map_size(values) <= 512 do
        Map.reject(values, fn
          {"_unused_" <> field = marker, ""} ->
            Map.has_key?(fields, field) && !Map.has_key?(fields, marker)

          _ ->
            false
        end)
      else
        values
      end

    manager_id = Map.get(form, "_manager_id", assigns.manager_id)
    scope = Map.get(form, "scope", assigns.scope)

    with true <-
           is_map(values) && map_size(values) <= 256 && Map.keys(values) -- Map.keys(fields) == [],
         true <- Enum.all?(values, fn {key, value} -> valid_draft_value?(fields[key], value) end),
         true <- byte_size(Jason.encode!(values)) <= 131_072,
         true <- scope in ["local", "host"],
         {:ok, manager_id} <- Ecto.UUID.cast(manager_id),
         {:ok, revision} <- draft_revision(Map.get(form, "_revision", assigns.revision)) do
      {:ok,
       %{
         values: Map.merge(assigns.values, values),
         manager_id: manager_id,
         revision: revision,
         scope: scope
       }}
    else
      _ -> {:error, :malformed_draft}
    end
  end

  defp normalized_draft(_, _), do: {:error, :malformed_draft}

  defp valid_draft_value?(%{"type" => type}, value) do
    case {type, value} do
      {_, text} when is_binary(text) -> String.valid?(text) && !String.contains?(text, <<0>>)
      {"boolean", boolean} when is_boolean(boolean) -> true
      {type, number} when type in ["integer", "number"] and is_number(number) -> true
      _ -> false
    end
  end

  defp valid_draft_value?(_, _), do: false

  defp draft_revision(value)
       when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807,
       do: {:ok, value}

  defp draft_revision(value) when is_binary(value) and byte_size(value) <= 20 do
    case Integer.parse(value) do
      {number, ""} -> draft_revision(number)
      _ -> :error
    end
  end

  defp draft_revision(_), do: :error

  def path(id, return_to \\ nil) do
    base = "/configuration/discovery/" <> URI.encode(id, &URI.char_unreserved?/1)

    case BrowserNavigation.return_path(return_to) do
      nil -> base
      origin -> base <> "?" <> URI.encode_query(%{"return_to" => origin})
    end
  end

  defp evidence_path(assigns, kind, id) do
    trail = InvestigationTrail.resolve(assigns.investigation_params)

    case InvestigationTrail.open(trail, {kind, id}) do
      {:ok, next} -> InvestigationTrail.path(assigns.investigation_host, next)
      _ -> assigns.investigation_host
    end
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        manager: assigns.context && assigns.context.manager,
        resource: resource(assigns.context),
        observer_count:
          if(assigns.context,
            do: DiscoveryConfiguration.observer_count(assigns.context.manager),
            else: 0
          ),
        target: target(assigns.context && assigns.context.manager)
      )

    reviewed_manager =
      if assigns.reviewed_context, do: assigns.reviewed_context.manager, else: assigns.manager

    assigns =
      assign(assigns,
        reviewed_manager: reviewed_manager,
        reviewed_target: target(reviewed_manager)
      )

    ~H"""
    <div
      id="discovery-config-shell"
      phx-hook="OverviewPanel"
      data-selection={@investigation_selection}
      data-panel-heading={@investigation_heading}
      data-panel-background=".preview-masthead,.preview-sidebar,.preview-skip"
    >
      <PreviewLayouts.app
        active={:configuration}
        page_title={@page_title}
        flash={@flash}
        main_class="discovery-configuration"
      >
        <div
          id="discovery-config-workflow"
          class="configuration-workspace"
          hidden={@investigation_page}
          inert={@investigation_active}
        >
          <section class="preview-list" aria-labelledby="discovery-config-heading">
            <header class="preview-heading">
              <h1 id="discovery-config-heading" class="pf-v6-c-title pf-m-2xl" tabindex="-1">
                {if @live_action == :receipt,
                  do: "Discovery change receipt",
                  else: "Resource discovery"}
              </h1><.link navigate={@return_to} class="pf-v6-c-button pf-m-link">Back to monitoring</.link>
            </header>
            <p :if={!@context && !@receipt} class="configuration-section-note">
              {if @live_action == :receipt,
                do: "This change receipt is not available.",
                else:
                  "Discovery relationship unavailable. No managing check is inferred from names or groups."}
            </p>
            <p
              :if={@error}
              role="alert"
              id="discovery-config-error"
              class="configuration-inline-feedback"
            >
              {@error}
            </p>
            <PreviewDetail.facts
              :if={@context}
              label="Discovery subject"
              class="discovery-config-subject"
            >
              <tr id="discovery-config-subject">
                <th scope="row">Monitored host</th><td>{@target["label"] || @target["key"]}</td>
              </tr>
              <tr>
                <th scope="row">Monitored environment</th><td>
                  {@manager["environment_label"] || @manager["environment"]}
                </td>
              </tr>
              <tr>
                <th scope="row">Observing runner</th><td>
                  <.link patch={evidence_path(assigns, "runner", @manager["runner_id"])}>{@manager[
                    "runner_label"
                  ] || @manager["runner_id"]}</.link>
                </td>
              </tr>
              <tr>
                <th scope="row">Current settings</th><td>{origin(@manager)}</td>
              </tr>
              <tr :if={@resource != %{}}>
                <th scope="row">Resource</th><td>
                  {@resource["resource_name"]}
                  <span class="preview-caption">{if @resource["origin"] == "required",
                    do: "Required by code",
                    else: "Automatically discovered"}</span>
                </td>
              </tr>
              <tr :if={@subject_result_id}>
                <th scope="row">Related evidence</th><td>
                  <.link
                    id="discovery-config-current-result"
                    data-overview-open
                    patch={evidence_path(assigns, "result", @subject_result_id)}
                  >View current result</.link>
                </td>
              </tr>
            </PreviewDetail.facts>
          </section>
          <%= if @context do %>
            <p
              :if={
                @manager["revision"] != @revision || @manager["id"] != @manager_id ||
                  @manager["parameter_schema"] != @draft_schema
              }
              class="configuration-inline-feedback"
              role="status"
            >
              Saved settings changed while you were editing. Your draft is retained.
              <button type="button" class="pf-v6-c-button pf-m-secondary" phx-click="reload">Reload current values</button>
            </p>
            <PreviewDetail.card
              hidden={@review != nil}
              inert={@review != nil}
              id="discovery-config-editor"
              title="Discovery settings"
              level={2}
            >
              <form
                id="discovery-config-form"
                phx-change="edit"
                phx-auto-recover="recover"
                phx-submit="review"
              >
                <input type="hidden" name="_revision" value={@revision} />
                <input type="hidden" name="_manager_id" value={@manager_id} />
                <div class="configuration-card-body">
                  <fieldset class="discovery-scope-picker">
                    <legend>1. Choose the scope</legend>
                    <p class="preview-caption">
                      Both options affect resource discovery for this exact host and environment. Other hosts on the observing runner are unaffected.
                    </p>
                    <div class="discovery-scope-options">
                      <label class={[
                        "discovery-scope-choice",
                        @scope == "local" && "discovery-scope-selected"
                      ]}><span><input
                        id="discovery-scope-local"
                        type="radio"
                        name="scope"
                        value="local"
                        checked={@scope == "local"}
                      /><strong>Only this discovery check</strong></span><small>One current observer, including resources this check discovers later. Does not follow a replacement observer.</small></label>
                      <label class={[
                        "discovery-scope-choice",
                        @scope == "host" && "discovery-scope-selected"
                      ]}><span><input
                        id="discovery-scope-host"
                        type="radio"
                        name="scope"
                        value="host"
                        checked={@scope == "host"}
                      /><strong>Host policy</strong></span><small>{@observer_count} current {if @observer_count ==
                                                                                                  1,
                                                                                                do:
                                                                                                  "observer",
                                                                                                else:
                                                                                                  "observers"}, plus future compatible observers of this exact host in this environment. Local overrides are reviewed separately.</small></label>
                    </div>
                  </fieldset>
                  <p
                    :if={@scope == "host" && @manager["instance_exception"]}
                    class="configuration-inline-feedback"
                  >
                    Local settings still take precedence. Host policy does not remove this check's override.
                  </p>
                  <div class="discovery-selection-values">
                    <h3>2. Set selection values</h3>
                    <div :if={shortcut?(@resource, @draft_schema)} class="discovery-resource-shortcut">
                      <button
                        id="toggle-discovered-resource"
                        type="button"
                        class="pf-v6-c-button pf-m-secondary"
                        phx-click="toggle_resource"
                      >{if excluded?(@values, @resource),
                        do: "Remove exact exclusion",
                        else: "Add exact exclusion"}: {@resource["resource_name"]}</button><p class="preview-caption">
                        This shortcut changes one exact-name exclusion. Other matching patterns still apply.
                      </p>
                    </div>
                    <p :if={@resource["origin"] == "required"} class="configuration-inline-feedback">
                      This resource is required by code. Discovery exclusions cannot remove it; change the monitoring project's declaration.
                    </p>
                    <ParameterForm.fields
                      id_prefix="discovery-param"
                      schema={@draft_schema}
                      values={@values}
                      error={@error}
                      error_id="discovery-config-error"
                    />
                    <p class="preview-caption">
                      The complete parameter set is saved together, including unchanged values. Later rules or defaults do not merge into it field by field.
                    </p>
                    <p :if={@scope == "host"} class="preview-caption">
                      A new runner can initially discover using code defaults until it adopts the host policy.
                    </p>
                  </div>
                  <div class="configuration-form-actions">
                    <span class="preview-caption">Review the affected checks and values before saving.</span><button
                      class="pf-v6-c-button pf-m-primary"
                      phx-disable-with="Reviewing…"
                    >Review change</button>
                  </div>
                </div>
              </form>
            </PreviewDetail.card>
            <PreviewDetail.card
              :if={@review}
              id="discovery-config-review"
              title="Review discovery settings"
              level={2}
              tabindex="-1"
              phx-mounted={Phoenix.LiveView.JS.focus(to: "#discovery-config-review")}
            >
              <PreviewDetail.facts label="Reviewed discovery scope">
                <tr>
                  <th scope="row">Monitored host</th><td>
                    {@reviewed_target["label"] || @reviewed_target["key"]}
                  </td>
                </tr>
                <tr>
                  <th scope="row">Environment</th><td>
                    {@reviewed_manager["environment_label"] || @reviewed_manager["environment"]}
                  </td>
                </tr>
                <tr>
                  <th scope="row">Applies to</th><td>
                    {if @scope == "host",
                      do: "Current and future compatible observers of this exact host",
                      else: "This discovery check only"}
                  </td>
                </tr>
              </PreviewDetail.facts>
              <table
                class="configuration-values-table discovery-config-values"
                aria-label="Reviewed discovery values"
              >
                <thead>
                  <tr>
                    <th scope="col">Parameter</th><th scope="col">Current value</th><th scope="col">
                      Proposed value
                    </th>
                  </tr>
                </thead><tbody>
                  <tr :for={{key, value} <- Enum.sort(review_values(@review, @proposal))}>
                    <th scope="row">
                      {ParameterForm.field_label(@reviewed_manager["parameter_schema"], key)}<span :if={
                        get_in(@reviewed_manager, ["parameter_schema", "fields", key, "unit"])
                      }> ({get_in(@reviewed_manager, ["parameter_schema", "fields", key, "unit"])})</span><span
                        :if={value != @reviewed_manager["params"][key]}
                        class="pf-v6-c-label pf-m-blue"
                      >Changed</span>
                    </th><td>{ParameterForm.input_value(@reviewed_manager["params"][key])}</td><td>
                      {ParameterForm.input_value(value)}
                    </td>
                  </tr>
                </tbody>
              </table>
              <%= if @scope == "host" do %>
                <PreviewDetail.facts label="Host policy effect">
                  <tr>
                    <th scope="row">Current checks</th><td>
                      {@review["counts"]["changed"]} change · {@review["counts"]["exceptions"] || 0} masked · {@review[
                        "counts"
                      ]["conflicts"]} conflicts
                    </td>
                  </tr>
                </PreviewDetail.facts>
                <table
                  :if={(@review["rows"] || []) != []}
                  class="pf-v6-c-table pf-m-compact preview-table discovery-policy-table"
                  aria-label="Checks reviewed for host policy"
                >
                  <thead class="pf-v6-c-table__thead">
                    <tr>
                      <th class="pf-v6-c-table__th" scope="col">Check / observer</th><th
                        class="pf-v6-c-table__th"
                        scope="col"
                      >
                        Effect
                      </th>
                    </tr>
                  </thead><tbody>
                    <tr :for={row <- @review["rows"] || []}>
                      <td class="pf-v6-c-table__td" data-label="Check">
                        <.link navigate={"/configuration/" <> row["id"]}>{row["label"]}</.link><span class="configuration-secondary preview-caption">{row[
                          "environment"
                        ]} · {observer_label(row["runner_id"])}</span>
                      </td><td class="pf-v6-c-table__td" data-label="Effect">
                        {if row["instance_exception"],
                          do: "Local override remains in force",
                          else: if(row["changed"], do: "Settings change", else: "Settings unchanged")}
                        <p :if={row["error"]} class="configuration-inline-feedback">{row["error"]}</p><div :for={
                          id <- row["rule_ids"] || []
                        }>
                          <.link navigate={"/configuration/rules/" <> id}>Inspect conflicting rule</.link>
                        </div><.link
                          :if={
                            get_in(row, ["origin", "kind"]) == "rule" &&
                              get_in(row, ["origin", "rule_id"]) !=
                                (@proposal["id"] || "00000000-0000-0000-0000-000000000000")
                          }
                          navigate={"/configuration/rules/" <> row["origin"]["rule_id"]}
                        >Inspect effective shared rule</.link>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <p :if={!@review["review_token"]} class="configuration-inline-feedback">
                  Resolve conflicting shared rules before saving, or choose only this discovery check. Priority is not raised automatically.
                </p>
                <p
                  :if={DiscoveryConfiguration.host_shadowed?(@review, @proposal)}
                  class="configuration-inline-feedback"
                >
                  Another shared rule remains effective. Inspect that rule or choose only this discovery check.
                </p>
                <p
                  :if={@review["total"] > length(@review["rows"] || [])}
                  class="configuration-section-note"
                >
                  Showing {length(@review["rows"])} of {@review["total"]} reviewed checks. Counts and save validation cover every match.
                </p>
              <% end %>
              <div class="configuration-card-body">
                <p class="preview-caption">
                  Saving is not retirement or measured recovery. The runner must activate the settings and publish a successful inventory; fresh measurements remain separate evidence.
                </p><div class="configuration-form-actions">
                  <button type="button" class="pf-v6-c-button pf-m-secondary" phx-click="back">Back to editing</button><button
                    :if={
                      @review["review_token"] &&
                        (@scope != "host" ||
                           !DiscoveryConfiguration.host_shadowed?(@review, @proposal))
                    }
                    id="save-discovery-change"
                    class="pf-v6-c-button pf-m-primary"
                    phx-click="save"
                    phx-disable-with="Saving…"
                  >Save reviewed change</button>
                </div>
              </div>
            </PreviewDetail.card>
          <% end %>
          <.receipt :if={@receipt} receipt={@receipt} host_assigns={assigns} />
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={nil}
          initial={[]}
          context={"discovery-settings:" <> to_string(@live_action) <> ":" <> @id}
          back={
            InvestigationTrail.path(@investigation_host, [], %{"surface" => nil, "page_entity" => nil})
          }
        />
      </PreviewLayouts.app>
    </div>
    """
  end

  defp receipt(assigns) do
    subject = assigns.receipt.change.resource["subject"] || %{}

    assigns =
      assign(assigns,
        subject: subject,
        subject_target: get_in(subject, ["outputs", Access.at(0), "target"]) || %{}
      )

    ~H"""
    <PreviewDetail.card
      id="discovery-change-receipt"
      title={if @receipt.historical?, do: "Earlier change receipt", else: "Saved discovery change"}
      level={2}
    >
      <PreviewDetail.facts label="Saved discovery change">
        <tr>
          <th scope="row">Monitored host</th><td>
            {@subject_target["label"] || @subject_target["key"] || "Not recorded"}
          </td>
        </tr>
        <tr>
          <th scope="row">Environment</th><td>
            {@subject["environment_label"] || @subject["environment"]}
          </td>
        </tr>
        <tr>
          <th scope="row">Saved at</th><td>
            <time datetime={DateTime.to_iso8601(@receipt.change.saved_at)}>{MondekWeb.EvidencePresentation.time(
              @receipt.change.saved_at
            )}</time>
          </td>
        </tr>
        <tr>
          <th scope="row">Scope</th><td>
            {if @receipt.change.scope == "host", do: "Host policy", else: "One discovery check"}
          </td>
        </tr>
        <tr>
          <th scope="row">Receipt ID</th><td>{@receipt.change.id}</td>
        </tr>
      </PreviewDetail.facts>
      <p class="configuration-section-note">
        This receipt records the saved change and its accepted inventory outcomes. Completed outcomes remain historical; current result health and freshness are separate.
      </p>
      <table class="configuration-values-table" aria-label="Saved discovery values">
        <thead>
          <tr>
            <th scope="col">Parameter</th><th scope="col">Saved value</th>
          </tr>
        </thead><tbody>
          <tr :for={{key, value} <- Enum.sort(@receipt.change.params)}>
            <th scope="row">{key}</th><td>{ParameterForm.input_value(value)}</td>
          </tr>
        </tbody>
      </table>
      <section
        :for={member <- @receipt.members}
        class="discovery-receipt-member"
        aria-labelledby={"discovery-receipt-member-" <> member.receipt["id"]}
      >
        <h3 id={"discovery-receipt-member-" <> member.receipt["id"]} class="preview-section-heading">
          {(member.assignment || %{})["runner_label"] || member.receipt["runner_id"]}
        </h3>
        <PreviewDetail.facts label="Observer discovery outcome">
          <tr>
            <th scope="row">Status</th><td>
              <span class={["pf-v6-c-label", status_tone(member.status)]}>{status_label(member.status)}</span><div class="preview-caption discovery-member-explanation">
                {status(member.status)}
              </div>
            </td>
          </tr>
          <tr>
            <th scope="row">Reviewed generation</th><td>{member.receipt["generation"]}</td>
          </tr>
          <tr :if={member.receipt["accepted_at"]}>
            <th scope="row">Inventory accepted</th><td>
              <time datetime={member.receipt["accepted_at"]}>{MondekWeb.EvidencePresentation.time(
                member.receipt["accepted_at"]
              )}</time>
            </td>
          </tr>
          <tr :if={
            member.status == "inventory_accepted" && !is_nil(member.receipt["resource_present"])
          }>
            <th scope="row">Resource membership</th><td>
              {if member.receipt["resource_present"],
                do:
                  "Included in the accepted inventory; its active result needs its own fresh evidence.",
                else:
                  "Administratively retired by the accepted inventory; historical failure evidence remains available."}
            </td>
          </tr>
          <tr :if={member.assignment}>
            <th scope="row">Current discovery measurement</th><td>
              {current_measurement(member.assignment)} Independent of the saved receipt and inventory acceptance.
            </td>
          </tr>
          <tr>
            <th scope="row">Related evidence</th><td>
              <.link
                :if={member.resource_stream_id}
                id={"discovery-receipt-result-" <> member.receipt["id"]}
                data-overview-open
                patch={evidence_path(@host_assigns, "result", member.resource_stream_id)}
              >Inspect resource results and history</.link>
              <span :if={member.resource_stream_id}> · </span><.link patch={
                evidence_path(@host_assigns, "runner", member.receipt["runner_id"])
              }>View runner</.link>
            </td>
          </tr>
          <tr>
            <th scope="row">Settings</th><td>
              <.link
                :if={member.status == "masked"}
                navigate={"/configuration/" <> member.receipt["id"] <> "?" <> URI.encode_query(%{"return_to" => "/configuration/discovery/changes/" <> @receipt.change.id})}
              >Review local override removal</.link><span :if={member.status == "masked"}> · </span><.link navigate={
                path(member.receipt["id"], "/configuration/discovery/changes/" <> @receipt.change.id)
              }>Inspect current discovery settings</.link>
            </td>
          </tr>
        </PreviewDetail.facts>
      </section>
    </PreviewDetail.card>
    """
  end

  defp current_measurement(assignment) do
    cond do
      assignment["retired"] ->
        "Discovery check retired; retained measurements are historical."

      assignment["desired_generation"] &&
          assignment["observed_generation"] == assignment["desired_generation"] ->
        "Current desired generation measured; inspect results for health and freshness."

      true ->
        "No measurement of the current desired generation yet."
    end
  end

  defp status_label("inventory_accepted"), do: "Inventory accepted"
  defp status_label("refresh_failed"), do: "Scan failed"
  defp status_label("masked"), do: "Local override"
  defp status_label("superseded"), do: "Superseded"
  defp status_label("activation_pending"), do: "Awaiting activation"
  defp status_label(_), do: "Awaiting inventory"

  defp status_tone("inventory_accepted"), do: "pf-m-green"
  defp status_tone(status) when status in ~w(refresh_failed masked), do: "pf-m-orange"
  defp status_tone(_), do: ""

  defp context_signature(nil), do: nil

  defp context_signature(context),
    do: {
      Map.take(
        context.manager,
        ~w(id revision source_id source_key source_revision parameter_contract parameter_schema retired)
      ),
      Map.take(context.resource || %{}, ~w(id source_id source_key discovery retired_at))
    }

  defp observer_label(id) do
    case Mondek.Repo.get(Mondek.Runner, id) do
      nil -> id
      runner -> runner.label || id
    end
  end

  defp resource(nil), do: %{}
  defp resource(%{resource: nil}), do: %{}
  defp resource(context), do: context.resource["discovery"] || %{}
  defp target(nil), do: %{}
  defp target(manager), do: get_in(manager, ["outputs", Access.at(0), "target"]) || %{}

  defp origin(manager) do
    case manager["configuration_origin"]["kind"] do
      "exception" -> "local override for this discovery check"
      "rule" -> "shared rule " <> (manager["configuration_origin"]["rule_name"] || "")
      _ -> "defaults from code"
    end
  end

  defp exact_rule?(manager) do
    case DiscoveryConfiguration.host_proposal(manager, manager["params"]) do
      {:ok, proposal} -> not is_nil(proposal["id"])
      _ -> false
    end
  end

  defp toggle_resource(socket, d) do
    field = d["resource_kind"] <> "_exclude"
    pattern = exact_pattern(d["resource_name"])
    patterns = split(socket.assigns.values[field])

    patterns =
      if pattern in patterns, do: List.delete(patterns, pattern), else: patterns ++ [pattern]

    {:noreply,
     assign(socket,
       values: Map.put(socket.assigns.values, field, Enum.join(patterns, ",")),
       review: nil
     )}
  end

  defp shortcut?(d, schema),
    do:
      (get_in(schema, ["fields", to_string(d["resource_kind"]) <> "_exclude", "type"]) == "string" &&
         d["origin"] == "discovered") and is_binary(d["resource_name"]) and
        String.trim(d["resource_name"]) == d["resource_name"] and
        not String.contains?(d["resource_name"], ",") and
        byte_size(exact_pattern(d["resource_name"])) <= 256

  defp split(value), do: String.split(value || "", ",", trim: true) |> Enum.map(&String.trim/1)

  defp exact_pattern(value),
    do:
      value
      |> String.codepoints()
      |> Enum.map_join(fn c ->
        case c do
          "[" -> "[[]"
          "]" -> "[]]"
          "*" -> "[*]"
          "?" -> "[?]"
          _ -> c
        end
      end)

  defp excluded?(values, d),
    do: exact_pattern(d["resource_name"]) in split(values[d["resource_kind"] <> "_exclude"])

  defp review_values(review, proposal), do: review["proposed_params"] || proposal["params"]
  defp status("inventory_accepted"), do: "Successful inventory accepted for the reviewed settings"

  defp status("refresh_failed"),
    do:
      "Inventory refresh failed; previous monitoring is retained. Waiting for a successful retry."

  defp status("masked"),
    do: "Local override blocks this host policy. Review removing the override separately."

  defp status("superseded"), do: "Superseded or retired; this change is not confirmed completed."

  defp status("activation_pending"),
    do: "Waiting for runner activation; a disconnected runner cannot apply settings yet."

  defp status(_), do: "Settings active; waiting for a successful inventory for these settings."
  defp error({:invalid, message}), do: message
  defp error({:conflict, message}), do: message

  defp error(reason) when reason in [:stale, :review_expired, :review_changed],
    do:
      "Settings or policy changed after review, or the review expired. Reload current values and review again."

  defp error(_),
    do: "The change could not be reviewed or saved. Inspect current settings and try again."
end

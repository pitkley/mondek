# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationRulesLive do
  use MondekWeb, :live_view

  alias Mondek.{ConfigurationRules, Monitoring}

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    PreviewDetail,
    PreviewFilters,
    PreviewLayouts,
    PreviewPagination,
    ScalarFilterPicker
  }

  alias MondekWeb.ParameterForm
  alias MondekWeb.InvestigationNavigation

  @filter_fields [
    {"enabled", "Status", "info"},
    {"ownership", "Managed by", "shield"},
    {"source_id", "Source", "code"}
  ]
  @status_choices [{"enabled", "Enabled"}, {"disabled", "Disabled"}]
  @ownership_choices [{"operator", "Operator"}, {"project", "Project"}]

  @proposal_fields ~w(id revision name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params)
  @editable_fields ~w(name environment target_kind target_key priority enabled)

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()

    if connected?(socket) do
      Process.send_after(self(), :tick, 2_000)
    end

    {:ok,
     assign(socket,
       navigation_counts: Mondek.Inspection.navigation_counts(now),
       now: now,
       page_title: "Configuration rules",
       return_to: nil,
       listing: %{},
       rule: nil,
       proposal: nil,
       preview: nil,
       review_token: nil,
       error: nil,
       notice: nil,
       schema_search: "",
       schema_candidates: [],
       groups: %{},
       group_search: "",
       scope_choices: %{},
       seed_check_id: nil,
       environment_scope: "all",
       target_scope: "all",
       saved_rule_id: nil,
       saved_rule_revision: nil,
       saved_receipts: nil,
       saved_progress: nil,
       saved_page: 1,
       page: 1,
       preview_page: 1,
       route_identity: nil,
       filters: %{},
       filter_picker: nil,
       investigation_params: %{},
       investigation_host: "/configuration/rules",
       investigation_open: false,
       investigation_page: false
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    local = URI.parse(uri)
    identity = {socket.assigns.live_action, params["id"], params["check_id"], params["group"]}
    same = identity == socket.assigns.route_identity

    socket =
      assign(socket,
        route_identity: identity,
        controller_url:
          URI.to_string(%URI{scheme: local.scheme, host: local.host, port: local.port}),
        investigation_params: params,
        investigation_host: local.path <> if(local.query, do: "?" <> local.query, else: ""),
        investigation_open: InvestigationTrail.resolve(params) != [],
        investigation_page: !is_nil(InvestigationTrail.promoted(params)),
        filters: list_filters(params),
        filter_picker: nil,
        return_to: BrowserNavigation.return_path(params["return_to"])
      )

    if same && socket.assigns.proposal do
      socket =
        if params["schema_from"] && params["schema_from"] != socket.assigns[:schema_from],
          do: refresh_schema(socket, params["schema_from"]),
          else: socket

      schema_search = ScalarFilterPicker.text(params["schema_search"])

      socket =
        if socket.assigns.rule && schema_search != socket.assigns.schema_search,
          do:
            assign(socket,
              schema_search: schema_search,
              schema_candidates:
                ConfigurationRules.schema_candidates(socket.assigns.rule["id"], schema_search)
            ),
          else: socket

      {:noreply, assign(socket, schema_from: params["schema_from"])}
    else
      load_route(params, socket)
    end
  end

  defp load_route(params, socket) do
    socket =
      assign(socket,
        error: nil,
        notice: nil,
        preview: nil,
        review_token: nil,
        schema_from: params["schema_from"],
        return_to: BrowserNavigation.return_path(params["return_to"])
      )

    socket =
      if params["id"] == socket.assigns.saved_rule_id,
        do: socket,
        else:
          assign(socket,
            saved_rule_id: nil,
            saved_receipts: nil,
            saved_progress: nil,
            saved_page: 1
          )

    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(page: positive_integer(params["page"]), rule: nil, proposal: nil)
         |> refresh_list()}

      :new ->
        if params["check_id"] do
          socket = load_proposal(socket, ConfigurationRules.seed(params["check_id"]))

          socket =
            if params["group"] == "1" && socket.assigns.proposal do
              assign(socket,
                proposal:
                  Map.merge(socket.assigns.proposal, %{
                    "environment" => nil,
                    "target_kind" => nil,
                    "target_key" => nil
                  })
              )
            else
              socket
            end

          {:noreply, socket |> assign(seed_check_id: params["check_id"]) |> assign_scope()}
        else
          search = ScalarFilterPicker.text(params["search"])

          {:noreply,
           assign(socket,
             rule: nil,
             proposal: nil,
             seed_check_id: nil,
             group_search: search,
             groups: ConfigurationRules.groups(search, positive_integer(params["page"]))
           )}
        end

      :edit ->
        case ConfigurationRules.get(params["id"]) do
          {:ok, rule} ->
            socket =
              assign(socket,
                rule: rule,
                proposal: Map.take(rule, @proposal_fields),
                schema_search: ScalarFilterPicker.text(params["schema_search"]),
                schema_candidates:
                  ConfigurationRules.schema_candidates(
                    rule["id"],
                    ScalarFilterPicker.text(params["schema_search"])
                  )
              )

            socket =
              if params["schema_from"],
                do: refresh_schema(socket, params["schema_from"]),
                else: socket

            {:noreply, assign_scope(socket)}

          {:error, reason} ->
            {:noreply, assign(socket, rule: nil, proposal: nil, error: error_message(reason))}
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

    socket =
      cond do
        socket.assigns.live_action == :index ->
          refresh_list(socket)

        socket.assigns.rule ->
          case ConfigurationRules.get(socket.assigns.rule["id"]) do
            {:ok, current} ->
              assign(socket, rule: current)

            {:error, :not_found} ->
              assign(socket,
                rule: nil,
                proposal: nil,
                preview: nil,
                review_token: nil,
                notice:
                  "This rule was removed. Existing configuration history retains its original values."
              )
          end

        true ->
          socket
      end

    {:noreply, refresh_saved_progress(socket)}
  end

  @impl true
  def handle_event(event, _form, %{assigns: %{investigation_open: true}} = socket)
      when event in ~w(edit preview save back refresh_schema), do: {:noreply, socket}

  def handle_event("edit", form, socket) do
    {:noreply,
     socket
     |> keep_draft(form)
     |> assign(preview: nil, review_token: nil, error: nil, notice: nil)}
  end

  def handle_event("group_search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to: group_path(ScalarFilterPicker.text(search), 1, socket.assigns.return_to)
     )}
  end

  def handle_event("saved_page", %{"page" => page}, socket),
    do:
      {:noreply, socket |> assign(saved_page: positive_integer(page)) |> refresh_saved_progress()}

  def handle_event("recover_saved", form, socket) do
    with encoded when is_binary(encoded) and byte_size(encoded) <= 180_000 <-
           form["_saved_change"],
         {:ok, %{"rule_id" => rule_id, "rule_revision" => revision, "receipts" => receipts}} <-
           Jason.decode(encoded),
         true <- is_integer(revision) && revision in 1..2_147_483_647,
         true <- rule_id == (socket.assigns.rule || %{})["id"],
         true <- is_list(receipts) && length(receipts) <= 512,
         true <- Enum.all?(receipts, &(is_map(&1) && &1["changed"] == true)) do
      {:noreply,
       socket
       |> assign(
         saved_rule_id: rule_id,
         saved_rule_revision: revision,
         saved_receipts: receipts,
         saved_page: 1
       )
       |> refresh_saved_progress()}
    else
      _ ->
        {:noreply, assign(socket, saved_rule_id: nil, saved_receipts: nil, saved_progress: nil)}
    end
  end

  def handle_event("recover", form, socket) do
    with encoded when is_binary(encoded) and byte_size(encoded) <= 100_000 <- form["_proposal"],
         {:ok, captured} when is_map(captured) <- Jason.decode(encoded),
         true <- captured["id"] == (socket.assigns.proposal || %{})["id"],
         true <- recoverable_proposal?(captured) do
      {:noreply,
       socket
       |> assign(proposal: Map.take(captured, @proposal_fields))
       |> assign_scope()
       |> assign(
         environment_scope:
           if(form["_environment_scope"] in ["all", "one"],
             do: form["_environment_scope"],
             else: if(captured["environment"] in [nil, ""], do: "all", else: "one")
           ),
         target_scope:
           if(form["_target_scope"] in ["all", "one"],
             do: form["_target_scope"],
             else: if(captured["target_key"] in [nil, ""], do: "all", else: "one")
           )
       )
       |> keep_draft(form)
       |> assign(
         preview: nil,
         review_token: nil,
         error: nil,
         notice:
           "Draft restored. Preview again before saving; the reviewed revision is preserved."
       )}
    else
      _ ->
        {:noreply,
         assign(socket, error: "The saved draft could not be restored. Reload this rule.")}
    end
  end

  def handle_event("preview", form, socket) do
    socket = keep_draft(socket, form)

    with :ok <- validate_scope(socket),
         {:ok, proposal} <- typed_proposal(socket.assigns.proposal),
         {:ok, preview} <- ConfigurationRules.preview(proposal) do
      {:noreply,
       assign(socket,
         proposal: preview["proposal"] || proposal,
         preview: preview,
         review_token: preview["review_token"],
         preview_page: 1,
         error: nil,
         notice: nil
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason), review_token: nil)}
    end
  end

  def handle_event("save", form, socket) do
    with token when is_binary(token) <- socket.assigns.review_token,
         true <- token == form["_review_token"],
         {:ok, saved} <- ConfigurationRules.apply(token, socket.assigns.proposal) do
      inspected_rule =
        case ConfigurationRules.get(saved["rule"]["id"]) do
          {:ok, rule} -> rule
          {:error, :not_found} -> saved["rule"]
        end

      {:noreply,
       socket
       |> assign(
         rule: inspected_rule,
         proposal: Map.take(saved["rule"], @proposal_fields),
         preview: nil,
         review_token: nil,
         error: nil,
         schema_from: nil,
         saved_rule_id: saved["rule"]["id"],
         saved_rule_revision: saved["rule"]["revision"],
         saved_receipts: Enum.filter(saved["receipts"], & &1["changed"]),
         saved_page: 1
       )
       |> assign_scope()
       |> refresh_saved_progress()
       |> put_flash(
         :info,
         "Rule saved. #{saved["changed_count"]} checks received a new desired configuration. Runners must still measure it."
       )
       |> push_patch(
         to:
           InvestigationNavigation.detail_path(
             rule_path(saved["rule"]["id"]),
             socket.assigns.return_to
           )
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason), review_token: nil, preview: nil)}

      _ ->
        {:noreply, assign(socket, error: "Preview this draft before saving.", review_token: nil)}
    end
  end

  def handle_event("back", _form, socket),
    do: {:noreply, assign(socket, preview: nil, review_token: nil, error: nil)}

  def handle_event("preview_page", %{"page" => page}, socket) do
    with true <- socket.assigns.preview != nil,
         {:ok, preview} <-
           ConfigurationRules.preview(socket.assigns.proposal, positive_integer(page)) do
      if preview["fingerprint"] == socket.assigns.preview["fingerprint"] do
        # Pagination does not renew the original review or its expiry.
        {:noreply,
         assign(socket, preview: preview, preview_page: positive_integer(page), error: nil)}
      else
        {:noreply, assign(socket, preview: nil, review_token: nil, error: error_message(:stale))}
      end
    else
      {:error, reason} -> {:noreply, assign(socket, error: error_message(reason))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("refresh_schema", %{"check_id" => id}, socket),
    do: {:noreply, refresh_schema(socket, id)}

  def handle_event("schema_search", %{"search" => search}, socket) do
    search = ScalarFilterPicker.text(search)
    candidates = ConfigurationRules.schema_candidates(socket.assigns.rule["id"], search)
    socket = assign(socket, schema_search: search, schema_candidates: candidates)

    {:noreply,
     push_patch(socket,
       to:
         InvestigationTrail.path(
           socket.assigns.investigation_host,
           InvestigationTrail.resolve(socket.assigns.investigation_params),
           %{"schema_search" => if(search != "", do: search)}
         )
     )}
  end

  def handle_event("search", %{"search" => value}, socket) do
    search = ScalarFilterPicker.text(value)

    cond do
      socket.assigns.live_action == :index ->
        patch_list(socket, %{"search" => search})

      socket.assigns.proposal == nil ->
        {:noreply, push_patch(socket, to: group_path(search, 1, socket.assigns.return_to))}

      true ->
        handle_event("schema_search", %{"search" => search}, socket)
    end
  end

  def handle_event("filter_open", %{"field" => field}, socket) do
    draft =
      ScalarFilterPicker.draft(
        @filter_fields,
        &choices(&1, socket.assigns.listing),
        field,
        "",
        empty_values(field)
      )

    if draft do
      label =
        if socket.assigns.filters[field],
          do:
            ScalarFilterPicker.label(
              choices(field, socket.assigns.listing),
              socket.assigns.filters[field]
            ),
          else: ""

      {:noreply, assign(socket, filter_picker: %{draft | value: label})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket),
    do: {:noreply, picker_ready(socket)}

  def handle_event("filter_close", _, socket), do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do: patch_list(picker_ready(socket), %{field => ""})

  def handle_event("filter_remove", %{"field" => field}, socket) do
    cond do
      field == "search" ->
        handle_event("search", %{"search" => ""}, picker_ready(socket))

      List.keymember?(@filter_fields, field, 0) ->
        patch_list(picker_ready(socket), %{field => ""})

      true ->
        {:noreply, socket}
    end
  end

  def handle_event(
        event,
        %{"search" => query},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ~w(filter_query filter_first) do
    draft =
      ScalarFilterPicker.draft(
        @filter_fields,
        &choices(&1, socket.assigns.listing),
        field,
        query,
        empty_values(field)
      )

    case {event, draft.options} do
      {"filter_first", [option | _]} -> patch_list(picker_ready(socket), %{field => option.key})
      _ -> {:noreply, assign(socket, filter_picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_list(picker_ready(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="configuration-rules-shell"
      phx-hook="OverviewPanel"
      data-selection={InvestigationTrail.selection(@investigation_params)}
      data-panel-heading={InvestigationTrail.heading(@investigation_params, "rules-heading")}
      data-panel-background=".preview-masthead,.preview-sidebar,#rules-workflow"
    >
      <PreviewLayouts.navigation active={:configuration} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <div
          id="rules-workflow"
          class="configuration-workspace rules-workspace"
          hidden={@investigation_page}
          inert={@investigation_open}
        >
          <section class="preview-list" aria-labelledby="rules-heading">
            <header class="preview-heading">
              <h1 id="rules-heading" tabindex="-1" class="pf-v6-c-title pf-m-2xl">
                {page_title(@live_action, @rule)}
              </h1>
              <div class="configuration-actions">
                <.link
                  navigate={
                    @return_to ||
                      if(@live_action == :index, do: "/configuration", else: "/configuration/rules")
                  }
                  class="pf-v6-c-button pf-m-link"
                >{if @return_to,
                  do: "Back to investigation",
                  else: if(@live_action == :index, do: "Configuration", else: "All rules")}</.link>
                <.link navigate="/configuration/history" class="pf-v6-c-button pf-m-link">History &amp; Git</.link>
              </div>
            </header>
            <p class="configuration-section-note">
              Rules apply complete settings to current and future compatible checks. Instance exceptions take precedence.
            </p>
            <p
              :for={key <- [:info, :error]}
              :if={Phoenix.Flash.get(@flash, key)}
              role={if key == :error, do: "alert", else: "status"}
              class="ui-feedback"
            >
              {Phoenix.Flash.get(@flash, key)}
            </p>
            <div :if={@error || @notice} class="rules-feedback">
              <p :if={@error} id="rule-error" role="alert">{@error}</p>
              <.link
                :if={@error && @rule}
                navigate={InvestigationNavigation.detail_path(rule_path(@rule["id"]), @return_to)}
                class="pf-v6-c-button pf-m-secondary"
                id="reload-rule"
              >Reload saved rule and discard draft</.link>
              <p :if={@notice} id="rule-notice" role="status">{@notice}</p>
            </div>
            <.rules_list
              :if={@live_action == :index}
              listing={@listing}
              filters={@filters}
              picker={@filter_picker}
            />
            <.group_chooser
              :if={@live_action == :new && @proposal == nil}
              groups={@groups}
              search={@group_search}
              picker={@filter_picker}
              return_to={@return_to}
            />
          </section>
          <.saved_change
            :if={@rule}
            rule={@rule}
            receipts={@saved_receipts}
            revision={@saved_rule_revision}
            progress={@saved_progress}
            page={@saved_page}
          />
          <PreviewDetail.card
            :if={@live_action == :edit && @proposal == nil}
            id="rule-unavailable"
            title="Rule unavailable"
            level={2}
          >
            <p class="configuration-section-note">No retained rule is available at this address.</p><div class="configuration-card-body">
              <.link navigate="/configuration/rules">Browse saved rules</.link>
            </div>
          </PreviewDetail.card>
          <.rule_form
            :if={@proposal && @preview == nil}
            proposal={@proposal}
            rule={@rule}
            error={@error}
            schema_candidates={@schema_candidates}
            schema_search={@schema_search}
            scope_choices={@scope_choices}
            environment_scope={@environment_scope}
            target_scope={@target_scope}
            seed_check_id={@seed_check_id}
            picker={@filter_picker}
            host={@investigation_host}
          />
          <.rule_preview
            :if={@preview}
            preview={@preview}
            proposal={@proposal}
            token={@review_token}
            page={@preview_page}
            environment_scope={@environment_scope}
            target_scope={@target_scope}
            host={@investigation_host}
          />
          <.managed_rule :if={managed?(@rule)} rule={@rule} />
          <.diagnostics :if={@rule} entries={@rule["diagnostics"] || []} />
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={nil}
          initial={[]}
          context={"rules:#{inspect(@route_identity)}"}
          controller_url={@controller_url}
          back={
            InvestigationTrail.path(@investigation_host, [], %{"surface" => nil, "page_entity" => nil})
          }
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp rules_list(assigns) do
    assigns =
      assign(assigns,
        fields: @filter_fields,
        chips:
          ScalarFilterPicker.chips(
            @filter_fields,
            assigns.filters,
            &choices(&1, assigns.listing),
            &empty_values/1
          )
      )

    ~H"""
    <div class="configuration-filter-toolbar">
      <PreviewFilters.filter_picker
        picker={@picker}
        chips={@chips}
        fields={@fields}
        search={@filters["search"]}
        remove={fn field -> list_path(Map.delete(@filters, field)) end}
        clear_search={list_path(Map.delete(@filters, "search"))}
        form_label="Filter configuration rules"
        label="Search rules"
        placeholder="Search or filter rules"
      />
    </div>
    <section class="preview-table-group" aria-labelledby="saved-rules-heading">
      <h2 id="saved-rules-heading" class="preview-section-heading">
        Saved rules
        <span class="pf-v6-c-badge pf-m-read">{@listing["total"]}</span><.link
          navigate={
            InvestigationNavigation.detail_path(
              "/configuration/rules/new",
              list_path(Map.put(@filters, "page", @listing["page"]))
            )
          }
          id="new-shared-rule"
          class="pf-v6-c-button pf-m-primary"
        >New shared rule</.link>
      </h2>
      <p :if={@listing["rules"] == []} class="preview-empty">
        No configuration rules match this view. Rules remain saved when their checks disappear.
      </p>
      <table
        :if={@listing["rules"] != []}
        class="inventory-table rules-list-table"
        aria-label="Saved configuration rules"
      >
        <thead>
          <tr>
            <th scope="col">Rule</th><th scope="col">Matches</th><th scope="col">Scope</th><th scope="col">
              Priority
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={rule <- @listing["rules"]} id={"rule-row-" <> rule["id"]}>
            <td data-label="Rule">
              <.link navigate={
                InvestigationNavigation.detail_path(
                  rule_path(rule["id"]),
                  list_path(Map.put(@filters, "page", @listing["page"]))
                )
              }>{rule["name"]}</.link><div class="sub">
                <span class={["badge", rule["enabled"] && "good"]}>{if rule["enabled"],
                  do: "Enabled",
                  else: "Disabled"}</span><span :if={managed?(rule)}> · Project {rule[
                  "managed_project"
                ]} · {rule["managed_key"]}</span>
              </div>
            </td>
            <td data-label="Matches">
              {quantity(rule["match_count"], "current check")}
              <div
                :if={(rule["conflict_count"] || 0) > 0}
                class="sub"
              >
                {rule["conflict_count"]} need attention
              </div><div :if={(rule["match_count"] || 0) == 0 && rule["enabled"]} class="sub">
                Waiting for compatible checks
              </div>
            </td>
            <td data-label="Scope">
              {scope_label(rule)}
              <div class="sub">{rule["source_id"]} · {rule["parameter_contract"]}</div>
            </td>
            <td data-label="Priority">{rule["priority"]}</td>
          </tr>
        </tbody>
      </table>
      <PreviewPagination.pagination
        page={@listing["page"]}
        size={@listing["page_size"]}
        total={@listing["total"]}
        label="Rule pages"
        url={fn page -> list_path(Map.put(@filters, "page", page)) end}
      />
    </section>
    <details class="rules-help">
      <summary>How settings are chosen</summary><p>
        An instance exception wins first. Otherwise the matching enabled rule with the highest priority supplies the complete parameter set. Equal highest priorities conflict. Without a rule, defaults from code apply.
      </p>
    </details>
    <.diagnostics entries={@listing["diagnostics"] || []} />
    """
  end

  defp managed?(rule), do: is_map(rule) && is_binary(rule["managed_project"])

  defp saved_change(assigns) do
    ~H"""
    <form id="rule-saved-change-recovery" phx-change="recover_saved" phx-auto-recover="recover_saved">
      <input
        type="hidden"
        name="_saved_change"
        value={
          Jason.encode!(%{
            "rule_id" => @rule["id"],
            "rule_revision" => @revision,
            "receipts" => @receipts
          })
        }
      />
    </form>
    <PreviewDetail.card
      :if={is_list(@receipts)}
      id="rule-saved-change"
      title="Adoption of this saved change"
      level={2}
    >
      <PreviewDetail.facts label="Saved rule adoption">
        <tr>
          <th scope="row">Rule revision</th><td>{@revision}</td>
        </tr>
        <tr>
          <th scope="row">Progress</th><td>
            <span :if={@progress} id="rule-saved-change-summary" role="status">{Enum.map_join(
              Enum.filter(@progress["counts"], fn {_, count} -> count > 0 end),
              " · ",
              fn {stage, count} -> "#{count} #{saved_stage(stage)}" end
            )}</span><span :if={!@progress}>No check received a new desired version. Enabled rules still apply to future compatible checks.</span>
          </td>
        </tr>
      </PreviewDetail.facts>
      <details
        :if={@progress}
        id="rule-saved-change-details"
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
      >
        <summary>Inspect {@progress["total"]} saved check versions</summary>
        <table class="inventory-table" aria-label="Saved configuration versions">
          <thead>
            <tr>
              <th scope="col">Scheduled check</th><th scope="col">Saved version</th><th scope="col">
                Adoption
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @progress["rows"]} id={"rule-saved-" <> row["id"]}>
              <td data-label="Scheduled check">
                <.link navigate={"/configuration/" <> row["id"]}>{row["label"]}</.link><div class="sub">
                  {row["runner_label"] || row["runner_id"]}
                </div>
              </td>
              <td data-label="Saved version">{row["target_generation"]}</td>
              <td data-label="Adoption">{saved_stage(row["stage"])}</td>
            </tr>
          </tbody>
        </table>
        <PreviewPagination.pagination
          page={@page}
          size={@progress["page_size"] || 25}
          total={@progress["total"]}
          label="Saved change pages"
          event="saved_page"
        />
      </details>
      <p class="configuration-section-note">
        Measured means this version produced complete evidence at least once; inspect current freshness separately. Superseded does not prove that the saved version ran.
      </p>
    </PreviewDetail.card>
    """
  end

  defp refresh_saved_progress(%{assigns: %{saved_receipts: receipts}} = socket)
       when receipts in [nil, []], do: assign(socket, saved_progress: nil)

  defp refresh_saved_progress(socket) do
    case Monitoring.bulk_configuration_status(
           socket.assigns.saved_receipts,
           socket.assigns.saved_page
         ) do
      {:ok, progress} -> assign(socket, saved_progress: progress, saved_page: progress["page"])
      {:error, _} -> assign(socket, saved_receipts: nil, saved_progress: nil, saved_rule_id: nil)
    end
  end

  defp saved_stage("pending"), do: "waiting for runner"
  defp saved_stage("prepared"), do: "prepared"
  defp saved_stage("active"), do: "active; awaiting measurement"
  defp saved_stage("measured"), do: "measured"
  defp saved_stage("superseded"), do: "superseded"
  defp saved_stage("retired"), do: "retired"
  defp saved_stage("missing"), do: "no longer retained"

  defp group_chooser(assigns) do
    ~H"""
    <div id="configuration-group-chooser">
      <p class="configuration-section-note">
        Choose settings declared compatible by their source, then choose environments and targets. Similar field names do not establish compatibility.
      </p>
      <div class="configuration-filter-toolbar">
        <PreviewFilters.filter_picker
          picker={@picker}
          chips={[]}
          fields={[]}
          search={if @search != "", do: @search}
          remove={nil}
          clear_search={group_path("", 1, @return_to)}
          form_label="Find compatible settings"
          label="Find check settings"
          placeholder="Search check names, settings or source"
        />
      </div>
      <section class="preview-table-group" aria-label="Compatible settings">
        <h2 class="preview-section-heading">
          Compatible settings <span class="pf-v6-c-badge pf-m-read">{@groups["total"] || 0}</span>
        </h2>
        <div :if={(@groups["groups"] || []) == []} class="preview-empty">
          <p>
            No matching shared settings. Checks must delegate settings and declare their shared meaning in code.
          </p><.link navigate="/configuration">Choose a scheduled check</.link>
        </div>
        <table
          :if={(@groups["groups"] || []) != []}
          class="inventory-table rules-group-table"
          aria-label="Compatible parameter groups"
        >
          <thead>
            <tr>
              <th scope="col">Check settings</th><th scope="col">Parameters</th><th scope="col">
                Current inventory
              </th><th scope="col">Source / contract</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={group <- @groups["groups"] || []} id={"settings-group-" <> group["check_id"]}>
              <td data-label="Check settings">
                <.link navigate={"/configuration/rules/new?" <> URI.encode_query(Map.reject(%{"check_id" => group["check_id"], "group" => "1", "return_to" => @return_to}, fn {_, value} -> is_nil(value) end))}>Use settings from {group[
                  "label"
                ]}</.link><div :if={group["label_count"] > 1} class="sub">
                  And {quantity(group["label_count"] - 1, "other check name")}
                </div>
              </td>
              <td data-label="Parameters">{Enum.map_join(group["fields"], ", ", & &1["label"])}</td>
              <td data-label="Current inventory">
                {quantity(group["check_count"], "scheduled check")}
                <div class="sub">
                  {quantity(group["result_count"], "result")} · {quantity(
                    group["environment_count"],
                    "monitored environment"
                  )}
                </div>
              </td>
              <td data-label="Source / contract">
                {group["source_id"]}
                <div class="sub">{group["parameter_contract"]}</div>
              </td>
            </tr>
          </tbody>
        </table>
        <PreviewPagination.pagination
          page={@groups["page"] || 1}
          size={@groups["page_size"] || 25}
          total={@groups["total"] || 0}
          label="Compatible settings pages"
          url={fn page -> group_path(@search, page, @return_to) end}
        />
      </section>
    </div>
    """
  end

  defp managed_rule(assigns) do
    ~H"""
    <PreviewDetail.card id="managed-rule" title="Project provenance" level={2}>
      <PreviewDetail.facts label="Rule ownership">
        <tr>
          <th scope="row">Project</th><td>{@rule["managed_project"]}</td>
        </tr><tr>
          <th scope="row">Rule key</th><td>{@rule["managed_key"]}</td>
        </tr>
      </PreviewDetail.facts>
      <p class="configuration-section-note">
        Edit here or through Git. Accepted changes keep their project identity and appear in <.link navigate="/configuration/history">configuration history</.link>.
      </p>
    </PreviewDetail.card>
    """
  end

  defp rule_form(assigns) do
    ~H"""
    <PreviewDetail.card id="rule-settings" title="Rule settings" level={2}>
      <div class="configuration-card-body">
        <p :if={@rule} class="footnote">Editing captured revision {@proposal["revision"]}</p>
        <p :if={@seed_check_id} id="rule-seed-context" class="notice notice-copy">
          Starting values are copied from one example check's currently saved settings; other checks may have different values or defaults from code. Review the complete set below.
          <.link navigate={"/configuration/" <> @seed_check_id}>Inspect the example check</.link>
        </p>
        <p :if={@rule && (@rule["match_count"] || 0) == 0} id="rule-zero-matches" class="notice">
          No current checks match. This rule is retained and will apply to compatible checks that appear later while it is enabled.
        </p>
        <form
          id="configuration-rule-form"
          phx-change="edit"
          phx-submit="preview"
          phx-auto-recover="recover"
        >
          <input type="hidden" name="_proposal" value={Jason.encode!(@proposal)} />
          <input type="hidden" name="_environment_scope" value={@environment_scope} />
          <input type="hidden" name="_target_scope" value={@target_scope} />
          <fieldset class="rules-fieldset">
            <legend>1. Name and precedence</legend><div class="form-grid rules-name-fields">
              <div class="field">
                <label for="rule-name">Rule name</label><input
                  id="rule-name"
                  name="rule[name]"
                  value={@proposal["name"]}
                  maxlength="200"
                  required
                />
              </div>
              <div class="field">
                <label for="rule-enabled">Status</label><select id="rule-enabled" name="rule[enabled]"><option
                  value="true"
                  selected={@proposal["enabled"] in [true, "true"]}
                >
                  Enabled
                </option><option value="false" selected={@proposal["enabled"] in [false, "false"]}>
                  Disabled
                </option></select>
              </div>
              <div class="field">
                <label for="rule-priority">Priority</label><input
                  id="rule-priority"
                  type="number"
                  name="rule[priority]"
                  value={@proposal["priority"]}
                  min="-10000"
                  max="10000"
                  step="1"
                  required
                /><small>Higher wins. Equal highest priorities conflict.</small>
              </div>
            </div>
          </fieldset>
          <fieldset class="rules-fieldset">
            <legend>2. Monitored scope</legend><div class="form-grid">
              <div class="field">
                <label for="rule-environment-scope">Monitored environments</label>
                <select id="rule-environment-scope" name="scope[environment]"><option
                  value="all"
                  selected={@environment_scope == "all"}
                >
                  All monitored environments
                </option><option value="one" selected={@environment_scope == "one"}>
                  One monitored environment
                </option></select>
              </div>
              <div :if={@environment_scope == "one"} class="field">
                <label for="rule-environment">Choose or enter an environment ID</label><input
                  id="rule-environment"
                  name="rule[environment]"
                  value={@proposal["environment"]}
                  maxlength="128"
                  list="rule-environment-options"
                  required
                /><datalist id="rule-environment-options"><option
                  :for={environment <- @scope_choices["environments"] || []}
                  value={environment["id"]}
                >
                  {environment["label"]}
                </option></datalist><small>A stable ID can describe an environment whose checks have not appeared yet.</small>
              </div>
              <div class="field">
                <label for="rule-target-scope">Monitored targets</label>
                <select id="rule-target-scope" name="scope[target]"><option
                  value="all"
                  selected={@target_scope == "all"}
                >
                  All targets
                </option><option value="one" selected={@target_scope == "one"}>
                  One exact target
                </option></select>
              </div>
              <div :if={@target_scope == "one"} class="field">
                <label for="rule-target-kind">Target kind</label><input
                  id="rule-target-kind"
                  name="rule[target_kind]"
                  value={@proposal["target_kind"]}
                  maxlength="64"
                  placeholder="For example: volume"
                  list="rule-kind-options"
                  required
                /><datalist id="rule-kind-options"><option
                  :for={kind <- Enum.uniq(Enum.map(@scope_choices["targets"] || [], & &1["kind"]))}
                  value={kind}
                /></datalist><small>Kind and stable ID together identify the target.</small>
              </div>
              <div :if={@target_scope == "one"} class="field">
                <label for="rule-target-key">Stable target ID</label><input
                  id="rule-target-key"
                  name="rule[target_key]"
                  value={@proposal["target_key"]}
                  maxlength="200"
                  list="rule-target-options"
                  required
                /><datalist id="rule-target-options"><option
                  :for={target <- @scope_choices["targets"] || []}
                  :if={target["kind"] == @proposal["target_kind"]}
                  value={target["key"]}
                >
                  {target["label"]}
                </option></datalist><small>Choose an existing target or enter a future subject's stable ID, such as a persistent volume UID.</small>
              </div>
            </div>
          </fieldset>
          <p
            :if={@scope_choices["environments_truncated"] || @scope_choices["targets_truncated"]}
            class="footnote space-top"
            id="rule-scope-suggestions-limit"
          >
            Suggestions show the first 100 environments or targets. You can enter any exact stable ID, including one not listed here.
          </p>
          <p class="footnote space-top">
            This rule follows the monitored subject across runners. A target-specific rule requires every result from the scheduled check to describe that target; shared executions spanning other targets need separate checks.
          </p>
          <fieldset class="rules-fieldset">
            <legend>3. Complete parameter set</legend><p class="footnote">
              The source declares these fields. The rule supplies the complete set below.
            </p>
            <ParameterForm.fields
              id_prefix="rule-param"
              schema={@proposal["parameter_schema"]}
              values={@proposal["params"]}
              error={@error}
              error_id="rule-error"
            />
          </fieldset>
          <div class="configuration-form-actions">
            <p>
              Review current matches before saving. Future compatible matches are included automatically.
            </p><button class="button primary" phx-disable-with="Previewing…">Preview rule</button>
          </div>
        </form>
        <details class="space-top">
          <summary>Source contract and schema</summary><PreviewDetail.facts label="Source contract">
            <tr>
              <th scope="row">Source</th><td>{@proposal["source_id"]}</td>
            </tr><tr>
              <th scope="row">Parameter contract</th><td>{@proposal["parameter_contract"]}</td>
            </tr>
          </PreviewDetail.facts><p>
            Rules require the reviewed schema, including field types, units and constraints. An incompatible source declaration is visible as a configuration problem; values are never silently reinterpreted.
          </p>
        </details>
      </div>
    </PreviewDetail.card>
    <PreviewDetail.card
      :if={@rule}
      id="rule-source-schema"
      title="Review a changed source schema"
      level={2}
    >
      <p class="configuration-section-note">
        Load a current check with the same source and parameter contract. Retained fields keep your values; review the resulting complete set before saving.
      </p>
      <div class="configuration-filter-toolbar">
        <PreviewFilters.filter_picker
          id="rule-schema-filter"
          picker={@picker}
          chips={[]}
          fields={[]}
          search={if @schema_search != "", do: @schema_search}
          remove={nil}
          form_label="Find a current source schema"
          label="Find a current check"
          placeholder="Search check names"
        />
      </div>
      <p :if={@schema_candidates == []} class="preview-empty">
        No current checks match. The rule and its captured schema are retained.
      </p>
      <table
        :if={@schema_candidates != []}
        class="inventory-table rules-schema-table"
        aria-label="Current source schemas"
      >
        <thead>
          <tr>
            <th scope="col">Check</th><th scope="col">Environment / runner</th><th scope="col">
              Action
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={check <- @schema_candidates}>
            <td data-label="Check">{check["label"]}</td><td data-label="Environment / runner">
              {check["environment"]}
              <div class="sub">{check["runner_label"] || check["runner_id"]}</div>
            </td>
            <td data-label="Action">
              <button
                type="button"
                class="button"
                phx-click="refresh_schema"
                phx-value-check_id={check["id"]}
              >Load schema for review</button>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="configuration-section-note">Up to 50 matching checks are shown.</p>
    </PreviewDetail.card>
    """
  end

  defp rule_preview(assigns) do
    ~H"""
    <PreviewDetail.card id="rule-preview" title="Review rule" level={2}>
      <PreviewDetail.facts label="Rule proposal">
        <tr>
          <th scope="row">Rule</th><td>
            {@proposal["name"]}
            <span class="badge">{if @proposal["enabled"], do: "Enabled", else: "Disabled"}</span>
          </td>
        </tr>
        <tr>
          <th scope="row">Scope</th><td>{scope_label(@proposal)}</td>
        </tr>
        <tr>
          <th scope="row">Priority</th><td>{@proposal["priority"]}</td>
        </tr>
        <tr>
          <th scope="row">Current effects</th><td id="rule-preview-summary">
            {quantity(@preview["counts"]["matched"], "check")} reviewed · {quantity(
              @preview["counts"]["changed"],
              "configuration"
            )} will change · {quantity(@preview["counts"]["exceptions"], "instance exception")} · {quantity(
              @preview["counts"]["conflicts"],
              "conflict"
            )}
          </td>
        </tr>
        <tr :if={@preview["scope_counts"]}>
          <th scope="row">Scope matching</th><td
            id="rule-preview-scope"
            class="preview-incident-nested-facts"
          >
            <PreviewDetail.facts label="Scope review">
              <tr>
                <th scope="row">Fully matching checks</th><td>
                  {@preview["scope_counts"]["proposed_full"]}
                </td>
              </tr>
              <tr>
                <th scope="row">Executions spanning other targets</th><td>
                  {@preview["scope_counts"]["proposed_partial"]}
                </td>
              </tr>
              <tr>
                <th scope="row">Excluded from this scope</th><td>
                  {@preview["scope_counts"]["excluded"]}
                </td>
              </tr>
              <tr :if={@preview["scope_counts"]["released_from_rule"] > 0}>
                <th scope="row">Leaving this rule</th><td>
                  {@preview["scope_counts"]["released_from_rule"]}. Their resulting values are included below.
                </td>
              </tr>
            </PreviewDetail.facts>
          </td>
        </tr>
        <tr>
          <th scope="row">Future checks</th><td>
            {if @proposal["enabled"],
              do:
                "Compatible checks in this scope follow this rule unless an exception or higher-priority rule takes precedence.",
              else: "Disabled rules keep their scope but do not supply values."}
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={(@preview["counts"]["matched"] || 0) == 0} class="configuration-section-note">
        No current check configuration is affected. The rule remains saved for future compatible checks.
      </p>
      <p :if={!@token} class="configuration-inline-feedback" role="alert">
        Resolve conflicts before saving. No configuration has changed.
      </p>
      <table
        :if={(@preview["rows"] || []) != []}
        class="inventory-table rules-preview-table"
        aria-label="Reviewed configuration changes"
      >
        <thead>
          <tr>
            <th scope="col" id="rule-review-check">Scheduled check</th><th
              scope="col"
              id="rule-review-current"
            >
              Currently saved values
            </th><th scope="col" id="rule-review-proposed">After this rule</th><th
              scope="col"
              id="rule-review-outcome"
            >
              Outcome
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @preview["rows"]} id={"rule-preview-" <> row["id"]}>
            <td headers="rule-review-check" data-label="Scheduled check">
              <.link href={"/configuration/" <> row["id"]} target="_blank" rel="noopener">{row[
                "label"
              ]}<span class="sub"> (new tab)</span></.link><div class="sub">
                {row["environment"]} · {length(row["outputs"] || [])} results
              </div><div class="sub">
                {if scope_matches?(@proposal, row),
                  do: "In proposed scope",
                  else: "Leaving this rule's scope"}
              </div><.link
                :if={row["runner_id"]}
                id={"rule-runner-" <> row["id"]}
                patch={InvestigationTrail.path(@host, [{"runner", row["runner_id"]}])}
                data-overview-open
              >Inspect runner</.link>
            </td>
            <td headers="rule-review-current" data-label="Currently saved values">
              <.parameter_values
                params={row["current_params"] || %{}}
                schema={row["parameter_schema"] || @proposal["parameter_schema"]}
              />
            </td>
            <td headers="rule-review-proposed" data-label="After this rule">
              <.parameter_values
                params={row["proposed_params"] || %{}}
                schema={row["parameter_schema"] || @proposal["parameter_schema"]}
              />
            </td>
            <td headers="rule-review-outcome" data-label="Outcome">
              <span :if={row["error"]} class="form-error">{error_message(row["error"])}</span><span :if={
                !row["error"]
              }>{if row["changed"], do: "Configuration changes", else: "Configuration unchanged"}
              <div class="sub">{origin_label(row["origin"])}</div></span>
            </td>
          </tr>
        </tbody>
      </table>
      <PreviewPagination.pagination
        page={@page}
        size={@preview["page_size"] || 25}
        total={@preview["total"] || 0}
        label="Rule match pages"
        event="preview_page"
      />
      <div class="configuration-card-body">
        <p class="footnote">
          Saving sets desired values. Runners still need to prepare, activate and measure them; incidents stay independent.
        </p>
        <form
          id="configuration-rule-form"
          phx-change="edit"
          phx-submit="save"
          phx-auto-recover="recover"
        >
          <input type="hidden" name="_proposal" value={Jason.encode!(@proposal)} /><input
            type="hidden"
            name="_environment_scope"
            value={@environment_scope}
          /><input type="hidden" name="_target_scope" value={@target_scope} /><input
            type="hidden"
            name="_review_token"
            value={@token}
          />
          <div class="configuration-form-actions">
            <button type="button" class="button" phx-click="back">Edit draft</button><button
              class="button primary"
              id="rule-save"
              disabled={!@token}
              phx-disable-with="Saving…"
            >Save rule</button>
          </div>
        </form>
      </div>
    </PreviewDetail.card>
    """
  end

  defp parameter_values(assigns) do
    ~H"""
    <PreviewDetail.facts class="rules-parameter-values" label="Complete parameter values">
      <tr :for={{key, value} <- Enum.sort(@params)}>
        <th scope="row">
          {get_in(@schema, ["fields", key, "label"]) || key}<span :if={
            get_in(@schema, ["fields", key, "unit"])
          }> ({get_in(@schema, ["fields", key, "unit"])})</span>
        </th><td>{if is_binary(value), do: value, else: Jason.encode!(value)}</td>
      </tr>
    </PreviewDetail.facts>
    """
  end

  defp diagnostics(assigns) do
    ~H"""
    <PreviewDetail.card
      :if={@entries != []}
      id="rule-diagnostics"
      title="Source declarations needing attention"
      level={2}
    >
      <p class="configuration-section-note">
        These declarations were rejected. Previously accepted checks keep their settings; newly declared checks may not have been admitted.
      </p>
      <table class="inventory-table" aria-label="Rejected source declarations">
        <thead>
          <tr>
            <th scope="col">Source / check</th><th scope="col">Problem</th><th scope="col">
              Investigate
            </th>
          </tr>
        </thead><tbody>
          <tr :for={entry <- @entries}>
            <td data-label="Source / check">
              {entry["source_id"]}
              <div class="sub">{entry["source_key"]}</div>
            </td>
            <td data-label="Problem">{entry["message"]}</td>
            <td data-label="Investigate">
              <.link navigate={"/runners?" <> URI.encode_query(%{"source_id" => entry["source_id"]})}>Inspect runners</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <details>
        <summary>Correcting a blocked schema change</summary><p class="configuration-section-note">
          Restore the accepted source, or disable the rule through review, publish the changed source, then load a current check's schema and review before enabling the rule again. Changing parameter types or units requires a new check identity and parameter contract.
        </p>
      </details>
    </PreviewDetail.card>
    """
  end

  defp quantity(value, noun), do: "#{value || 0} #{noun}" <> if(value == 1, do: "", else: "s")
  defp page_title(:index, _), do: "Configuration rules"
  defp page_title(:new, _), do: "Create configuration rule"
  defp page_title(_, rule), do: (rule || %{})["name"] || "Configuration rule"

  defp list_filters(params) do
    %{
      "search" => ScalarFilterPicker.text(params["search"]),
      "source_id" => ScalarFilterPicker.text(params["source_id"]),
      "enabled" =>
        if(List.keymember?(@status_choices, params["enabled"], 0), do: params["enabled"]),
      "ownership" =>
        if(List.keymember?(@ownership_choices, params["ownership"], 0), do: params["ownership"])
    }
    |> Map.reject(fn {_, value} -> value in [nil, ""] end)
  end

  defp list_path(filters) do
    query =
      Map.take(filters, ~w(search source_id enabled ownership page))
      |> Map.reject(fn {_, value} -> value in [nil, ""] end)
      |> Enum.sort()
      |> URI.encode_query()

    "/configuration/rules" <> if(query == "", do: "", else: "?" <> query)
  end

  defp patch_list(socket, changes) do
    filters = socket.assigns.filters |> Map.merge(changes) |> list_filters()

    if filters == socket.assigns.filters,
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: list_path(filters))}
  end

  defp choices("enabled", _), do: @status_choices
  defp choices("ownership", _), do: @ownership_choices
  defp choices("source_id", listing), do: Enum.map(listing["sources"] || [], &{&1, &1})
  defp choices(_, _), do: []
  defp empty_values(_), do: [nil, ""]

  defp picker_ready(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp refresh_list(socket),
    do:
      assign(socket,
        listing:
          ConfigurationRules.list(Map.put(socket.assigns.filters, "page", socket.assigns.page))
      )

  defp load_proposal(socket, {:ok, proposal}),
    do: assign(socket, rule: nil, proposal: Map.take(proposal, @proposal_fields))

  defp load_proposal(socket, {:error, reason}),
    do: assign(socket, rule: nil, proposal: nil, error: error_message(reason))

  defp recoverable_proposal?(proposal) do
    Enum.all?(~w(source_id parameter_contract), &required_identity?(proposal[&1])) &&
      Enum.all?(
        ~w(id name environment target_kind target_key),
        fn key ->
          value = proposal[key]

          is_nil(value) ||
            (is_binary(value) && byte_size(value) <= 800 && String.valid?(value) &&
               !String.contains?(value, <<0>>))
        end
      ) && is_integer(proposal["revision"]) && proposal["revision"] >= 0 &&
      (is_integer(proposal["priority"]) ||
         (is_binary(proposal["priority"]) && byte_size(proposal["priority"]) <= 32)) &&
      proposal["enabled"] in [true, false, "true", "false"] &&
      Mondek.Parameters.schema?(proposal["parameter_schema"]) &&
      scalar_params?(proposal["params"])
  end

  defp required_identity?(value),
    do:
      is_binary(value) && byte_size(value) in 1..800 && String.valid?(value) &&
        String.trim(value) != "" && !String.contains?(value, <<0>>)

  defp scalar_params?(params) when is_map(params),
    do:
      Enum.all?(params, fn {key, value} ->
        required_identity?(key) &&
          (is_nil(value) || is_boolean(value) || is_number(value) ||
             (is_binary(value) && byte_size(value) <= 100_000 && String.valid?(value) &&
                !String.contains?(value, <<0>>)))
      end)

  defp scalar_params?(_), do: false

  defp keep_draft(%{assigns: %{proposal: nil}} = socket, _form), do: socket

  defp keep_draft(socket, form) do
    modes = if is_map(form["scope"]), do: form["scope"], else: %{}

    environment_scope =
      if modes["environment"] in ["all", "one"],
        do: modes["environment"],
        else: socket.assigns.environment_scope

    target_scope =
      if modes["target"] in ["all", "one"], do: modes["target"], else: socket.assigns.target_scope

    proposal =
      socket.assigns.proposal
      |> Map.merge(
        if(is_map(form["rule"]), do: Map.take(form["rule"], @editable_fields), else: %{})
        |> Map.filter(fn {key, value} ->
          (key == "enabled" && is_boolean(value)) ||
            (is_binary(value) && byte_size(value) <= 800 && String.valid?(value) &&
               !String.contains?(value, <<0>>))
        end)
      )
      |> Map.put(
        "params",
        if(scalar_params?(form["params"]),
          do: form["params"],
          else: socket.assigns.proposal["params"]
        )
      )

    proposal =
      if modes["environment"] == "all", do: Map.put(proposal, "environment", nil), else: proposal

    proposal =
      if modes["target"] == "all",
        do: Map.merge(proposal, %{"target_kind" => nil, "target_key" => nil}),
        else: proposal

    assign(socket,
      proposal: proposal,
      environment_scope: environment_scope,
      target_scope: target_scope
    )
  end

  defp assign_scope(%{assigns: %{proposal: nil}} = socket), do: socket

  defp assign_scope(socket) do
    proposal = socket.assigns.proposal

    assign(socket,
      environment_scope: if(proposal["environment"] in [nil, ""], do: "all", else: "one"),
      target_scope: if(proposal["target_key"] in [nil, ""], do: "all", else: "one"),
      scope_choices:
        ConfigurationRules.scope_choices(proposal["source_id"], proposal["parameter_contract"])
    )
  end

  defp group_path(search, page, return_to),
    do:
      "/configuration/rules/new?" <>
        URI.encode_query(
          Map.reject(%{"search" => search, "page" => page, "return_to" => return_to}, fn {_,
                                                                                          value} ->
            is_nil(value)
          end)
        )

  defp typed_proposal(proposal) do
    with {:ok, params} <- ParameterForm.parse(proposal["parameter_schema"], proposal["params"]),
         {priority, ""} <- Integer.parse(to_string(proposal["priority"])) do
      {:ok,
       proposal
       |> Map.put("params", params)
       |> Map.put("priority", priority)
       |> Map.put("enabled", proposal["enabled"] in [true, "true"])
       |> then(fn draft ->
         Enum.reduce(~w(environment target_kind target_key), draft, fn key, draft ->
           value = String.trim(draft[key] || "")
           Map.put(draft, key, if(value == "", do: nil, else: value))
         end)
       end)}
    else
      {:error, _} = error -> error
      _ -> {:error, "Enter an integer priority."}
    end
  end

  defp validate_scope(socket) do
    proposal = socket.assigns.proposal || %{}

    cond do
      socket.assigns.environment_scope == "one" &&
          String.trim(proposal["environment"] || "") == "" ->
        {:error,
         "Choose or enter one monitored environment, or select All monitored environments."}

      socket.assigns.target_scope == "one" &&
          Enum.any?(~w(target_kind target_key), &(String.trim(proposal[&1] || "") == "")) ->
        {:error, "Enter both the target kind and stable ID, or select All targets."}

      true ->
        :ok
    end
  end

  defp refresh_schema(socket, id) do
    with proposal when is_map(proposal) <- socket.assigns.proposal,
         {:ok, source} <- ConfigurationRules.seed(id),
         true <-
           source["source_id"] == proposal["source_id"] &&
             source["parameter_contract"] == proposal["parameter_contract"] do
      fields = Map.keys(source["parameter_schema"]["fields"])
      params = Map.merge(source["params"], Map.take(proposal["params"], fields))

      assign(socket,
        proposal:
          Map.merge(proposal, %{
            "parameter_schema" => source["parameter_schema"],
            "params" => params
          }),
        preview: nil,
        review_token: nil,
        error: nil,
        notice:
          "Loaded the selected check's schema for review. Verify the fields, units and values, then preview before saving."
      )
    else
      false ->
        assign(socket, error: "Choose a check with the same source and parameter contract.")

      {:error, reason} ->
        assign(socket, error: error_message(reason))

      _ ->
        assign(socket, error: "Load a rule before reviewing a new schema.")
    end
  end

  defp rule_path(id), do: "/configuration/rules/" <> id

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp positive_integer(_), do: 1

  defp scope_label(rule) do
    environment = rule["environment"] || "All environments"

    target =
      if rule["target_key"],
        do: "#{rule["target_kind"]}: #{rule["target_key"]}",
        else: "All targets"

    environment <> " · " <> target
  end

  defp scope_matches?(proposal, row) do
    (is_nil(proposal["environment"]) || proposal["environment"] == row["environment"]) &&
      (is_nil(proposal["target_key"]) ||
         Enum.any?(row["outputs"] || [], fn output ->
           target = output["target"] || %{}
           target["kind"] == proposal["target_kind"] && target["key"] == proposal["target_key"]
         end))
  end

  defp origin_label(%{"kind" => "rule"} = origin),
    do: "Rule: " <> (origin["rule_name"] || origin["rule_id"])

  defp origin_label(%{"kind" => "exception"}), do: "Instance exception takes precedence"
  defp origin_label(_), do: "Defaults from code"
  defp error_message({:invalid, reason}), do: error_message(reason)
  defp error_message({:conflict, reason}), do: error_message(reason)
  defp error_message({:stale, _}), do: error_message(:stale)

  defp error_message(:stale),
    do:
      "The rule or matching inventory changed. Your draft is preserved; reload the saved rule if its revision changed, then preview again."

  defp error_message(:review_expired),
    do: "This preview expired. Your draft is preserved; preview again before saving."

  defp error_message(:not_found),
    do: "The requested rule or check is not in the retained inventory."

  defp error_message(reason) when is_binary(reason), do: reason

  defp error_message(reason) when is_map(reason),
    do: reason["message"] || "This match needs attention. Review its configuration."

  defp error_message(_),
    do: "This rule could not be saved. Review the draft and preview its current matches again."
end

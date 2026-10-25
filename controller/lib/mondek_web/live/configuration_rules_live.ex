# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationRulesLive do
  use MondekWeb, :live_view

  alias Mondek.{ConfigurationRules, Monitoring}
  alias MondekWeb.ParameterForm
  alias MondekWeb.ConfigurationValues
  alias MondekWeb.InvestigationNavigation

  @proposal_fields ~w(id revision name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params)
  @editable_fields ~w(name environment target_kind target_key priority enabled)

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
       preview_page: 1
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        error: nil,
        notice: nil,
        preview: nil,
        review_token: nil,
        return_to: InvestigationNavigation.safe_return_path(params["return_to"])
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
          search = String.slice(params["search"] || "", 0, 200)

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
                schema_search: "",
                schema_candidates: ConfigurationRules.schema_candidates(rule["id"])
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
  def handle_event("edit", form, socket) do
    {:noreply,
     socket
     |> keep_draft(form)
     |> assign(preview: nil, review_token: nil, error: nil, notice: nil)}
  end

  def handle_event("group_search", %{"search" => search}, socket) do
    {:noreply, push_patch(socket, to: group_path(String.slice(search, 0, 200), 1))}
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
         true <- captured["id"] == (socket.assigns.proposal || %{})["id"] do
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
      {:noreply,
       socket
       |> assign(
         saved_rule_id: saved["rule"]["id"],
         saved_rule_revision: saved["rule"]["revision"],
         saved_receipts: Enum.filter(saved["receipts"], & &1["changed"]),
         saved_page: 1
       )
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
    search = String.slice(search, 0, 200)
    candidates = ConfigurationRules.schema_candidates(socket.assigns.rule["id"], search)
    {:noreply, assign(socket, schema_search: search, schema_candidates: candidates)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.Layouts.app
      active={:configuration}
      page_title="Configuration rules"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
      main_class=""
    >
      <.link
        navigate={
          @return_to || if @live_action == :index, do: "/configuration", else: "/configuration/rules"
        }
        class="back"
      >{InvestigationNavigation.return_label(
        @return_to,
        if(@live_action == :index, do: "Back to configuration", else: "All configuration rules")
      )}</.link>
      <div class="page-heading">
        <div>
          <div class="eyebrow">Shared settings</div><h1>
            {if @live_action == :index,
              do: "Configuration rules",
              else:
                if(@live_action == :new,
                  do: "Create configuration rule",
                  else: (@rule || %{})["name"] || "Configuration rule"
                )}
          </h1><p>
            Apply settings to present and future checks, independently of which runner observes them.
          </p>
        </div>
      </div>
      <p :if={@error} id="rule-error" role="alert" class="form-error space-top">{@error}</p>
      <.link
        :if={@error && @rule}
        navigate={InvestigationNavigation.detail_path(rule_path(@rule["id"]), @return_to)}
        class="button small space-top"
        id="reload-rule"
      >Reload saved rule and discard draft</.link>
      <p :if={@notice} id="rule-notice" role="status" class="notice space-top">{@notice}</p>
      <.saved_change
        :if={@rule}
        rule={@rule}
        receipts={@saved_receipts}
        revision={@saved_rule_revision}
        progress={@saved_progress}
        page={@saved_page}
      />
      <.link navigate="/configuration/history" class="text-link">Configuration history and Git access</.link>
      <.rules_list :if={@live_action == :index} listing={@listing} />
      <.group_chooser
        :if={@live_action == :new && @proposal == nil}
        groups={@groups}
        search={@group_search}
      />
      <div :if={@live_action == :edit && @proposal == nil} class="empty">
        <p>No saved rule is available at this address.</p>
        <.link navigate="/configuration/rules" class="button primary">Browse saved rules</.link>
      </div>
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
      />
      <.rule_preview
        :if={@preview}
        preview={@preview}
        proposal={@proposal}
        token={@review_token}
        page={@preview_page}
        environment_scope={@environment_scope}
        target_scope={@target_scope}
      />
      <.managed_rule :if={managed?(@rule)} rule={@rule} />
      <.diagnostics :if={@rule} entries={@rule["diagnostics"] || []} />
    </MondekWeb.Layouts.app>
    """
  end

  defp rules_list(assigns) do
    ~H"""
    <section class="panel">
      <div class="panel-heading">
        <h2>Saved rules</h2><span class="badge">{@listing["total"] || 0} rules</span>
      </div>
      <div class="panel-body">
        <p>
          An instance exception takes precedence. Otherwise, the enabled matching rule with the highest priority supplies the full parameter set. Without either, defaults from code apply. Matching rules tied for highest priority require a correction.
        </p><.link
          navigate="/configuration/rules/new"
          class="button primary space-top"
          id="new-shared-rule"
        >New shared rule</.link>
      </div>
      <div :if={(@listing["rules"] || []) == []} class="empty">
        <h3>No configuration rules yet</h3><p>
          Choose a compatible check group to share settings. Rules remain here when their checks disappear.
        </p>
      </div>
      <div :if={(@listing["rules"] || []) != []} class="table-wrap rule-table-wrap">
        <table class="inventory-table rule-table" role="table" aria-label="Saved configuration rules">
          <thead role="rowgroup">
            <tr role="row">
              <th scope="col" id="rule-list-name" role="columnheader">Rule</th><th
                scope="col"
                id="rule-list-matches"
                role="columnheader"
              >
                Matches
              </th><th scope="col" id="rule-list-scope" role="columnheader">Scope</th><th
                scope="col"
                id="rule-list-priority"
                role="columnheader"
              >
                Priority
              </th>
            </tr>
          </thead><tbody role="rowgroup">
            <tr :for={rule <- @listing["rules"] || []} id={"rule-row-" <> rule["id"]} role="row">
              <td headers="rule-list-name" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Rule</span>
                <.link navigate={rule_path(rule["id"])}><strong>{rule["name"]}</strong></.link><div class="sub">
                  {if rule["enabled"], do: "Enabled", else: "Disabled"}
                </div>
                <div :if={managed?(rule)} class="sub managed-policy-label">
                  Project: {rule["managed_project"]} · {rule["managed_key"]}
                </div>
              </td><td headers="rule-list-matches" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Matches</span>
                {rule["match_count"] || 0} current checks<div
                  :if={(rule["conflict_count"] || 0) > 0}
                  class="sub"
                >
                  {rule["conflict_count"]} need attention
                </div><div :if={(rule["match_count"] || 0) == 0 && rule["enabled"]} class="sub">
                  Applies when compatible checks appear
                </div>
              </td><td headers="rule-list-scope" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Scope</span>
                {scope_label(rule)}
                <div class="sub">{rule["source_id"]} · {rule["parameter_contract"]}</div>
              </td><td headers="rule-list-priority" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Priority</span>{rule["priority"]}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <nav :if={pages(@listing) > 1} class="pagination" aria-label="Rule pages">
        <.link
          :if={(@listing["page"] || 1) > 1}
          patch={"/configuration/rules?page=#{@listing["page"] - 1}"}
          class="button small"
        >Previous</.link><span>Page {@listing["page"]} of {pages(@listing)}</span><.link
          :if={(@listing["page"] || 1) < pages(@listing)}
          patch={"/configuration/rules?page=#{@listing["page"] + 1}"}
          class="button small"
        >Next</.link>
      </nav>
    </section>
    <ConfigurationValues.workflow />
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
    <section
      :if={is_list(@receipts)}
      id="rule-saved-change"
      class="panel space-top"
      aria-labelledby="rule-saved-change-heading"
    >
      <div class="panel-heading">
        <h2 id="rule-saved-change-heading">Adoption of this saved change</h2>
        <span class="badge">Rule revision {@revision}</span>
      </div>
      <div class="panel-body">
        <p :if={@receipts == []}>
          No check received a new desired version. The rule is saved and will apply to future compatible matches while enabled.
        </p>
        <p :if={@progress} id="rule-saved-change-summary" role="status">
          {Enum.map_join(
            Enum.filter(@progress["counts"], fn {_stage, count} -> count > 0 end),
            " · ",
            fn {stage, count} -> "#{count} #{saved_stage(stage)}" end
          )}
        </p>
        <details
          :if={@progress}
          id="rule-saved-change-details"
          phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
        >
          <summary>Inspect {@progress["total"]} saved check versions</summary>
          <div class="table-wrap rule-table-wrap space-top">
            <table
              class="inventory-table rule-table"
              role="table"
              aria-label="Saved configuration versions"
            >
              <thead role="rowgroup">
                <tr role="row">
                  <th scope="col" id="saved-check" role="columnheader">Scheduled check</th><th
                    scope="col"
                    id="saved-version"
                    role="columnheader"
                  >
                    Saved version
                  </th><th scope="col" id="saved-adoption" role="columnheader">
                    Adoption
                  </th>
                </tr>
              </thead><tbody role="rowgroup">
                <tr :for={row <- @progress["rows"]} id={"rule-saved-" <> row["id"]} role="row">
                  <td headers="saved-check" role="cell">
                    <span class="rule-cell-label" aria-hidden="true">Scheduled check</span>
                    <.link navigate={"/configuration/" <> row["id"]}>{row["label"]}</.link><div class="sub">
                      {row["runner_label"] || row["runner_id"]}
                    </div>
                  </td><td headers="saved-version" role="cell">
                    <span class="rule-cell-label" aria-hidden="true">Saved version</span>{row[
                      "target_generation"
                    ]}
                  </td><td headers="saved-adoption" role="cell">
                    <span class="rule-cell-label" aria-hidden="true">Adoption</span>{saved_stage(
                      row["stage"]
                    )}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <nav :if={pages(@progress) > 1} class="pagination" aria-label="Saved change pages">
            <button
              :if={@page > 1}
              type="button"
              class="button small"
              phx-click="saved_page"
              phx-value-page={@page - 1}
            >Previous saved versions</button><span>Page {@page} of {pages(@progress)}</span><button
              :if={@page < pages(@progress)}
              type="button"
              class="button small"
              phx-click="saved_page"
              phx-value-page={@page + 1}
            >Next saved versions</button>
          </nav>
        </details>
        <p class="footnote">
          This follows only the versions saved by this action. Measured means complete evidence arrived for that version; it can be stale now. Superseded means a later configuration replaced it, without proving this version ran. This progress summary remains available until you reload or leave this rule.
        </p>
      </div>
    </section>
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
    <section class="panel" id="configuration-group-chooser">
      <div class="panel-heading">
        <h2>Choose settings to share</h2>
      </div>
      <div class="panel-body">
        <p>
          Start with a group of checks whose code declares compatible settings. Next, choose which monitored environments and targets should follow the rule, including future checks.
        </p>
        <form id="configuration-group-search" phx-submit="group_search" class="form-actions space-top">
          <div class="field">
            <label for="group-search">Find check settings</label><input
              id="group-search"
              name="search"
              value={@search}
              maxlength="200"
              placeholder="Check name, setting or source"
            />
          </div>
          <button class="button">Find groups</button>
        </form>
        <p class="footnote">
          {@groups["total"] || 0} compatible groups. Similar field names alone do not make checks compatible.
        </p>
      </div>
      <div :if={(@groups["groups"] || []) == []} class="empty">
        <h3>No matching shared settings</h3>
        <p>
          Checks must delegate settings and declare their shared meaning in code. Try another search, or inspect an individual check.
        </p>
        <.link navigate="/configuration" class="button">Choose a scheduled check</.link>
      </div>
      <div class="configuration-groups">
        <section
          :for={group <- @groups["groups"] || []}
          class="panel-body configuration-group"
          id={"settings-group-" <> group["check_id"]}
        >
          <h3>Settings used by {group["label"]}</h3>
          <p :if={group["label_count"] > 1} class="sub">
            And {group["label_count"] - 1} other check names
          </p>
          <p>{Enum.map_join(group["fields"], ", ", & &1["label"])}</p>
          <p class="sub">
            {group["check_count"]} scheduled checks · {group["result_count"]} results · {group[
              "environment_count"
            ]} monitored environments
          </p>
          <p class="sub">Source: {group["source_id"]}</p>
          <.link
            class="button primary small"
            navigate={"/configuration/rules/new?" <> URI.encode_query(%{"check_id" => group["check_id"], "group" => "1"})}
          >Use these settings</.link>
          <details class="space-top">
            <summary>Declared compatibility</summary><p>
              Contract {group["parameter_contract"]}. This group shares the complete declared schema. The review checks all assignments in your chosen scope, including incompatible declarations and existing exceptions.
            </p>
          </details>
        </section>
      </div>
      <nav :if={pages(@groups) > 1} class="pagination" aria-label="Compatible settings pages">
        <.link
          :if={@groups["page"] > 1}
          class="button small"
          patch={group_path(@search, @groups["page"] - 1)}
        >Previous groups</.link>
        <span>Page {@groups["page"]} of {pages(@groups)}</span>
        <.link
          :if={@groups["page"] < pages(@groups)}
          class="button small"
          patch={group_path(@search, @groups["page"] + 1)}
        >Next groups</.link>
      </nav>
    </section>
    """
  end

  defp managed_rule(assigns) do
    ~H"""
    <p id="managed-rule" class="footnote space-top">
      Project: <strong>{@rule["managed_project"]}</strong>
      · Rule key: <strong>{@rule["managed_key"]}</strong>.
      Edit here or through Git. Accepted changes are recorded automatically in <.link navigate="/configuration/history">configuration history</.link>.
    </p>
    """
  end

  defp rule_form(assigns) do
    ~H"""
    <section class="panel space-top">
      <div class="panel-heading">
        <h2>Rule settings</h2><span :if={@rule} class="badge">Revision {@proposal["revision"]}</span>
      </div>
      <div class="panel-body">
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
          <div class="form-grid">
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
              </option><option value="one" selected={@target_scope == "one"}>One exact target</option></select>
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
          <h3 class="space-top">Parameters</h3><p class="footnote">
            The source declares these fields. The rule supplies the complete set below.
          </p>
          <ParameterForm.fields
            id_prefix="rule-param"
            schema={@proposal["parameter_schema"]}
            values={@proposal["params"]}
            error={@error}
            error_id="rule-error"
          />
          <div class="form-actions">
            <p>
              Review current matches before saving. Future compatible matches are included automatically.
            </p><button class="button primary" phx-disable-with="Previewing…">Preview rule</button>
          </div>
        </form>
        <details class="space-top">
          <summary>Source contract and schema</summary><dl class="kv-list">
            <div class="kv">
              <dt>Source</dt><dd>{@proposal["source_id"]}</dd>
            </div><div class="kv">
              <dt>Shared parameter contract</dt><dd>{@proposal["parameter_contract"]}</dd>
            </div>
          </dl><p>
            Rules require the reviewed schema, including field types, units and constraints. An incompatible source declaration is visible as a configuration problem; values are never silently reinterpreted.
          </p>
        </details>
      </div>
    </section>
    <section :if={@rule} class="panel space-top">
      <div class="panel-heading">
        <h2>Review a changed source schema</h2>
      </div><div class="panel-body">
        <p>
          Choose a current check with the same source and parameter contract. Existing rule values are retained where fields still exist; preview the resulting complete set before saving.
        </p>
        <form
          id="rule-schema-search"
          phx-change="schema_search"
          phx-submit="schema_search"
          class="space-top"
        >
          <div class="field">
            <label for="rule-schema-search-input">Find a current check</label><input
              id="rule-schema-search-input"
              name="search"
              value={@schema_search}
              maxlength="200"
              phx-debounce="250"
            /><small>Search check names. Up to 50 matching checks are listed.</small>
          </div>
        </form>
        <form id="rule-refresh-schema" phx-submit="refresh_schema" class="space-top">
          <div class="field">
            <label for="rule-refresh-check">Current check to review</label><select
              id="rule-refresh-check"
              name="check_id"
              required
            ><option value="" disabled selected>Choose a check with the same contract</option><option
              :for={check <- @schema_candidates}
              value={check["id"]}
            >
              {check["label"]} · {check["environment"]} · {check["runner_label"] || check["runner_id"]}
            </option></select>
            <small :if={@schema_candidates == []}>No current checks match this search. The rule and its captured schema are retained.</small>
          </div><button class="button small space-top" disabled={@schema_candidates == []}>Load schema for review</button>
        </form>
      </div>
    </section>
    """
  end

  defp rule_preview(assigns) do
    ~H"""
    <section class="panel space-top" id="rule-preview">
      <div class="panel-heading">
        <h2>Review rule</h2><span class="badge">{if @proposal["enabled"],
          do: "Enabled",
          else: "Disabled"}</span>
      </div><div class="panel-body">
        <h3>{@proposal["name"]}</h3><p>{scope_label(@proposal)} · Priority {@proposal["priority"]}</p><p id="rule-preview-summary">
          {@preview["counts"]["matched"] || 0} checks reviewed · {@preview["counts"]["changed"] || 0} configurations will change · {@preview[
            "counts"
          ]["exceptions"] || 0} instance exceptions · {@preview["counts"]["conflicts"] || 0} conflicts
        </p>
        <p :if={@preview["scope_counts"]} id="rule-preview-scope">
          {@preview["scope_counts"]["proposed_full"]} checks fully match the proposed scope · {@preview[
            "scope_counts"
          ]["proposed_partial"]} executions span this and other targets · {@preview["scope_counts"][
            "excluded"
          ]} checks in this source and contract are outside the scope.
          <span :if={@preview["scope_counts"]["released_from_rule"] > 0}>{@preview["scope_counts"][
            "released_from_rule"
          ]} previously matching checks will be released from this rule. Their resulting values are included in the review.</span>
          <span :if={!@proposal["enabled"]}>This rule is disabled; scope matches will not adopt its values.</span>
          <span :if={@proposal["enabled"]}>Future compatible checks in this scope will follow the rule unless an exception or higher-priority rule takes precedence.</span>
        </p>
        <p :if={(@preview["counts"]["matched"] || 0) == 0} class="notice">
          No current check configuration is affected. The rule is retained; while enabled, it applies when compatible checks appear.
        </p><p :if={!@token} class="form-error" role="alert">
          Resolve the conflicts below before saving. No configuration has changed.
        </p><p class="footnote">
          Saving sets desired values; adoption and fresh measurement remain visible on each check. It does not move or merge incidents between runners.
        </p>
      </div>
      <div :if={(@preview["rows"] || []) != []} class="table-wrap rule-table-wrap">
        <table
          class="inventory-table rule-table"
          role="table"
          aria-label="Reviewed configuration changes"
        >
          <thead role="rowgroup">
            <tr role="row">
              <th scope="col" id="rule-review-check" role="columnheader">Scheduled check</th><th
                scope="col"
                id="rule-review-current"
                role="columnheader"
              >
                Currently saved values
              </th><th scope="col" id="rule-review-proposed" role="columnheader">
                After this rule
              </th><th scope="col" id="rule-review-outcome" role="columnheader">Outcome</th>
            </tr>
          </thead><tbody role="rowgroup">
            <tr :for={row <- @preview["rows"] || []} id={"rule-preview-" <> row["id"]} role="row">
              <td headers="rule-review-check" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Scheduled check</span>
                <.link href={"/configuration/" <> row["id"]} target="_blank" rel="noopener">{row[
                  "label"
                ]} <span class="sub">(opens in a new tab)</span></.link><div class="sub">
                  {row["environment"]} · {length(row["outputs"] || [])} results
                </div>
                <div class="sub">
                  {if scope_matches?(@proposal, row),
                    do: "In proposed scope",
                    else: "Leaving this rule's scope"}
                </div>
              </td><td headers="rule-review-current" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Currently saved values</span>
                <.parameter_values
                  params={row["current_params"] || %{}}
                  schema={row["parameter_schema"] || @proposal["parameter_schema"]}
                />
              </td><td headers="rule-review-proposed" role="cell">
                <span class="rule-cell-label" aria-hidden="true">After this rule</span>
                <.parameter_values
                  params={row["proposed_params"] || %{}}
                  schema={row["parameter_schema"] || @proposal["parameter_schema"]}
                />
              </td><td headers="rule-review-outcome" role="cell">
                <span class="rule-cell-label" aria-hidden="true">Outcome and origin</span>
                <span :if={row["error"]} class="form-error">{error_message(row["error"])}</span><span :if={
                  !row["error"]
                }>{if row["changed"], do: "Configuration changes", else: "Configuration unchanged"}
                <div class="sub">{origin_label(row["origin"])}</div></span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <nav :if={pages(@preview) > 1} class="pagination" aria-label="Rule match pages">
        <button
          :if={@page > 1}
          class="button small"
          phx-click="preview_page"
          phx-value-page={@page - 1}
        >Previous</button><span>Page {@page} of {pages(@preview)}</span><button
          :if={@page < pages(@preview)}
          class="button small"
          phx-click="preview_page"
          phx-value-page={@page + 1}
        >Next</button>
      </nav>
      <div class="panel-body">
        <form
          id="configuration-rule-form"
          phx-change="edit"
          phx-submit="save"
          phx-auto-recover="recover"
        >
          <input type="hidden" name="_proposal" value={Jason.encode!(@proposal)} />
          <input type="hidden" name="_environment_scope" value={@environment_scope} />
          <input type="hidden" name="_target_scope" value={@target_scope} />
          <input type="hidden" name="_review_token" value={@token} /><div class="form-actions">
            <button type="button" class="button" phx-click="back">Edit draft</button><button
              class="button primary"
              id="rule-save"
              disabled={!@token}
              phx-disable-with="Saving…"
            >Save rule</button>
          </div>
        </form>
      </div>
    </section>
    """
  end

  defp parameter_values(assigns) do
    ~H"""
    <dl class="rule-values">
      <div :for={{key, value} <- Enum.sort(@params)}>
        <dt>
          {get_in(@schema, ["fields", key, "label"]) || key}<span :if={
            get_in(@schema, ["fields", key, "unit"])
          }> ({get_in(@schema, ["fields", key, "unit"])})</span>
        </dt><dd>
          {if is_binary(value), do: value, else: Jason.encode!(value)}
        </dd>
      </div>
    </dl>
    """
  end

  defp diagnostics(assigns) do
    ~H"""
    <section :if={@entries != []} class="panel space-top" id="rule-diagnostics">
      <div class="panel-heading">
        <h2>Source declarations needing attention</h2>
      </div><div class="panel-body">
        <p>
          These attempted inventories were rejected. Previously accepted checks keep their configuration; a newly declared check may not have been admitted. Correct the rule or source and publish again.
        </p>
        <p class="space-top">
          For a compatible schema change blocked by a rule, restore the previously accepted source, or disable the rule through Preview, publish the new source, then load a current check's schema and review the rule before enabling it again. Changing parameter types or units requires a new check identity and a new parameter contract for the changed meaning.
        </p>
        <ul class="result-links">
          <li :for={entry <- @entries}>
            <div>
              <strong>{entry["source_id"]} · {entry["source_key"]}</strong><p>{entry["message"]}</p><.link
                navigate="/runners"
                class="text-link"
              >Inspect runner diagnostics</.link>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp refresh_list(socket),
    do: assign(socket, listing: ConfigurationRules.list(socket.assigns.page))

  defp load_proposal(socket, {:ok, proposal}),
    do: assign(socket, rule: nil, proposal: Map.take(proposal, @proposal_fields))

  defp load_proposal(socket, {:error, reason}),
    do: assign(socket, rule: nil, proposal: nil, error: error_message(reason))

  defp keep_draft(%{assigns: %{proposal: nil}} = socket, _form), do: socket

  defp keep_draft(socket, form) do
    modes = form["scope"] || %{}
    environment_scope = modes["environment"] || socket.assigns.environment_scope
    target_scope = modes["target"] || socket.assigns.target_scope

    proposal =
      socket.assigns.proposal
      |> Map.merge(Map.take(form["rule"] || %{}, @editable_fields))
      |> Map.put("params", form["params"] || socket.assigns.proposal["params"])

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

  defp group_path(search, page),
    do: "/configuration/rules/new?" <> URI.encode_query(%{"search" => search, "page" => page})

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

  defp pages(result), do: max(1, ceil((result["total"] || 0) / max(1, result["page_size"] || 25)))
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

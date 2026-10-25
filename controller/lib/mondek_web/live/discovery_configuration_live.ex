# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DiscoveryConfigurationLive do
  use MondekWeb, :live_view
  alias Mondek.{ConfigurationRules, DiscoveryConfiguration, Monitoring}
  alias MondekWeb.{InvestigationNavigation, ParameterForm}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mondek.PubSub, "monitoring")
      Process.send_after(self(), :tick, 1_000)
    end

    {:ok,
     assign(socket,
       page_title: "Resource discovery",
       now: Monitoring.now(),
       navigation_counts: Mondek.Inspection.navigation_counts(Monitoring.now()),
       context: nil,
       receipt: nil,
       error: nil,
       review: nil,
       proposal: nil,
       values: %{},
       scope: "local",
       revision: nil,
       return_to: "/checks",
       id: nil
     )}
  end

  def handle_params(params, _uri, socket) do
    if socket.assigns.live_action == :receipt do
      {:noreply,
       assign(socket,
         id: params["id"],
         receipt: DiscoveryConfiguration.receipt(params["id"]),
         context: nil
       )}
    else
      context = DiscoveryConfiguration.context(params["id"])
      manager = context && context.manager
      scope = if manager && exact_rule?(manager), do: "host", else: "local"

      {:noreply,
       assign(socket,
         context: context,
         id: params["id"],
         receipt: nil,
         review: nil,
         error: nil,
         revision: manager && manager["revision"],
         values: (manager && manager["params"]) || %{},
         scope: scope,
         return_to: InvestigationNavigation.safe_return_path(params["return_to"]) || "/checks"
       )}
    end
  end

  def handle_info(:changed, socket), do: {:noreply, socket}

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)

    socket =
      assign(socket,
        now: Monitoring.now(),
        navigation_counts: Mondek.Inspection.navigation_counts(Monitoring.now())
      )

    if socket.assigns.live_action == :receipt do
      socket = assign(socket, receipt: DiscoveryConfiguration.receipt(socket.assigns.id))
      {:noreply, socket}
    else
      if socket.assigns.context do
        context = DiscoveryConfiguration.context(socket.assigns.id)
        {:noreply, assign(socket, context: context)}
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("edit", form, socket) do
    {:noreply,
     assign(socket,
       revision: parse_revision(form["_revision"], socket.assigns.revision),
       values: form["params"] || socket.assigns.values,
       scope: if(form["scope"] == "host", do: "host", else: "local"),
       review: nil,
       error: nil
     )}
  end

  def handle_event("toggle_resource", _, socket) do
    d = resource(socket.assigns.context)

    if shortcut?(d) do
      toggle_resource(socket, d)
    else
      {:noreply,
       assign(socket,
         error: "This resource name cannot be represented by an exact selection shortcut.",
         review: nil
       )}
    end
  end

  def handle_event("review", form, socket) do
    scope = if form["scope"] == "host", do: "host", else: "local"
    socket = assign(socket, values: form["params"] || socket.assigns.values, scope: scope)
    manager = socket.assigns.context.manager

    result =
      with {:ok, params} <-
             ParameterForm.parse(
               manager["parameter_schema"],
               form["params"] || socket.assigns.values
             ) do
        if manager["revision"] != parse_revision(form["_revision"], socket.assigns.revision) do
          {:error, :stale}
        else
          if scope == "host" do
            with {:ok, proposal} <- DiscoveryConfiguration.host_proposal(manager, params),
                 {:ok, preview} <- ConfigurationRules.preview(proposal),
                 do: {:ok, preview, proposal}
          else
            with {:ok, preview} <-
                   ConfigurationRules.preview_instance(
                     manager["id"],
                     socket.assigns.revision,
                     params
                   ),
                 do: {:ok, preview, nil}
          end
        end
      end

    case result do
      {:ok, preview, proposal} ->
        {:noreply, assign(socket, review: preview, proposal: proposal, scope: scope, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error(reason), review: nil)}
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
    case DiscoveryConfiguration.save(
           socket.assigns.context,
           socket.assigns.scope,
           socket.assigns.review,
           socket.assigns.proposal
         ) do
      {:ok, receipt} ->
        {:noreply, push_navigate(socket, to: "/configuration/discovery/changes/" <> receipt.id)}

      {:error, reason} ->
        {:noreply, assign(socket, error: error(reason), review: nil)}
    end
  end

  def handle_event("back", _, socket), do: {:noreply, assign(socket, review: nil)}

  def handle_event("reload", _, socket) do
    context = DiscoveryConfiguration.context(socket.assigns.id)

    {:noreply,
     assign(socket,
       context: context,
       revision: context.manager["revision"],
       values: context.manager["params"],
       review: nil,
       error: nil
     )}
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

    ~H"""
    <MondekWeb.Layouts.app
      active={:configuration}
      page_title="Resource discovery"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
    >
      <div class="discovery-configuration">
        <.link navigate={@return_to} class="back">Back to monitoring</.link>
        <h1>Resource discovery</h1>
        <p :if={!@context && !@receipt} class="notice warn">
          Discovery relationship unavailable. No managing check is inferred from names or groups.
        </p>
        <p :if={@error} role="alert" id="discovery-config-error" class="notice warn">{@error}</p>
        <div :if={@context}>
          <dl class="result-context" id="discovery-config-subject">
            <div>
              <dt>Monitored host</dt><dd>{@target["label"] || @target["key"]}</dd>
            </div>
            <div>
              <dt>Monitored environment</dt><dd>
                {@manager["environment_label"] || @manager["environment"]}
              </dd>
            </div>
            <div>
              <dt>Observing runner</dt><dd>{@manager["runner_label"] || @manager["runner_id"]}</dd>
            </div>
          </dl>
          <p>Current settings: {origin(@manager)}.</p>
          <p :if={@manager["revision"] != @revision} class="notice warn">
            Saved settings changed while you were editing. Your draft is retained.
            <button class="button" phx-click="reload">Reload current values</button>
          </p>
          <section :if={!@review} class="panel panel-body">
            <form id="discovery-config-form" phx-change="edit" phx-submit="review">
              <input type="hidden" name="_revision" value={@revision} />
              <fieldset>
                <legend>Scope of this change</legend>
                <p>
                  Both options apply only to resource discovery for
                  <strong>{@target["label"] || @target["key"]}</strong>
                  in {@manager["environment_label"] || @manager["environment"]}. Other hosts on the same observer are unaffected.
                </p>
                <label class="discovery-scope-choice">
                  <input
                    id="discovery-scope-local"
                    type="radio"
                    name="scope"
                    value="local"
                    checked={@scope == "local"}
                  /> Only this discovery check
                  <small>This host through one current observer, including resources this check discovers later. Does not follow a replacement observer.</small>
                </label>
                <label class="discovery-scope-choice">
                  <input
                    id="discovery-scope-host"
                    type="radio"
                    name="scope"
                    value="host"
                    checked={@scope == "host"}
                  /> Host policy for {@target["label"] || @target["key"]}
                  <small>{@observer_count} current {if @observer_count == 1,
                    do: "observer",
                    else: "observers"}, plus future compatible observers of this exact host in this environment. Review lists current matches and masked local overrides.</small>
                </label>
              </fieldset>
              <p :if={@scope == "host" && @manager["instance_exception"]} class="notice warn">
                Local settings still take precedence. Saving host policy does not remove this check's override; review its removal separately.
              </p>
              <div
                :if={shortcut?(@resource)}
                class="space-top"
              >
                <button
                  id="toggle-discovered-resource"
                  type="button"
                  class="button"
                  phx-click="toggle_resource"
                >{if excluded?(@values, @resource),
                  do: "Remove exact exclusion",
                  else: "Add exact exclusion"}: {@resource["resource_name"]}</button>
                <p>
                  Only optional discovered resources can be excluded. Required resources remain monitored. Removing an exact exclusion does not override other matching exclusion patterns.
                </p>
              </div>
              <p :if={@resource["origin"] == "required"} class="notice">
                This resource is required by code. Discovery exclusions cannot remove it; change the monitoring project's declaration.
              </p>
              <p :if={@resource["resource_kind"]} class="footnote">
                Draft exclusions: <code>{@values[@resource["resource_kind"] <> "_exclude"]}</code>. Review and save to apply this change.
              </p>
              <details
                id="discovery-all-values"
                open={@resource == %{}}
                phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
              >
                <summary>All selection values saved with this change</summary>
                <ParameterForm.fields
                  id_prefix="discovery-param"
                  schema={@manager["parameter_schema"]}
                  values={@values}
                  error={@error}
                  error_id="discovery-config-error"
                />
              </details>
              <p>
                The complete parameter set is saved together, including unchanged filesystem values. These values do not inherit later rule/default changes field by field.
              </p>
              <p :if={@scope == "host"}>
                A new runner can initially discover using code defaults until it adopts the host policy.
              </p>
              <button class="button primary" phx-disable-with="Reviewing…">Review change</button>
            </form>
          </section>
          <section
            :if={@review}
            id="discovery-config-review"
            class="panel panel-body"
            tabindex="-1"
            phx-mounted={Phoenix.LiveView.JS.focus(to: "#discovery-config-review")}
          >
            <h2>Review discovery settings</h2>
            <p>
              {@target["label"] || @target["key"]} · {@manager["environment_label"] ||
                @manager["environment"]} · {if @scope == "host",
                do: "current and future compatible observers of this host",
                else: "this discovery check only"}
            </p>
            <p>This saves the complete selection parameter set. Changed values are marked below.</p>
            <dl class="kv-list">
              <div :for={{key, value} <- Enum.sort(review_values(@review, @proposal))} class="kv">
                <dt>
                  {ParameterForm.field_label(@manager["parameter_schema"], key)}
                  <strong :if={value != @manager["params"][key]}>Changed</strong>
                </dt><dd>{inspect(value)}</dd>
              </div>
            </dl>
            <div :if={@scope == "host"}>
              <p>
                {@review["counts"]["changed"]} checks change · {@review["counts"]["exceptions"] || 0} masked · {@review[
                  "counts"
                ]["conflicts"]} conflicts.
              </p>
              <div :for={row <- @review["rows"] || []} class="space-top">
                <p>
                  {row["label"]} · {row["environment"]} · observer {observer_label(row["runner_id"])}
                </p><p>
                  {if row["instance_exception"],
                    do: "Local override remains in force",
                    else: if(row["changed"], do: "Settings change", else: "Settings unchanged")}
                </p><p :if={row["error"]} class="notice warn">{row["error"]}</p><.link
                  :for={id <- row["rule_ids"] || []}
                  navigate={"/configuration/rules/" <> id}
                >Inspect conflicting rule</.link><.link
                  :if={
                    get_in(row, ["origin", "kind"]) == "rule" &&
                      get_in(row, ["origin", "rule_id"]) !=
                        (@proposal["id"] || "00000000-0000-0000-0000-000000000000")
                  }
                  navigate={"/configuration/rules/" <> row["origin"]["rule_id"]}
                >Inspect effective shared rule</.link>
              </div>
              <p :if={!@review["review_token"]} class="notice warn">
                Resolve conflicting shared rules before saving, or go back and choose only this discovery check. No priority is raised automatically.
              </p>
              <p :if={DiscoveryConfiguration.host_shadowed?(@review, @proposal)} class="notice warn">
                Another shared rule remains effective. Inspect that rule or go back and choose only this discovery check.
              </p>
              <p :if={@review["total"] > length(@review["rows"] || [])} class="footnote">
                Showing {length(@review["rows"])} of {@review["total"]} reviewed checks. Counts and save validation cover every match.
              </p>
            </div>
            <p>
              Saving is not retirement. The runner must activate settings and publish a successful inventory. Fresh discovery measurements are separate evidence. Exclusions apply to optional resources on later scans; actual membership may also depend on other selection values and source declarations.
            </p>
            <button type="button" class="button" phx-click="back">Back to editing</button>
            <button
              :if={
                @review["review_token"] &&
                  (@scope != "host" || !DiscoveryConfiguration.host_shadowed?(@review, @proposal))
              }
              id="save-discovery-change"
              class="button primary"
              phx-click="save"
              phx-disable-with="Saving…"
            >Save reviewed change</button>
          </section>
        </div>
        <section :if={@receipt} class="panel panel-body" id="discovery-change-receipt">
          <h2>
            {if @receipt.historical?, do: "Earlier change receipt", else: "Saved discovery change"}
          </h2><p>
            {get_in(@receipt.change.resource, ["subject", "outputs", Access.at(0), "target", "label"])} · {get_in(
              @receipt.change.resource,
              ["subject", "environment_label"]
            ) || get_in(@receipt.change.resource, ["subject", "environment"])}
          </p><p>
            Saved at {DateTime.to_iso8601(@receipt.change.saved_at)} · {if @receipt.change.scope ==
                                                                             "host",
                                                                           do: "host policy",
                                                                           else: "one discovery check"}. This receipt records this change; completed outcomes are historical.
          </p>
          <div :for={member <- @receipt.members} class="space-top">
            <h3>{(member.assignment || %{})["runner_label"] || member.receipt["runner_id"]}</h3>
            <p role="status">{status(member.status)}</p>
            <.link
              :if={member.resource_stream_id}
              navigate={"/checks/" <> member.resource_stream_id}
              class="button"
            >Inspect resource results and history</.link>
            <p :if={
              member.status == "inventory_accepted" && !is_nil(member.receipt["resource_present"])
            }>
              {if member.receipt["resource_present"],
                do:
                  "The accepted inventory includes this resource. Its active observation needs its own fresh evidence.",
                else:
                  "The accepted inventory no longer includes this resource. Its former observation is retired administratively; historical failure evidence is retained."}
            </p>
            <p :if={member.assignment}>
              Discovery measurement: {if member.assignment["observed_generation"] ==
                                           member.assignment["desired_generation"],
                                         do:
                                           "current saved generation measured; inspect results for freshness",
                                         else: "no measurement of the current saved generation yet"}. Independent of inventory acceptance.
            </p>
            <.link
              :if={member.status == "masked"}
              navigate={"/configuration/" <> member.receipt["id"] <> "?" <> URI.encode_query(%{"return_to" => "/configuration/discovery/changes/" <> @receipt.change.id})}
              class="button"
            >Review local override removal</.link>
            <.link navigate={"/configuration/discovery/" <> member.receipt["id"]} class="button">Inspect current discovery settings</.link>
          </div>
          <p>Receipt ID: {@receipt.change.id}</p>
        </section>
      </div>
    </MondekWeb.Layouts.app>
    """
  end

  defp parse_revision(value, default) do
    case Integer.parse(to_string(value || "")) do
      {number, ""} -> number
      _ -> default
    end
  end

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

  defp shortcut?(d),
    do:
      d["origin"] == "discovered" and is_binary(d["resource_name"]) and
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

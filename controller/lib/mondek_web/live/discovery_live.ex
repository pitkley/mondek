# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DiscoveryLive do
  use MondekWeb, :live_view

  alias Mondek.{Discovery, Inspection, Monitoring}
  alias MondekWeb.{AgentPrompts, CheckInventory, InvestigationNavigation, Layouts, ParameterForm}

  @token_salt "discovery-review-v1"
  @max_token_bytes 262_144
  @max_form_bytes 131_072

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       page_title: "Review discovered resources",
       stream_id: nil,
       return_to: nil,
       current: nil,
       frozen: nil,
       snapshot_token: nil,
       draft: %{},
       reviewed: nil,
       prompt: nil,
       error: nil,
       now: Monitoring.now(),
       snapshot: %{}
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, stream_id: params["id"], return_to: safe_return(params["return_to"]))
    {:noreply, socket |> refresh() |> adopt_current()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event(event, form, socket) when event in ["edit", "recover"] do
    with true <- bounded_form?(form),
         {:ok, frozen} <- recover_snapshot(form["snapshot"], socket.assigns.stream_id) do
      previous = if event == "recover", do: %{}, else: socket.assigns.draft

      socket =
        socket
        |> assign(
          frozen: frozen,
          snapshot_token: form["snapshot"],
          draft: draft(form["selections"], frozen, previous, event == "recover"),
          reviewed: nil,
          prompt: nil,
          error: nil
        )
        |> refresh()

      {:noreply, socket}
    else
      _ ->
        {:noreply,
         assign(socket,
           error:
             "This draft could not be recovered. Reload the latest discovery before selecting again.",
           reviewed: nil,
           prompt: nil
         )}
    end
  end

  def handle_event("reload", _params, socket),
    do: {:noreply, socket |> refresh() |> adopt_current()}

  def handle_event("review", form, socket) do
    socket = refresh(socket)

    with true <- ready?(socket.assigns),
         true <- bounded_form?(form),
         true <- form["snapshot"] == socket.assigns.snapshot_token,
         updated <- draft(form["selections"], socket.assigns.frozen, socket.assigns.draft, true),
         {:ok, selections} <- selections(updated, socket.assigns.frozen),
         {:ok, review} <-
           Discovery.review(
             socket.assigns.stream_id,
             socket.assigns.frozen["fingerprint"],
             selections
           ) do
      {:noreply, assign(socket, draft: updated, reviewed: review, prompt: nil, error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: reason, reviewed: nil, prompt: nil)}

      _ ->
        {:noreply,
         assign(socket,
           error:
             "Review requires the current, fresh discovery. Reload changed evidence before continuing.",
           reviewed: nil,
           prompt: nil
         )}
    end
  end

  def handle_event("generate", _params, socket) do
    socket = refresh(socket)

    with true <- ready?(socket.assigns),
         %{"selections" => selections} <- socket.assigns.reviewed,
         {:ok, review} <-
           Discovery.review(
             socket.assigns.stream_id,
             socket.assigns.frozen["fingerprint"],
             selections
           ) do
      {:noreply, assign(socket, reviewed: review, prompt: review["prompt"], error: nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: reason, reviewed: nil, prompt: nil)}

      _ ->
        {:noreply,
         assign(socket,
           error:
             "Review the selected proposals against fresh discovery before generating a prompt.",
           reviewed: nil,
           prompt: nil
         )}
    end
  end

  defp refresh(socket) do
    now = Monitoring.now()
    current = socket.assigns.stream_id && Discovery.inspect(socket.assigns.stream_id, now)

    socket =
      assign(socket, now: now, current: current, snapshot: Inspection.navigation_counts(now))

    if ready?(socket.assigns),
      do: socket,
      else: assign(socket, reviewed: nil, prompt: nil)
  end

  defp adopt_current(%{assigns: %{current: nil}} = socket), do: socket

  defp adopt_current(socket) do
    current = socket.assigns.current

    frozen =
      current
      |> Map.take(~w(discovery fingerprint observation_id source_at))
      |> Map.put(
        "stream",
        Map.take(
          current["stream"] || %{},
          ~w(id label result_key target environment environment_label runner_label runner_id assignment_id)
        )
      )
      |> Map.put(
        "assignment",
        Map.take(
          current["assignment"] || %{},
          ~w(id label source_id source_revision desired_generation)
        )
      )

    assign(socket,
      frozen: frozen,
      snapshot_token: Phoenix.Token.sign(MondekWeb.Endpoint, @token_salt, frozen),
      draft: draft(%{}, frozen, %{}, false),
      reviewed: nil,
      prompt: nil,
      error: nil
    )
  end

  defp recover_snapshot(token, stream_id)
       when is_binary(token) and byte_size(token) <= @max_token_bytes do
    with {:ok, %{"stream" => %{"id" => ^stream_id}} = frozen} <-
           Phoenix.Token.verify(MondekWeb.Endpoint, @token_salt, token, max_age: 86_400),
         true <- is_map(frozen["discovery"]) do
      {:ok, frozen}
    else
      _ -> :error
    end
  end

  defp recover_snapshot(_, _), do: :error

  defp bounded_form?(form) when is_map(form) do
    selections = Map.get(form, "selections", %{})

    is_map(selections) && map_size(selections) <= 100 &&
      Enum.all?(selections, fn {index, entry} ->
        is_binary(index) && is_map(entry) &&
          entry["selected"] in [nil, true, false, "true", "false"] &&
          (is_nil(entry["choice_key"]) || is_binary(entry["choice_key"])) &&
          valid_draft_params?(entry["params"] || %{})
      end) && byte_size(Jason.encode!(selections)) <= @max_form_bytes
  end

  defp bounded_form?(_), do: false

  defp valid_draft_params?(params) when is_map(params) and map_size(params) <= 8,
    do:
      Enum.all?(params, fn {key, value} ->
        is_binary(key) && (is_binary(value) || is_number(value) || is_boolean(value))
      end)

  defp valid_draft_params?(_), do: false

  defp draft(raw, frozen, previous, recovering) do
    raw = if is_map(raw), do: raw, else: %{}
    choices = Map.new(frozen["discovery"]["choices"], &{&1["key"], &1})

    frozen["discovery"]["candidates"]
    |> Enum.with_index()
    |> Map.new(fn {_candidate, index} ->
      key = to_string(index)
      entry = if is_map(raw[key]), do: raw[key], else: %{}
      choice = choices[entry["choice_key"]]
      choice_key = if choice, do: choice["key"], else: ""
      values = if is_map(entry["params"]), do: entry["params"], else: %{}
      same_choice = get_in(previous, [key, "choice_key"]) == choice_key

      params =
        if choice do
          defaults = choice["params"] || %{}

          if recovering || same_choice,
            do:
              Map.merge(
                defaults,
                Map.take(values, Map.keys(choice["parameter_schema"]["fields"]))
              ),
            else: defaults
        else
          %{}
        end

      {key,
       %{
         "selected" => entry["selected"] in [true, "true"],
         "choice_key" => choice_key,
         "params" => params
       }}
    end)
  end

  defp selections(draft, frozen) do
    choices = Map.new(frozen["discovery"]["choices"], &{&1["key"], &1})

    result =
      frozen["discovery"]["candidates"]
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {candidate, index}, {:ok, selected} ->
        entry = draft[to_string(index)]

        if entry["selected"] do
          case choices[entry["choice_key"]] do
            nil ->
              {:halt, {:error, "Choose a proposal for #{candidate["label"]}."}}

            choice ->
              case ParameterForm.parse(choice["parameter_schema"], entry["params"]) do
                {:ok, params} ->
                  {:cont,
                   {:ok,
                    selected ++
                      [
                        %{
                          "candidate_key" => candidate["key"],
                          "choice_key" => choice["key"],
                          "params" => params
                        }
                      ]}}

                {:error, reason} ->
                  {:halt, {:error, "#{candidate["label"]}: #{reason}"}}
              end
          end
        else
          {:cont, {:ok, selected}}
        end
      end)

    case result do
      {:ok, []} ->
        {:error,
         "Select at least one discovered resource and explicitly choose its proposed configuration."}

      other ->
        other
    end
  end

  defp ready?(%{current: current, frozen: frozen}) do
    is_map(current) && is_map(frozen) && current["reviewable"] == true &&
      current["fingerprint"] == frozen["fingerprint"]
  end

  defp changed?(%{current: current, frozen: frozen}),
    do: is_map(frozen) && (is_nil(current) || current["fingerprint"] != frozen["fingerprint"])

  def path(id, return_to \\ nil),
    do: with_return("/checks/" <> id <> "/discovery", safe_return(return_to))

  defp incident_return?(path), do: is_binary(path) && String.starts_with?(path, "/incidents/")

  defp result_path(id, return_to), do: with_return("/checks/" <> id, return_to)
  defp with_return(path, nil), do: path

  defp with_return(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp safe_return("/"), do: "/"

  defp safe_return(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if is_nil(uri.scheme) && is_nil(uri.host) && is_nil(uri.fragment) do
      cond do
        uri.path == "/checks" ->
          (uri.query || "")
          |> URI.decode_query()
          |> CheckInventory.normalize()
          |> CheckInventory.path()

        is_binary(uri.path) && String.starts_with?(uri.path, "/incidents/") ->
          InvestigationNavigation.safe_return_path(value)

        true ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  defp safe_return(_), do: nil

  @impl true
  def render(assigns) do
    changed = changed?(assigns)

    assigns =
      assign(assigns,
        ready: ready?(assigns),
        changed: changed,
        evidence: if(changed, do: assigns.frozen, else: assigns.current || assigns.frozen)
      )

    ~H"""
    <Layouts.app
      active={:checks}
      page_title={@page_title}
      snapshot={@snapshot}
      now={@now}
      flash={@flash}
    >
      <div class="discovery-page">
        <.link
          navigate={
            if incident_return?(@return_to), do: @return_to, else: result_path(@stream_id, @return_to)
          }
          class="back"
          id="discovery-back"
        >← {if incident_return?(@return_to), do: "Back to incident", else: "Back to result"}</.link>
        <div class="page-heading">
          <div>
            <div class="eyebrow">Source-owned monitoring</div><h1>Review discovered resources</h1>
            <p>
              Choose proposals to take back to your monitoring project. This review does not change monitoring or acknowledge an incident.
            </p>
          </div>
        </div>
        <p :if={!@frozen} id="discovery-missing" class="notice">
          No retained discovery is available for this result. Return to the result to inspect its latest evidence.
        </p>
        <div :if={@frozen}>
          <section class="panel">
            <div class="panel-heading">
              <div>
                <h2>{@frozen["discovery"]["title"]}</h2><p>{@frozen["discovery"]["instructions"]}</p>
              </div>
            </div>
            <div class="panel-body">
              <dl class="discovery-evidence">
                <div>
                  <dt>Result</dt><dd>
                    {@frozen["stream"]["label"] || @frozen["stream"]["result_key"]}
                  </dd>
                </div>
                <div>
                  <dt>Observing runner</dt><dd>
                    {@frozen["stream"]["runner_label"] || @frozen["stream"]["runner_id"]}
                  </dd>
                </div>
                <div>
                  <dt>Monitored environment</dt><dd>
                    {@frozen["stream"]["environment_label"] || @frozen["stream"]["environment"] ||
                      "Not declared"}
                  </dd>
                </div>
                <div>
                  <dt>Discovery measured</dt><dd>
                    <time datetime={@evidence["source_at"]}>{@evidence["source_at"] || "Not recorded"}</time>
                  </dd>
                </div>
              </dl>
              <p :if={@changed} id="discovery-changed" class="notice warn">
                Discovery or its source configuration changed. Your previous selections are retained below for reference. Reload the latest discovery and choose again before reviewing.
              </p>
              <p :if={!@changed && !@ready} id="discovery-unavailable" class="notice warn">
                {(@current && @current["reason"]) ||
                  "Fresh, current discovery is required to review proposals."} Previous selections remain visible; retained evidence cannot authorize a proposal.
              </p>
              <button
                :if={@changed}
                id="discovery-reload"
                type="button"
                class="button space-top"
                phx-click="reload"
                disabled={!@current}
              >Reload latest discovery and clear selections</button>
              <p
                :if={(@frozen["discovery"]["omitted"] || 0) > 0}
                id="discovery-omitted"
                class="notice space-top"
              >
                {@frozen["discovery"]["omitted"]} additional resources were omitted by the source. This review covers only the listed candidates.
              </p>
              <p :if={@frozen["discovery"]["candidates"] == []} class="empty">
                No resources are currently proposed for review.
              </p>
              <p :if={@error} id="discovery-error" class="form-error" role="alert">{@error}</p>
              <form
                id="discovery-review-form"
                phx-change="edit"
                phx-auto-recover="recover"
                phx-submit="review"
              >
                <input type="hidden" name="snapshot" value={@snapshot_token} />
                <ul class="discovery-candidates">
                  <.candidate
                    :for={{candidate, index} <- Enum.with_index(@frozen["discovery"]["candidates"])}
                    candidate={candidate}
                    index={index}
                    choices={@frozen["discovery"]["choices"]}
                    draft={@draft[to_string(index)]}
                    ready={@ready}
                  />
                </ul>
                <div class="form-actions">
                  <button
                    id="discovery-review"
                    type="submit"
                    class="button primary"
                    disabled={!@ready || @frozen["discovery"]["candidates"] == []}
                  >Review proposed changes</button>
                </div>
              </form>
            </div>
          </section>
          <section
            :if={@reviewed}
            id="discovery-proposal-review"
            class="panel space-top"
            aria-labelledby="discovery-proposal-heading"
          >
            <div class="panel-heading">
              <h2 id="discovery-proposal-heading">Proposed source changes</h2>
            </div>
            <div class="panel-body">
              <p>
                Review these explicit choices. Generating a prompt prepares instructions for a coding agent; nothing is saved to your monitoring project or controller.
              </p>
              <ul class="discovery-reviewed space-top">
                <.reviewed_choice
                  :for={selection <- @reviewed["selections"]}
                  selection={selection}
                  discovery={@frozen["discovery"]}
                />
              </ul>
              <button
                id="discovery-generate"
                type="button"
                phx-click="generate"
                class="button primary space-top"
                disabled={!@ready}
              >Generate agent prompt</button>
              <AgentPrompts.supplied_prompt
                :if={@prompt}
                id="discovery-prompt"
                title="Implement reviewed monitoring proposals"
                text={@prompt}
                notice="Review before sharing. This prompt includes the selected discovered identities, source-owned descriptions and your proposed parameter values. Check it for sensitive information before copying. Mondek does not send it."
              />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp candidate(assigns) do
    assigns =
      assign(assigns,
        choice: Enum.find(assigns.choices, &(&1["key"] == assigns.draft["choice_key"])),
        prefix: "selections[#{assigns.index}]"
      )

    ~H"""
    <li
      id={"discovery-candidate-#{@index}"}
      class={["discovery-candidate", @draft["selected"] && "discovery-candidate-selected"]}
    >
      <label class="discovery-select" for={"discovery-select-#{@index}"}>
        <input
          type="hidden"
          name={@prefix <> "[selected]"}
          value={if !@ready && @draft["selected"], do: "true", else: "false"}
        />
        <input
          id={"discovery-select-#{@index}"}
          type="checkbox"
          name={@prefix <> "[selected]"}
          value="true"
          checked={@draft["selected"]}
          disabled={!@ready}
        />
        <span>{@candidate["label"]}</span>
      </label>
      <p :if={@candidate["details"]} class="discovery-candidate-details">{@candidate["details"]}</p>
      <p class="footnote">Resource identity: <code>{@candidate["key"]}</code></p>
      <fieldset :if={@draft["selected"]} disabled={!@ready}>
        <legend>Proposal for {@candidate["label"]}</legend>
        <div class="field">
          <label for={"discovery-choice-#{@index}"}>Proposed configuration</label>
          <select id={"discovery-choice-#{@index}"} name={@prefix <> "[choice_key]"}>
            <option value="" selected={@draft["choice_key"] == ""}>Choose a proposal</option>
            <option
              :for={choice <- @choices}
              value={choice["key"]}
              selected={@draft["choice_key"] == choice["key"]}
            >
              {choice["label"]}
            </option>
          </select>
        </div>
        <p :if={@choice} class="footnote space-top">{@choice["description"]}</p>
        <ParameterForm.fields
          :if={@choice}
          id_prefix={"discovery-params-#{@index}"}
          name_prefix={@prefix <> "[params]"}
          schema={@choice["parameter_schema"]}
          values={@draft["params"]}
          fixed_hint="This value is fixed by the source-declared proposal."
        />
      </fieldset>
      <input
        :if={!@ready && @draft["selected"]}
        type="hidden"
        name={@prefix <> "[choice_key]"}
        value={@draft["choice_key"]}
      />
      <input
        :for={{key, value} <- if(!@ready && @draft["selected"], do: @draft["params"], else: %{})}
        type="hidden"
        name={@prefix <> "[params][" <> key <> "]"}
        value={ParameterForm.input_value(value)}
      />
    </li>
    """
  end

  defp reviewed_choice(assigns) do
    assigns =
      assign(assigns,
        candidate:
          Enum.find(
            assigns.discovery["candidates"],
            &(&1["key"] == assigns.selection["candidate_key"])
          ),
        choice:
          Enum.find(assigns.discovery["choices"], &(&1["key"] == assigns.selection["choice_key"]))
      )

    ~H"""
    <li>
      <strong>{@candidate["label"]}</strong><p>{@choice["label"]}</p>
      <dl>
        <div :for={{key, value} <- Enum.sort(@selection["params"])}>
          <dt>
            {ParameterForm.field_label(@choice["parameter_schema"], key)}<span :if={
              get_in(@choice, ["parameter_schema", "fields", key, "unit"])
            }> ({get_in(@choice, ["parameter_schema", "fields", key, "unit"])})</span>
          </dt>
          <dd>{ParameterForm.input_value(value)}</dd>
        </div>
      </dl>
    </li>
    """
  end
end

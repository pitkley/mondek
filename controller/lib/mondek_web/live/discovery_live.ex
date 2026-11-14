# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DiscoveryLive do
  use MondekWeb, :live_view

  alias Mondek.{Discovery, Monitoring}

  alias MondekWeb.{
    AgentPrompts,
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    ParameterForm,
    PreviewDetail,
    PreviewFilters,
    PreviewLayouts,
    ScalarFilterPicker
  }

  @token_salt "discovery-review-v1"
  @max_token_bytes 262_144
  @max_form_bytes 131_072
  @page_size 25
  @unchosen_proposal "$unchosen"
  @filter_fields [{"selection", "Selection", "check"}, {"proposal", "Proposal", "sliders"}]

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
       filters: %{},
       filter_picker: nil,
       investigation_host: nil,
       investigation_params: %{},
       investigation_selection: "",
       investigation_page: false,
       investigation_active: false,
       investigation_heading: "discovery-heading"
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    same_entity = socket.assigns.stream_id == params["id"]
    local = URI.parse(uri)
    filters = filter_params(params)
    promoted_page = not is_nil(InvestigationTrail.promoted(params))

    socket =
      assign(socket,
        stream_id: params["id"],
        return_to: safe_return(params["return_to"]),
        filters: filters,
        filter_picker: if(filters == socket.assigns.filters, do: socket.assigns.filter_picker),
        investigation_host: local.path <> if(local.query, do: "?" <> local.query, else: ""),
        investigation_params: params,
        investigation_selection: InvestigationTrail.selection(params),
        investigation_page: promoted_page,
        investigation_active: InvestigationTrail.resolve(params) != [],
        investigation_heading: InvestigationTrail.heading(params, "discovery-heading")
      )

    socket =
      if same_entity,
        do: socket,
        else:
          assign(socket,
            frozen: nil,
            snapshot_token: nil,
            draft: %{},
            reviewed: nil,
            prompt: nil,
            error: nil
          )

    socket = refresh(socket)
    {:noreply, if(same_entity, do: socket, else: adopt_current(socket))}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{investigation_active: true}} = socket)
      when event != "recover", do: {:noreply, socket}

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

  def handle_event("search", %{"search" => value}, socket),
    do: patch_filters(socket, %{"search" => ScalarFilterPicker.text(value)})

  def handle_event("filter_open", %{"field" => field}, socket) do
    case picker(socket.assigns, field, "") do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply,
         assign(socket, filter_picker: %{draft | value: selected_label(socket.assigns, field)})}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket), do: {:noreply, ready(socket)}
  def handle_event("filter_close", _, socket), do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do: patch_filters(ready(socket), %{field => ""})

  def handle_event(
        event,
        %{"search" => value},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ["filter_query", "filter_first"] do
    draft = picker(socket.assigns, field, value)

    case {event, draft.options} do
      {"filter_first", [option | _]} -> patch_filters(ready(socket), %{field => option.key})
      _ -> {:noreply, assign(socket, filter_picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_filters(ready(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp ready(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp picker(assigns, field, value),
    do: ScalarFilterPicker.draft(@filter_fields, &choices(assigns, &1), field, value, [nil, ""])

  defp selected_label(assigns, field),
    do: ScalarFilterPicker.label(choices(assigns, field), assigns.filters[field])

  defp choices(_, "selection"), do: [{"selected", "Selected"}, {"unselected", "Not selected"}]

  defp choices(assigns, "proposal"),
    do: [
      {@unchosen_proposal, "No proposal chosen"}
      | Enum.map(
          get_in(assigns.frozen || %{}, ["discovery", "choices"]) || [],
          &{&1["key"], &1["label"]}
        )
    ]

  defp filter_params(params) do
    params
    |> Map.take(~w(search selection proposal page))
    |> Enum.filter(fn {_, value} ->
      is_binary(value) && byte_size(value) <= 800 && String.valid?(value) &&
        !String.contains?(value, <<0>>)
    end)
    |> Map.new()
  end

  defp patch_filters(socket, changes) do
    filters =
      socket.assigns.filters |> Map.merge(changes) |> Map.delete("page") |> filter_params()

    {:noreply, push_patch(socket, to: list_path(socket.assigns, filters))}
  end

  defp list_path(assigns, filters) do
    params =
      if assigns.return_to, do: Map.put(filters, "return_to", assigns.return_to), else: filters

    path = URI.parse(assigns.investigation_host).path
    query = params |> Map.reject(fn {_, value} -> value in [nil, ""] end) |> URI.encode_query()
    path <> if(query == "", do: "", else: "?" <> query)
  end

  defp refresh(socket) do
    now = Monitoring.now()
    current = socket.assigns.stream_id && Discovery.inspect(socket.assigns.stream_id, now)
    socket = assign(socket, now: now, current: current)
    if ready?(socket.assigns), do: socket, else: assign(socket, reviewed: nil, prompt: nil)
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

  defp result_path(id),
    do: "/results/" <> URI.encode(id || "", &URI.char_unreserved?/1) <> "/full"

  defp with_return(path, nil), do: path

  defp with_return(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp safe_return(value), do: BrowserNavigation.return_path(value)

  @impl true
  def render(assigns) do
    changed = changed?(assigns)

    assigns =
      assign(assigns,
        ready: ready?(assigns),
        changed: changed,
        evidence: if(changed, do: assigns.frozen, else: assigns.current || assigns.frozen),
        filter_fields: @filter_fields,
        selected_count: Enum.count(assigns.draft, fn {_, entry} -> entry["selected"] end),
        filter_chips:
          ScalarFilterPicker.chips(@filter_fields, assigns.filters, &choices(assigns, &1), [
            nil,
            ""
          ])
      )

    assigns = assign(assigns, candidate_page: candidate_page(assigns))

    ~H"""
    <div
      id="discovery-shell"
      phx-hook="OverviewPanel"
      data-selection={@investigation_selection}
      data-panel-heading={@investigation_heading}
      data-panel-background=".preview-masthead,.preview-sidebar,#discovery-workflow,.preview-skip"
    >
      <PreviewLayouts.app
        active={:checks}
        page_title={@page_title}
        flash={@flash}
        main_class="discovery-page"
      >
        <div id="discovery-workflow" hidden={@investigation_page} inert={@investigation_active}>
          <section class="preview-list" aria-labelledby="discovery-heading">
            <header class="preview-heading">
              <h1 id="discovery-heading" tabindex="-1" class="pf-v6-c-title pf-m-2xl">
                Review discovered resources
              </h1>
              <.link
                navigate={@return_to || result_path(@stream_id)}
                id="discovery-back"
                class="pf-v6-c-button pf-m-link"
              >Back to investigation</.link>
            </header>
            <p class="discovery-intro">
              Choose source changes to take back to your monitoring project. This review does not change monitoring or acknowledge an incident.
            </p>
            <p :if={!@frozen} id="discovery-missing" class="preview-empty">
              No retained discovery is available for this result. Open its current evidence to investigate.
            </p>
            <div class="discovery-evidence-action">
              <.link
                patch={InvestigationTrail.path(@investigation_host, [{"result", @stream_id}])}
                data-overview-open
                id="discovery-current-result"
                class="pf-v6-c-button pf-m-secondary"
              >View current result</.link>
            </div>
          </section>
          <%= if @frozen do %>
            <PreviewDetail.card
              id="discovery-evidence"
              title={@frozen["discovery"]["title"]}
              level={2}
            >
              <p class="discovery-intro">{@frozen["discovery"]["instructions"]}</p>
              <PreviewDetail.facts label="Discovery evidence">
                <tr>
                  <th scope="row">Result</th><td>
                    {@frozen["stream"]["label"] || @frozen["stream"]["result_key"]}
                  </td>
                </tr>
                <tr>
                  <th scope="row">Observing runner</th><td>
                    {@frozen["stream"]["runner_label"] || @frozen["stream"]["runner_id"]}
                  </td>
                </tr>
                <tr>
                  <th scope="row">Monitored environment</th><td>
                    {@frozen["stream"]["environment_label"] || @frozen["stream"]["environment"] ||
                      "Not declared"}
                  </td>
                </tr>
                <tr>
                  <th scope="row">Discovery measured</th><td>
                    <time datetime={@evidence["source_at"]}>{MondekWeb.EvidencePresentation.time(
                      @evidence["source_at"]
                    )}</time>
                  </td>
                </tr>
              </PreviewDetail.facts>
              <p :if={@changed} id="discovery-changed" class="discovery-notice" role="status">
                Discovery or its source configuration changed. Your previous selections are retained below for reference. Reload the latest discovery and choose again before reviewing.
              </p>
              <p :if={!@changed && !@ready} id="discovery-unavailable" class="discovery-notice">
                {(@current && @current["reason"]) ||
                  "Fresh, current discovery is required to review proposals."} Previous selections remain visible; retained evidence cannot authorize a proposal.
              </p>
              <div :if={@changed} class="discovery-actions">
                <button
                  id="discovery-reload"
                  type="button"
                  class="pf-v6-c-button pf-m-secondary"
                  phx-click="reload"
                  disabled={!@current}
                >Reload latest discovery and clear selections</button>
              </div>
              <p
                :if={(@frozen["discovery"]["omitted"] || 0) > 0}
                id="discovery-omitted"
                class="discovery-intro"
              >
                {@frozen["discovery"]["omitted"]} additional resources were omitted by the source. This review covers only the listed candidates.
              </p>
            </PreviewDetail.card>
            <section
              class="preview-list discovery-selection"
              aria-labelledby="discovery-selection-heading"
            >
              <header class="preview-heading">
                <h2 id="discovery-selection-heading" class="pf-v6-c-title pf-m-xl">
                  Discovered resources
                </h2><span class="pf-v6-c-badge pf-m-read">{Enum.count(@draft, fn {_, entry} ->
                  entry["selected"]
                end)} selected</span>
              </header>
              <div class="discovery-filter-toolbar">
                <PreviewFilters.filter_picker
                  picker={@filter_picker}
                  chips={@filter_chips}
                  fields={@filter_fields}
                  search={@filters["search"]}
                  remove={
                    fn field ->
                      list_path(assigns, @filters |> Map.delete(field) |> Map.delete("page"))
                    end
                  }
                  clear_search={
                    list_path(assigns, @filters |> Map.delete("search") |> Map.delete("page"))
                  }
                  form_label="Filter discovered resources"
                  label="Search discovered resources"
                  placeholder="Search or filter resources"
                />
              </div>
              <p
                :if={@error}
                id="discovery-error"
                class="discovery-notice discovery-error"
                role="alert"
              >
                {@error}
              </p>
              <form
                id="discovery-review-form"
                phx-hook="SelectableRows"
                phx-change="edit"
                phx-auto-recover="recover"
                phx-submit="review"
              >
                <input type="hidden" name="snapshot" value={@snapshot_token} />
                <section class="preview-table-group" aria-labelledby="discovery-matches-heading">
                  <h3 id="discovery-matches-heading" class="preview-section-heading">
                    Matching resources
                    <span class="pf-v6-c-badge pf-m-read">{@candidate_page.total}</span>
                  </h3>
                  <p :if={@candidate_page.items == []} class="preview-empty">
                    No resources match these filters.
                  </p>
                  <.candidates
                    :if={@candidate_page.items != []}
                    items={@candidate_page.items}
                    choices={@frozen["discovery"]["choices"]}
                    draft={@draft}
                    ready={@ready}
                    retained={false}
                  />
                  <MondekWeb.PreviewPagination.pagination
                    page={@candidate_page.page}
                    size={@candidate_page.size}
                    total={@candidate_page.total}
                    label="Discovered resource pages"
                    url={
                      fn page -> list_path(assigns, Map.put(@filters, "page", to_string(page))) end
                    }
                  />
                </section>
                <section
                  :if={@candidate_page.retained != []}
                  id="discovery-retained-selection"
                  class="preview-table-group"
                  aria-labelledby="discovery-retained-heading"
                >
                  <h3 id="discovery-retained-heading" class="preview-section-heading">
                    Selected outside this view
                    <span class="pf-v6-c-badge pf-m-read">{length(@candidate_page.retained)}</span>
                  </h3>
                  <p class="discovery-intro">
                    These selections are on another page or do not match the current filters. They remain part of your proposal.
                  </p>
                  <.candidates
                    items={@candidate_page.retained}
                    choices={@frozen["discovery"]["choices"]}
                    draft={@draft}
                    ready={@ready}
                    retained={true}
                  />
                </section>
                <div class="discovery-actions">
                  <span class="preview-caption">Selected resources need an explicit proposal. Unselected resources stay unchanged.</span><button
                    id="discovery-review"
                    type="submit"
                    class="pf-v6-c-button pf-m-primary"
                    disabled={!@ready || @selected_count == 0}
                  >Review proposed changes</button>
                </div>
              </form>
            </section>
            <PreviewDetail.card
              :if={@reviewed}
              id="discovery-proposal-review"
              title="Proposed source changes"
              level={2}
            >
              <p class="discovery-intro">
                Review the complete proposals. Generating a prompt prepares instructions for a coding agent; nothing is saved to your project or controller.
              </p>
              <PreviewDetail.facts label="Reviewed proposals">
                <.reviewed_choice
                  :for={selection <- @reviewed["selections"]}
                  selection={selection}
                  discovery={@frozen["discovery"]}
                />
              </PreviewDetail.facts>
              <div class="discovery-actions">
                <button
                  id="discovery-generate"
                  type="button"
                  phx-click="generate"
                  class="pf-v6-c-button pf-m-primary"
                  disabled={!@ready}
                >Generate agent prompt</button>
              </div>
              <AgentPrompts.supplied_prompt
                :if={@prompt}
                id="discovery-prompt"
                title="Implement reviewed monitoring proposals"
                text={@prompt}
                notice="Review before sharing. This prompt includes selected resource identities, source-owned descriptions and your proposed values. Check it for sensitive information before copying. Mondek does not send it."
              />
            </PreviewDetail.card>
          <% end %>
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@investigation_host}
          params={@investigation_params}
          now={@now}
          root={nil}
          initial={[]}
          context={"discovery:" <> @stream_id}
          back={
            InvestigationTrail.path(@investigation_host, [], %{"surface" => nil, "page_entity" => nil})
          }
        />
      </PreviewLayouts.app>
    </div>
    """
  end

  defp candidate_page(assigns) do
    all = Enum.with_index(get_in(assigns.frozen || %{}, ["discovery", "candidates"]) || [])
    query = String.downcase(assigns.filters["search"] || "")

    matched =
      Enum.filter(all, fn {candidate, index} ->
        entry = assigns.draft[to_string(index)]
        selected = entry["selected"]
        selection = assigns.filters["selection"]
        proposal = assigns.filters["proposal"]

        String.contains?(
          String.downcase(
            Enum.join([candidate["label"], candidate["key"], candidate["details"]], " ")
          ),
          query
        ) &&
          (selection in [nil, ""] || (selection == "selected" && selected) ||
             (selection == "unselected" && !selected)) &&
          (proposal in [nil, ""] || (proposal == @unchosen_proposal && entry["choice_key"] == "") ||
             proposal == entry["choice_key"])
      end)

    requested =
      case Integer.parse(assigns.filters["page"] || "1") do
        {number, ""} when number > 0 -> number
        _ -> 1
      end

    page = min(requested, max(1, ceil(length(matched) / @page_size)))
    items = Enum.slice(matched, (page - 1) * @page_size, @page_size)
    visible = MapSet.new(items, &elem(&1, 1))

    retained =
      Enum.filter(all, fn {_, index} ->
        assigns.draft[to_string(index)]["selected"] && !MapSet.member?(visible, index)
      end)

    %{items: items, retained: retained, page: page, size: @page_size, total: length(matched)}
  end

  defp candidates(assigns) do
    ~H"""
    <table
      class="pf-v6-c-table pf-m-compact preview-table discovery-candidate-table"
      aria-label={
        if @retained, do: "Selected resources outside this view", else: "Discovered resources"
      }
    >
      <thead class="pf-v6-c-table__thead">
        <tr>
          <th scope="col" class="pf-v6-c-table__th">
            <span class="pf-v6-screen-reader">Select</span>
          </th><th scope="col" class="pf-v6-c-table__th">Resource</th><th
            scope="col"
            class="pf-v6-c-table__th"
          >
            Proposed configuration
          </th>
        </tr>
      </thead>
      <tbody>
        <.candidate
          :for={{candidate, index} <- @items}
          candidate={candidate}
          index={index}
          choices={@choices}
          draft={@draft[to_string(index)]}
          ready={@ready}
          retained={@retained}
        />
      </tbody>
    </table>
    """
  end

  defp candidate(assigns) do
    assigns =
      assign(assigns,
        choice: Enum.find(assigns.choices, &(&1["key"] == assigns.draft["choice_key"])),
        prefix: "selections[#{assigns.index}]"
      )

    ~H"""
    <tr
      id={"discovery-candidate-#{@index}"}
      class={[@draft["selected"] && "preview-selected", @retained && "discovery-retained-row"]}
      data-select-row
    >
      <td class="pf-v6-c-table__td" data-label="Selection">
        <input
          type="hidden"
          name={@prefix <> "[selected]"}
          value={if !@ready && @draft["selected"], do: "true", else: "false"}
        />
        <input
          id={"discovery-select-#{@index}"}
          type="checkbox"
          data-row-checkbox
          name={@prefix <> "[selected]"}
          value="true"
          checked={@draft["selected"]}
          disabled={!@ready}
          aria-label={"Select " <> @candidate["label"]}
        />
      </td>
      <td class="pf-v6-c-table__td" data-label="Resource">
        <label for={"discovery-select-#{@index}"} class="discovery-candidate-title">{@candidate[
          "label"
        ]}</label><p :if={@candidate["details"]} class="preview-caption discovery-candidate-details">
          {@candidate["details"]}
        </p><span class="preview-caption">{@candidate["key"]}</span>
      </td>
      <td class="pf-v6-c-table__td" data-label="Proposal">
        <span :if={!@draft["selected"]} class="preview-caption">Not selected</span>
        <fieldset :if={@draft["selected"]} disabled={!@ready} class="discovery-proposal-fields">
          <legend class="pf-v6-screen-reader">Proposal for {@candidate["label"]}</legend>
          <div class="field">
            <label for={"discovery-choice-#{@index}"}>Proposed configuration</label><select
              id={"discovery-choice-#{@index}"}
              name={@prefix <> "[choice_key]"}
            ><option value="" selected={@draft["choice_key"] == ""}>Choose a proposal</option><option
              :for={choice <- @choices}
              value={choice["key"]}
              selected={@draft["choice_key"] == choice["key"]}
            >
              {choice["label"]}
            </option></select>
          </div>
          <p :if={@choice} class="preview-caption">{@choice["description"]}</p>
          <ParameterForm.fields
            :if={@choice}
            id_prefix={"discovery-params-#{@index}"}
            name_prefix={@prefix <> "[params]"}
            schema={@choice["parameter_schema"]}
            values={@draft["params"]}
            fixed_hint="Fixed by the source-declared proposal."
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
      </td>
    </tr>
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
    <tr>
      <th scope="row">
        {@candidate["label"]}<span class="preview-caption discovery-secondary">{@candidate["key"]}</span>
      </th><td>
        <table class="discovery-reviewed-facts" aria-label={"Proposal for " <> @candidate["label"]}>
          <tbody>
            <tr>
              <th scope="row">Proposal</th><td>{@choice["label"]}</td>
            </tr><tr :for={{key, value} <- Enum.sort(@selection["params"])}>
              <th scope="row">
                {ParameterForm.field_label(@choice["parameter_schema"], key)}<span :if={
                  get_in(@choice, ["parameter_schema", "fields", key, "unit"])
                }> ({get_in(@choice, ["parameter_schema", "fields", key, "unit"])})</span>
              </th><td>{ParameterForm.input_value(value)}</td>
            </tr>
          </tbody>
        </table>
      </td>
    </tr>
    """
  end
end

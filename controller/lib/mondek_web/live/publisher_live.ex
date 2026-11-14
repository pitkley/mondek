# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PublisherLive do
  use MondekWeb, :live_view

  alias Mondek.PublisherLifecycle
  alias Phoenix.LiveView.JS

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    PreviewDetail,
    PreviewFilters,
    PreviewLayouts,
    PreviewPagination
  }

  @proposal_fields ~w(publisher_id action reason successor_id)

  @impl true
  def mount(_params, _session, socket) do
    now = Mondek.Monitoring.now()
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       navigation_counts: Mondek.Inspection.navigation_counts(now),
       now: now,
       page_title: "Publishing runner",
       publication_id: nil,
       detail: nil,
       proposal: nil,
       preview: nil,
       review_token: nil,
       review_stale: false,
       successors: %{},
       successor_search: "",
       successor_page: 1,
       selected_successor: nil,
       history_page: 1,
       event_id: nil,
       event_page: 1,
       event: nil,
       evidence_id: nil,
       evidence: nil,
       evidence_missing: false,
       error: nil,
       notice: nil
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    local = URI.parse(uri)
    same? = socket.assigns.publication_id == params["id"]

    socket =
      assign(socket,
        publication_id: params["id"],
        raw_params: params,
        current: local.path <> if(local.query, do: "?" <> local.query, else: ""),
        return_to: BrowserNavigation.return_path(params["return_to"]),
        investigation_selection: InvestigationTrail.selection(params),
        investigation_open: InvestigationTrail.resolve(params) != [],
        promoted: !is_nil(InvestigationTrail.promoted(params)),
        history_page: positive(params["history_page"]),
        event_id: params["event_id"],
        event_page: positive(params["event_page"]),
        evidence_id: params["evidence_id"]
      )

    socket =
      if same?,
        do: socket,
        else:
          assign(socket,
            proposal: nil,
            preview: nil,
            review_token: nil,
            review_stale: false,
            successor_search: "",
            successor_page: 1,
            selected_successor: nil,
            error: nil,
            notice: nil
          )

    {:noreply, socket |> refresh() |> load_event() |> load_evidence()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, socket |> refresh() |> check_review()}
  end

  @impl true
  def handle_event(event, _params, %{assigns: %{investigation_open: true}} = socket)
      when event in ~w(edit choose_successor clear_successor successor_page preview apply preview_page back search filter_remove),
      do: {:noreply, socket}

  def handle_event(
        "search",
        %{"search" => query},
        %{assigns: %{investigation_open: false}} = socket
      ),
      do:
        {:noreply,
         socket
         |> assign(successor_search: bounded_search(query), successor_page: 1)
         |> load_successors()}

  def handle_event("filter_remove", %{"field" => "search"}, socket),
    do: handle_event("search", %{"search" => ""}, socket)

  def handle_event("filter_close", _, socket), do: {:noreply, socket}
  def handle_event("filter_open", _, socket), do: {:noreply, socket}

  def handle_event("edit", form, socket) do
    proposal = draft(form, socket.assigns.proposal)
    changed? = proposal != socket.assigns.proposal
    selection_changed? = proposal["successor_id"] != socket.assigns.proposal["successor_id"]
    socket = assign(socket, proposal: proposal)
    socket = if changed?, do: clear_review(socket), else: socket
    socket = if selection_changed?, do: load_selected(socket), else: socket

    socket =
      if form["_target"] == ["successor_search"] do
        socket
        |> assign(successor_search: bounded_search(form["successor_search"]), successor_page: 1)
        |> load_successors()
      else
        if proposal["action"] == "replace", do: load_successors(socket), else: socket
      end

    {:noreply, socket}
  end

  def handle_event("choose_successor", %{"id" => id}, socket) do
    selected = Enum.find(socket.assigns.successors["items"] || [], &(to_string(&1["id"]) == id))

    if selected do
      {:noreply,
       socket
       |> clear_review()
       |> assign(
         proposal: Map.put(socket.assigns.proposal, "successor_id", selected["id"]),
         selected_successor: selected
       )}
    else
      {:noreply,
       assign(socket,
         error: "This replacement is no longer in the displayed choices. Search again."
       )}
    end
  end

  def handle_event(
        "clear_successor",
        _,
        %{assigns: %{proposal: %{"action" => "replace"}}} = socket
      ) do
    {:noreply,
     socket
     |> clear_review()
     |> assign(
       proposal: Map.delete(socket.assigns.proposal, "successor_id"),
       selected_successor: nil
     )}
  end

  def handle_event("clear_successor", _, socket), do: {:noreply, socket}

  def handle_event("successor_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(successor_page: positive(page)) |> load_successors()}
  end

  def handle_event("preview", form, socket) do
    socket = assign(socket, proposal: draft(form, socket.assigns.proposal))

    case PublisherLifecycle.preview(socket.assigns.proposal) do
      {:ok, preview} ->
        {:noreply,
         assign(socket,
           proposal: preview["proposal"],
           preview: preview,
           review_token: preview["review_token"],
           review_stale: false,
           error: nil,
           notice: nil
         )}

      {:error, reason} ->
        {:noreply, socket |> clear_review() |> assign(error: error_message(reason))}
    end
  end

  def handle_event("apply", form, socket) do
    proposal = draft(form, socket.assigns.proposal)

    with token when is_binary(token) <- socket.assigns.review_token,
         true <- not socket.assigns.review_stale,
         true <- token == form["_review_token"] and proposal == socket.assigns.proposal,
         {:ok, receipt} <- PublisherLifecycle.apply(token, proposal) do
      socket =
        socket
        |> clear_review()
        |> assign(
          proposal: nil,
          selected_successor: nil
        )
        |> refresh()

      receipt = Map.put(receipt, "publisher", get_in(socket.assigns.detail || %{}, ["publisher"]))
      {:noreply, assign(socket, notice: receipt_notice(receipt, proposal["action"]))}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: error_message(reason), review_stale: true)}

      _ ->
        {:noreply,
         assign(socket,
           error: "Preview this exact decision before applying it.",
           review_stale: true
         )}
    end
  end

  def handle_event("preview_page", %{"page" => page}, socket) do
    {:noreply, review_page(socket, positive(page))}
  end

  def handle_event("back", _, socket), do: {:noreply, clear_review(socket)}

  def handle_event("recover", form, socket) do
    with encoded when is_binary(encoded) and byte_size(encoded) <= 16_384 <- form["_proposal"],
         {:ok, captured} when is_map(captured) <- Jason.decode(encoded),
         true <- valid_draft?(captured),
         true <- same_id?(captured["publisher_id"], socket.assigns.publication_id) do
      captured = Map.take(captured, @proposal_fields)
      proposal = draft(form, captured)
      token = form["_review_token"]

      socket =
        socket
        |> clear_review()
        |> assign(
          proposal: proposal,
          successor_search: bounded_search(form["successor_search"]),
          successor_page: positive(form["_successor_page"]),
          notice: "Draft restored. Review any unsaved changes before applying them."
        )
        |> load_successors()
        |> load_selected()

      socket =
        if is_binary(token) and byte_size(token) <= 32_768 and proposal == captured do
          socket |> assign(review_token: token) |> review_page(positive(form["_preview_page"]))
        else
          socket
        end

      {:noreply, socket}
    else
      _ ->
        {:noreply,
         assign(socket,
           error:
             "This draft could not be restored for this publication. Reopen its lifecycle page."
         )}
    end
  end

  defp refresh(socket) do
    refreshed_at = Mondek.Monitoring.now()

    socket =
      assign(socket,
        now: refreshed_at,
        navigation_counts: Mondek.Inspection.navigation_counts(refreshed_at)
      )

    case PublisherLifecycle.get(socket.assigns.publication_id, socket.assigns.history_page) do
      {:ok, detail} ->
        proposal =
          socket.assigns.proposal ||
            %{
              "publisher_id" => detail["publisher"]["id"],
              "action" =>
                if(detail["publisher"]["lifecycle_status"] == "retired",
                  do: "restore",
                  else: "retire"
                ),
              "reason" => ""
            }

        notice = socket.assigns.notice
        previous = get_in(socket.assigns.detail || %{}, ["publisher", "lifecycle_status"])
        changed? = previous && previous != detail["publisher"]["lifecycle_status"]

        notice =
          if changed? && is_binary(notice) &&
               Enum.any?(
                 ["Restoration recorded.", "Replacement recorded.", "Publication retired"],
                 &String.starts_with?(notice, &1)
               ), do: nil, else: notice

        assign(socket, detail: detail, proposal: proposal, notice: notice)

      {:error, reason} ->
        assign(socket, detail: nil, error: error_message(reason))
    end
  end

  defp load_successors(%{assigns: %{proposal: %{"action" => "replace"}}} = socket) do
    case PublisherLifecycle.successors(socket.assigns.publication_id, %{
           "search" => socket.assigns.successor_search,
           "page" => socket.assigns.successor_page
         }) do
      {:ok, listing} -> assign(socket, successors: listing, successor_page: listing["page"])
      {:error, reason} -> assign(socket, successors: %{}, error: error_message(reason))
    end
  end

  defp load_successors(socket), do: socket

  defp load_selected(socket) do
    case socket.assigns.proposal["successor_id"] do
      nil ->
        assign(socket, selected_successor: nil)

      id ->
        case PublisherLifecycle.get(id) do
          {:ok, detail} -> assign(socket, selected_successor: detail["publisher"])
          _ -> assign(socket, selected_successor: nil)
        end
    end
  end

  defp check_review(%{assigns: %{preview: nil}} = socket), do: socket
  defp check_review(%{assigns: %{review_stale: true}} = socket), do: socket
  defp check_review(socket), do: review_page(socket, socket.assigns.preview["page"] || 1)

  defp review_page(socket, page) do
    if is_binary(socket.assigns.review_token) do
      case PublisherLifecycle.preview(
             socket.assigns.proposal,
             page,
             nil,
             socket.assigns.review_token
           ) do
        {:ok, preview} -> assign(socket, preview: preview, review_stale: false, error: nil)
        {:error, reason} -> assign(socket, review_stale: true, error: error_message(reason))
      end
    else
      assign(socket, error: "Preview this decision before inspecting its impact.")
    end
  end

  defp clear_review(socket),
    do:
      assign(socket,
        preview: nil,
        review_token: nil,
        review_stale: false,
        error: nil,
        notice: nil
      )

  defp load_event(%{assigns: %{event_id: nil}} = socket), do: assign(socket, event: nil)

  defp load_event(socket) do
    case PublisherLifecycle.event(
           socket.assigns.publication_id,
           socket.assigns.event_id,
           socket.assigns.event_page
         ) do
      {:ok, event} ->
        assign(socket, event: event)

      {:error, _} ->
        assign(socket,
          event: nil,
          error: "This saved lifecycle decision could not be found for this publication."
        )
    end
  end

  defp load_evidence(%{assigns: %{event: nil}} = socket),
    do: assign(socket, evidence: nil, evidence_missing: false)

  defp load_evidence(%{assigns: %{evidence_id: nil}} = socket),
    do: assign(socket, evidence: nil, evidence_missing: false)

  defp load_evidence(socket) do
    case PublisherLifecycle.evidence(
           socket.assigns.publication_id,
           socket.assigns.event_id,
           socket.assigns.evidence_id
         ) do
      {:ok, evidence} -> assign(socket, evidence: evidence, evidence_missing: false)
      {:error, _} -> assign(socket, evidence: nil, evidence_missing: true)
    end
  end

  defp draft(form, original) do
    values = if is_map(form["lifecycle"]), do: form["lifecycle"], else: %{}

    values =
      Map.filter(values, fn {key, value} ->
        key in ~w(action reason successor_id) and is_binary(value) and byte_size(value) <= 2048 and
          String.valid?(value) and not String.contains?(value, <<0>>)
      end)

    proposal = Map.merge(original || %{}, Map.take(values, ~w(action reason successor_id)))

    proposal =
      if proposal["successor_id"] == "", do: Map.delete(proposal, "successor_id"), else: proposal

    if proposal["action"] == "replace" do
      if proposal["successor_id"],
        do: Map.update!(proposal, "successor_id", &normalize_id/1),
        else: Map.delete(proposal, "successor_id")
    else
      Map.delete(proposal, "successor_id")
    end
  end

  defp valid_draft?(draft) do
    Enum.all?(draft, fn {key, value} ->
      key in @proposal_fields and
        ((is_binary(value) and byte_size(value) <= 2048) or is_integer(value))
    end) and draft["action"] in ~w(retire replace restore) and is_binary(draft["reason"])
  end

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> value
    end
  end

  defp normalize_id(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="publication-shell"
      phx-hook="OverviewPanel"
      data-selection={@investigation_selection}
      data-panel-heading={InvestigationTrail.heading(@raw_params, "publisher-heading")}
    >
      <PreviewLayouts.navigation active={:coverage} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <div
          id="publication-workflow"
          class="publication-workflow"
          hidden={@promoted}
          inert={@investigation_open || @promoted}
        >
          <section class="preview-list publication-intro">
            <header class="preview-heading">
              <PreviewDetail.heading level={1} id="publisher-heading">
                {if @detail, do: publisher_name(@detail["publisher"]), else: "Publication not found"}
              </PreviewDetail.heading><.link
                navigate={@return_to || "/coverage/publishers"}
                class="pf-v6-c-button pf-m-link"
              >{publication_back_label(@return_to)}</.link>
            </header>
            <p
              :if={@error}
              id="publisher-error"
              class="publication-message publication-error"
              role="alert"
            >
              {@error}
            </p>
            <p :if={@notice} id="publisher-notice" class="publication-message" role="status">
              {@notice}
            </p>
            <p :if={!@detail} id="publisher-missing" class="preview-empty">
              Publication not found. Choose a source publication from Publishing runners.
            </p>
            <.publication :if={@detail} {assigns} />
          </section>
          <.lifecycle_form :if={@detail && @proposal} {assigns} />
          <.history :if={@detail} {assigns} />
          <.saved_event :if={@detail && @event} {assigns} />
          <.saved_measurement :if={@detail && @event && @evidence_id} {assigns} />
        </div>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@current}
          params={@raw_params}
          now={@now}
          root={nil}
          initial={[]}
          context={"publication:" <> to_string(@publication_id)}
          back={owner_url(@current, %{})}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp publication(assigns) do
    assigns =
      assign(assigns, publisher: assigns.detail["publisher"], summary: assigns.detail["summary"])

    ~H"""
    <PreviewDetail.card id="publisher-summary" title="Source publication" level={2}>
      <PreviewDetail.facts label="Publication and monitoring scope">
        <tr>
          <th scope="row">State</th><td>
            <span
              id="publisher-status"
              class={["pf-v6-c-label", status_tone(@publisher["lifecycle_status"])]}
            ><span class="pf-v6-c-label__content">{status(@publisher["lifecycle_status"])}</span></span>
          </td>
        </tr>
        <tr>
          <th scope="row">Source</th><td>{@publisher["source_id"]}</td>
        </tr>
        <tr>
          <th scope="row">Monitoring</th><td>
            {count(@summary, "assignments")} active checks · {count(@summary, "results")} active results · {count(
              @summary,
              "declared_scopes"
            )} {if @publisher["lifecycle_status"] == "active",
              do: "declared scopes",
              else: "retained declared scopes"}
          </td>
        </tr>
        <tr>
          <th scope="row">Open result incidents</th><td>{count(@summary, "open_incidents")}</td>
        </tr>
        <tr>
          <th scope="row">Meaning</th><td>{publication_meaning(@publisher["lifecycle_status"])}</td>
        </tr>
        <tr>
          <th scope="row">Related evidence</th><td class="publication-links">
            <.link
              patch={entity_path(@current, {"runner", @publisher["runner_id"]})}
              id="publication-runner"
              data-overview-open
            >Inspect runner</.link><.link navigate={coverage_path(@publisher)}>{if @publisher[
                                                                                     "lifecycle_status"
                                                                                   ] == "active",
                                                                                   do:
                                                                                     "Inspect declared scopes",
                                                                                   else:
                                                                                     "Current scopes from remaining publishers"}</.link><.link navigate={
              checks_path(@publisher)
            }>All checks and history from this runner</.link><.link
              :if={@publisher["replacement_id"]}
              navigate={publication_path(@publisher["replacement_id"])}
            >Inspect recorded replacement</.link>
          </td>
        </tr>
      </PreviewDetail.facts>
      <details
        id="publisher-provenance"
        phx-mounted={JS.ignore_attributes("open")}
        class="publication-disclosure"
      >
        <summary>Publication and restoration details</summary>
        <PreviewDetail.facts label="Publication identity">
          <tr>
            <th scope="row">Last controller contact</th><td>{utc(@publisher["last_seen_at"])}</td>
          </tr>
          <tr>
            <th scope="row">Accepted inventory</th><td>Version {@publisher["inventory_revision"]}</td>
          </tr>
          <tr>
            <th scope="row">Lifecycle revision</th><td>{@publisher["lifecycle_revision"]}</td>
          </tr>
          <tr :if={@publisher["retired_at"]}>
            <th scope="row">Retired</th><td>{utc(@publisher["retired_at"])}</td>
          </tr>
          <tr :if={@publisher["retirement_reason"]}>
            <th scope="row">Retirement reason</th><td>{@publisher["retirement_reason"]}</td>
          </tr>
          <tr :if={@publisher["runner_context"] not in [nil, %{}]}>
            <th scope="row">Execution context</th><td>
              {get_in(@publisher, ["runner_context", "label"])} · {get_in(@publisher, [
                "runner_context",
                "id"
              ])}
            </td>
          </tr>
          <tr :if={get_in(@publisher, ["runner_context", "local_environment"])}>
            <th scope="row">Execution environment</th><td>
              {get_in(@publisher, ["runner_context", "local_environment"])}
            </td>
          </tr>
          <tr>
            <th scope="row">Package code</th><td>{@publisher["code_revision"] || "Not reported"}</td>
          </tr>
          <tr>
            <th scope="row">Runtime</th><td>{@publisher["runtime_revision"] || "Not reported"}</td>
          </tr>
          <tr>
            <th scope="row">Source revision</th><td>
              {@publisher["source_revision"] || "Not reported"}
            </td>
          </tr>
          <tr>
            <th scope="row">Declaration catalogue</th><td>
              {cond do
                @publisher["coverage_revision"] == nil -> "Not reported"
                @publisher["coverage_confirmed"] -> "Confirmed by current inventory"
                true -> "Previous declarations are not confirmed by current inventory"
              end}
            </td>
          </tr>
          <tr>
            <th scope="row">Runner identity</th><td>{@publisher["runner_id"]}</td>
          </tr>
        </PreviewDetail.facts>
        <p :if={@publisher["lifecycle_status"] == "awaiting_inventory"} class="publication-message">
          The SDK must rediscover installed source and publish a newer inventory for this restoration request. Failed discovery leaves it waiting; cached inventory and buffered reports cannot establish restored coverage.
        </p>
      </details>
    </PreviewDetail.card>
    """
  end

  defp lifecycle_form(assigns) do
    assigns = assign(assigns, publisher: assigns.detail["publisher"])

    ~H"""
    <PreviewDetail.card id="publisher-lifecycle" title="Manage this publication" level={2}>
      <form
        id="publisher-lifecycle-form"
        phx-change="edit"
        phx-submit={if @preview && !@review_stale, do: "apply", else: "preview"}
        phx-auto-recover="recover"
      >
        <input type="hidden" name="_proposal" value={Jason.encode!(@proposal)} />
        <input :if={@review_token} type="hidden" name="_review_token" value={@review_token} />
        <input type="hidden" name="_preview_page" value={(@preview || %{})["page"] || 1} />
        <input type="hidden" name="_successor_page" value={@successor_page} />
        <input type="hidden" name="successor_search" value={@successor_search} />
        <input type="hidden" name="lifecycle[successor_id]" value={@proposal["successor_id"] || ""} />
        <div class="publication-editor-fields">
          <div class="publication-field">
            <label for="publisher-action">Decision</label><select
              id="publisher-action"
              name="lifecycle[action]"
            ><option value="retire" selected={@proposal["action"] == "retire"}>
              Retire this publication
            </option><option value="replace" selected={@proposal["action"] == "replace"}>
              Retire with a recorded replacement
            </option><option value="restore" selected={@proposal["action"] == "restore"}>
              Restore this publication
            </option></select><p class="preview-caption">{action_help(@proposal["action"])}</p>
          </div>
          <div class="publication-field">
            <label for="publisher-reason">Reason</label><textarea
              id="publisher-reason"
              name="lifecycle[reason]"
              rows="2"
              maxlength="500"
              required
              aria-describedby="publisher-reason-help"
            >{@proposal["reason"]}</textarea><p id="publisher-reason-help" class="preview-caption">
              Retained with this decision. No action transfers measurements or individual acknowledgements.
            </p>
          </div>
        </div>
      </form>
      <section
        :if={@proposal["action"] == "replace"}
        class="publication-replacement"
        aria-labelledby="publisher-replacement-heading"
      >
        <h3 id="publisher-replacement-heading" class="preview-section-heading">
          Replacement observer
        </h3>
        <div
          id="publisher-selected-successor"
          class="publication-message publication-selected-successor"
        >
          <span>{if @selected_successor,
            do: "Selected: " <> publisher_name(@selected_successor),
            else: "No replacement selected."}</span>
          <button
            :if={@selected_successor}
            id="publisher-clear-successor"
            type="button"
            class="pf-v6-c-button pf-m-link"
            phx-click="clear_successor"
          >Remove selection</button>
        </div>
        <details
          id="publisher-successor-choices"
          open={is_nil(@preview)}
          class="publication-disclosure"
        >
          <summary>Choose or change replacement observer</summary>
          <div class="publication-filter-toolbar">
            <PreviewFilters.filter_picker
              id="publisher-successor-filter"
              picker={assigns[:successor_filter_picker]}
              chips={[]}
              fields={[]}
              search={@successor_search}
              form_label="Search replacement observers"
              label="Search replacement observers"
              placeholder="Search replacement observers"
            />
          </div>
          <div id="publisher-successors">
            <p :if={@successors["items"] in [nil, []]} class="publication-message">
              No active publications match. Deploy this source on another runner, or retire without a replacement.
            </p>
            <table
              :if={@successors["items"] not in [nil, []]}
              class="pf-v6-c-table pf-m-compact preview-table publication-successor-table"
              aria-label="Replacement observers"
            >
              <thead class="pf-v6-c-table__thead">
                <tr>
                  <th scope="col" class="pf-v6-c-table__th">Observer</th><th
                    scope="col"
                    class="pf-v6-c-table__th"
                  >
                    Last contact
                  </th><th scope="col" class="pf-v6-c-table__th">Selection</th>
                </tr>
              </thead><tbody>
                <tr :for={candidate <- @successors["items"]} data-successor-id={candidate["id"]}>
                  <td class="pf-v6-c-table__td" data-label="Observer">
                    {publisher_name(candidate)}<span class="preview-caption publication-secondary">{String.slice(
                      candidate["runner_id"],
                      0,
                      8
                    )} · {@publisher[
                      "source_id"
                    ]}</span>
                  </td><td class="pf-v6-c-table__td" data-label="Last contact">
                    {utc(candidate["last_seen_at"])}
                  </td><td class="pf-v6-c-table__td" data-label="Selection">
                    <button
                      type="button"
                      class="pf-v6-c-button pf-m-secondary"
                      phx-click="choose_successor"
                      phx-value-id={candidate["id"]}
                      disabled={same_id?(candidate["id"], @proposal["successor_id"])}
                      aria-label={"Choose observer " <> publisher_name(candidate)}
                    >{if same_id?(candidate["id"], @proposal["successor_id"]),
                      do: "Selected",
                      else: "Choose observer"}</button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <.event_pager
            listing={@successors}
            event="successor_page"
            id="publisher-successor-pages"
            label="Replacement observer pages"
          />
        </details>
      </section>
      <div :if={is_nil(@preview) || @review_stale} class="publication-actions">
        <button
          id="publisher-preview-button"
          form="publisher-lifecycle-form"
          type="submit"
          class="pf-v6-c-button pf-m-primary"
        >{if @review_stale,
          do: "Preview again",
          else: "Preview impact"}</button>
      </div>
      <.preview :if={@preview} {assigns} />
    </PreviewDetail.card>
    """
  end

  defp preview(assigns) do
    assigns = assign(assigns, summary: assigns.preview["summary"])

    ~H"""
    <section
      id="publisher-preview"
      class="publication-review"
      aria-labelledby="publisher-preview-heading"
    >
      <h3 id="publisher-preview-heading" class="preview-section-heading">
        Review {action_name(@proposal["action"])}
      </h3>
      <PreviewDetail.facts label="Reviewed publication decision" class="publication-review-facts">
        <tr>
          <th scope="row">Reason</th><td>{@proposal["reason"]}</td>
        </tr>
        <tr :if={@preview["successor"]}>
          <th scope="row">Recorded replacement</th><td>{publisher_name(@preview["successor"])}</td>
        </tr>
        <tr>
          <th scope="row">Checks affected</th><td>{count(@summary, "assignments")}</td>
        </tr>
        <tr>
          <th scope="row">Results affected</th><td>{count(@summary, "results")}</td>
        </tr>
        <tr>
          <th scope="row">Open result incidents</th><td>{count(@summary, "open_incidents")}</td>
        </tr>
        <tr>
          <th scope="row">Shared incidents involved</th><td>{count(@summary, "shared_incidents")}</td>
        </tr>
        <tr :if={@proposal["action"] != "restore"}>
          <th scope="row">Scopes losing their last publisher</th><td>
            {count(@summary, "scopes_losing_last_publisher")}
          </td>
        </tr>
        <tr :if={@proposal["action"] != "restore"}>
          <th scope="row">Scopes losing their last selected observer</th><td>
            {count(@summary, "scopes_losing_last_selected")}
          </td>
        </tr>
        <tr :if={@proposal["action"] == "replace"}>
          <th scope="row">Replacement results ready</th><td>{count(@summary, "matched_results")}</td>
        </tr>
        <tr :if={@proposal["action"] == "replace"}>
          <th scope="row">Replacement gaps</th><td>{count(@summary, "replacement_gaps")}</td>
        </tr>
        <tr>
          <th scope="row">Effect</th><td>{preview_effect(@proposal["action"])}</td>
        </tr>
        <tr>
          <th scope="row">Configuration and controls</th><td>
            {if @proposal["action"] == "replace",
              do:
                "The replacement keeps its own effective settings. Individual check exceptions and acknowledgements are not transferred from this publication.",
              else:
                "Restored checks use defaults from code and matching configuration rules. Individual check exceptions and acknowledgements remain with retired instances."}
          </td>
        </tr>
      </PreviewDetail.facts>
      <p :if={@review_stale} class="publication-message publication-error">
        This review is no longer current. Your draft is retained; preview again before applying it.
      </p>
      <div
        :if={@preview["blockers"] != []}
        id="publisher-preview-blockers"
        class="publication-message publication-error"
      >
        <strong>This decision cannot be applied yet.</strong><ul>
          <li :for={blocker <- @preview["blockers"] || []}>{blocker}</li>
        </ul>
      </div>
      <p :if={version_difference?(@preview)} class="publication-message">
        The publications report different package or runtime versions. No shared latest release is inferred; inspect their declared contracts and reviewed impact.
      </p>
      <div class="publication-actions">
        <button
          id="publisher-apply"
          form="publisher-lifecycle-form"
          type="submit"
          class="pf-v6-c-button pf-m-primary"
          disabled={@review_stale || !@preview["can_apply"]}
        >Apply {action_name(@proposal["action"])}</button><button
          type="button"
          class="pf-v6-c-button pf-m-secondary"
          phx-click="back"
        >Discard review</button>
      </div>
      <details
        id="publisher-impact"
        class="publication-disclosure"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Inspect affected scopes ({@preview["total"]})</summary>
        <p :if={@preview["items"] == []} class="publication-message">
          There are no result declarations in this publication.
        </p>
        <.impact_rows items={@preview["items"] || []} current={@current} action={@proposal["action"]} />
        <.event_pager
          listing={@preview}
          event="preview_page"
          id="publisher-impact-pages"
          label="Reviewed impact pages"
          disabled={@review_stale}
        />
      </details>
    </section>
    """
  end

  defp impact_rows(assigns) do
    ~H"""
    <table
      :if={@items != []}
      class="pf-v6-c-table pf-m-compact preview-table publication-impact-table"
      aria-label="Affected result declarations"
    >
      <thead class="pf-v6-c-table__thead">
        <tr>
          <th scope="col" class="pf-v6-c-table__th">Result / target</th><th
            scope="col"
            class="pf-v6-c-table__th"
          >
            Coverage effect
          </th><th scope="col" class="pf-v6-c-table__th">Evidence</th>
        </tr>
      </thead><tbody>
        <tr :for={item <- @items} data-impact-scope={item["scope_id"]} class="publisher-impact-row">
          <td class="pf-v6-c-table__td" data-label="Result / target">
            <strong>{item["check_label"]} · {item["result_label"]}</strong><span class="preview-caption publication-secondary">{get_in(
              item,
              ["target", "label"]
            ) || "Unresolved target"} · {item["environment"] || "Unscoped"}</span>
          </td><td class="pf-v6-c-table__td" data-label="Coverage effect">
            {if item["selected"], do: "Selected by this publication", else: "Declared but excluded"}<span class="preview-caption publication-secondary">Remaining publishers: {item[
              "remaining_publishers"
            ] || 0}; selected observers: {item["remaining_selected"] || 0}.</span><span
              :if={@action == "replace"}
              class="publication-secondary"
            >{replacement_status(item["replacement_status"])}<span :if={item["replacement_reason"]}>: {item[
              "replacement_reason"
            ]}</span></span>
          </td><td class="pf-v6-c-table__td publication-links" data-label="Evidence">
            <.link :if={item["scope_id"]} navigate={"/coverage/" <> item["scope_id"]}>Inspect declared scope</.link><.link
              :if={item["stream_id"]}
              patch={entity_path(@current, {"result", item["stream_id"]})}
            >Inspect current result</.link><.link
              :if={item["successor_stream_id"]}
              patch={entity_path(@current, {"result", item["successor_stream_id"]})}
            >Inspect replacement result</.link>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp history(assigns) do
    assigns = assign(assigns, history: assigns.detail["history"])

    ~H"""
    <PreviewDetail.card id="publisher-history" title="Lifecycle history" level={2}>
      <p :if={@history["items"] in [nil, []]} class="publication-message">
        No lifecycle decisions have been recorded.
      </p>
      <table
        :if={@history["items"] not in [nil, []]}
        class="pf-v6-c-table pf-m-compact preview-table publication-history-table"
        aria-label="Publication lifecycle history"
      >
        <thead class="pf-v6-c-table__thead">
          <tr>
            <th scope="col" class="pf-v6-c-table__th">Decision</th><th
              scope="col"
              class="pf-v6-c-table__th"
            >
              Reason
            </th><th scope="col" class="pf-v6-c-table__th">Recorded</th><th
              scope="col"
              class="pf-v6-c-table__th"
            >
              Evidence
            </th>
          </tr>
        </thead><tbody>
          <tr :for={event <- @history["items"]} class="publisher-history-event">
            <td class="pf-v6-c-table__td" data-label="Decision">
              {history_action(event["action"])}<span class="preview-caption publication-secondary">Lifecycle revision {event[
                "lifecycle_revision"
              ]}</span>
            </td><td class="pf-v6-c-table__td" data-label="Reason">
              {event["reason"]}
              <details
                id={"publisher-event-" <> to_string(event["id"])}
                phx-mounted={JS.ignore_attributes("open")}
              >
                <summary>Reviewed impact</summary><p>
                  {count(event["summary"], "assignments")} checks; {count(event["summary"], "results")} results; {count(
                    event["summary"],
                    "open_incidents"
                  )} open result incidents.
                </p>
              </details>
            </td><td class="pf-v6-c-table__td" data-label="Recorded">
              {utc(event["inserted_at"])}<span class="preview-caption publication-secondary">{event[
                "actor"
              ] || "Local operator"}</span>
            </td><td class="pf-v6-c-table__td publication-links" data-label="Evidence">
              <.link patch={
                owner_url(@current, %{
                  "event_id" => event["id"],
                  "event_page" => 1,
                  "evidence_id" => nil
                })
              }>Inspect saved decision and evidence</.link><.link
                :if={event["successor_id"]}
                navigate={publication_path(event["successor_id"])}
              >Inspect recorded replacement</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <div id="publisher-history-pages">
        <PreviewPagination.pagination
          page={@history["page"]}
          size={@history["page_size"] || 25}
          total={@history["total"]}
          label="Publication history pages"
          url={fn page -> owner_url(@current, %{"history_page" => page}) end}
        />
      </div>
    </PreviewDetail.card>
    """
  end

  defp saved_event(assigns) do
    ~H"""
    <PreviewDetail.card
      id="publisher-saved-decision"
      phx-mounted={JS.focus(to: "#publisher-saved-decision-heading")}
      title={"Saved " <> action_name(@event["action"]) <> " decision"}
      level={2}
    >
      <PreviewDetail.facts label="Saved lifecycle decision">
        <tr>
          <th scope="row">Reason</th><td>{@event["reason"]}</td>
        </tr><tr>
          <th scope="row">Recorded</th><td>{utc(@event["inserted_at"])}</td>
        </tr><tr>
          <th scope="row">Evidence scope</th><td>
            {@event["total"]} affected result declarations. Showing page {@event["page"]} of {pages(
              @event
            )}. These identities and measurements describe the saved decision; current coverage may have changed.
          </td>
        </tr>
      </PreviewDetail.facts>
      <table
        class="pf-v6-c-table pf-m-compact preview-table publication-saved-table"
        aria-label="Saved decision result declarations"
      >
        <thead class="pf-v6-c-table__thead">
          <tr>
            <th scope="col" class="pf-v6-c-table__th">Recorded result / target</th><th
              scope="col"
              class="pf-v6-c-table__th"
            >
              Saved evidence
            </th><th scope="col" class="pf-v6-c-table__th">Current evidence</th>
          </tr>
        </thead><tbody>
          <tr :for={item <- @event["items"] || []} class="publisher-impact-row">
            <td class="pf-v6-c-table__td" data-label="Recorded result / target">
              <strong>{item["check_label"]} · {item["result_label"]}</strong><span class="preview-caption publication-secondary">{get_in(
                item,
                ["target", "label"]
              ) || "Unresolved target"} · {item["environment"] || "Unscoped"}</span><span
                :if={item["catalogue_unknown"]}
                class="preview-caption publication-secondary"
              >No supported declaration catalogue; retained scheduled results describe known impact.</span>
            </td><td class="pf-v6-c-table__td" data-label="Saved evidence">
              <span :if={item["successor_health"]}>Replacement's last measured health: {health(
                item["successor_health"]
              )}</span><.link
                :if={retained_witness?(item)}
                patch={owner_url(@current, %{"evidence_id" => item["successor_observation_id"]})}
              >Inspect saved measurement</.link><details :if={retained_witness?(item)}>
                <summary>Saved replacement evidence reference</summary><p>
                  Measurement {item["successor_observation_id"]}, configuration version {item[
                    "successor_generation"
                  ]}.
                </p>
              </details>
            </td><td class="pf-v6-c-table__td publication-links" data-label="Current evidence">
              <.link
                :if={item["stream_id"]}
                patch={entity_path(@current, {"result", item["stream_id"]})}
              >Inspect predecessor result history</.link><.link
                :if={item["successor_stream_id"]}
                patch={entity_path(@current, {"result", item["successor_stream_id"]})}
              >Inspect replacement result</.link>
            </td>
          </tr>
        </tbody>
      </table>
      <div id="publisher-saved-decision-pages">
        <PreviewPagination.pagination
          page={@event["page"]}
          size={@event["page_size"] || 25}
          total={@event["total"]}
          label="Saved decision impact pages"
          url={fn page -> owner_url(@current, %{"event_page" => page, "evidence_id" => nil}) end}
        />
      </div>
    </PreviewDetail.card>
    """
  end

  defp saved_measurement(assigns) do
    evidence = assigns.evidence || %{}
    observation = evidence["observation"] || %{}

    results =
      Enum.filter(
        get_in(observation, ["payload", "results"]) || [],
        &(&1["key"] in (evidence["referenced_result_keys"] || []))
      )

    assigns =
      assign(assigns,
        observation: observation,
        results: results,
        witnesses: evidence["witnesses"] || [],
        configuration: evidence["configuration"]
      )

    ~H"""
    <PreviewDetail.card
      id="publisher-saved-measurement"
      phx-mounted={JS.focus(to: "#publisher-saved-measurement-heading")}
      title="Saved replacement measurement"
      level={2}
      data-observation-id={@observation["id"]}
    >
      <p :if={@evidence} class="publication-message">
        This is the original measurement retained for this saved decision. It describes health at that time, not current health.
      </p>
      <p :if={@evidence_missing} id="publisher-saved-measurement-missing" class="publication-message">
        No retained measurement is available for this reference in this decision. Older records may have expired before evidence retention was introduced. The saved decision's identity and recorded health remain available above.
      </p>
      <%= if @evidence do %>
        <div :for={result <- @results} data-saved-result-key={result["key"]}>
          <PreviewDetail.facts
            label={"Saved measurement: " <> result["key"]}
            class="publisher-saved-result"
          >
            <tr>
              <th scope="row">Result</th><td>{saved_result_label(@witnesses, result["key"])}</td>
            </tr>
            <tr>
              <th scope="row">Last measured health</th><td>
                <span class={["pf-v6-c-label", health_tone(result["health"])]}><span class="pf-v6-c-label__content">{health(
                  result["health"]
                )}</span></span>
              </td>
            </tr>
            <tr :if={!is_nil(result["value"])}>
              <th scope="row">Measured value</th><td>Measured value: {result["value"]}</td>
            </tr>
            <tr>
              <th scope="row">Finding</th><td>{result["summary"]}</td>
            </tr>
            <tr :if={result["details"] not in [nil, ""]}>
              <th scope="row">Check details</th><td>
                <MondekWeb.CheckDetails.check_details text={result["details"]} />
              </td>
            </tr>
            <tr :if={result["impacts"] not in [nil, []]}>
              <th scope="row">Declared impacts</th><td>
                {Enum.map_join(result["impacts"], ", ", & &1["label"])}
              </td>
            </tr>
            <tr>
              <th scope="row">Source time</th><td>
                <time datetime={result["source_at"]}>{result["source_at"] || "Not reported"}</time>
              </td>
            </tr>
          </PreviewDetail.facts>
        </div>
        <PreviewDetail.facts label="Saved execution">
          <tr>
            <th scope="row">Evaluation completed</th><td>
              <time datetime={@observation["evaluated_at"]}>{@observation["evaluated_at"]}</time>
            </td>
          </tr><tr>
            <th scope="row">Execution started</th><td>
              <time datetime={@observation["started_at"]}>{@observation["started_at"]}</time>
            </td>
          </tr><tr>
            <th scope="row">Controller received</th><td>
              <time datetime={@observation["received_at"]}>{@observation["received_at"]}</time>
            </td>
          </tr><tr>
            <th scope="row">Configuration version</th><td>{@observation["generation"]}</td>
          </tr>
        </PreviewDetail.facts>
        <details
          id="publisher-saved-measurement-provenance"
          class="publication-disclosure"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Original measurement and configuration details</summary><p class="publication-message">
            Only result keys referenced by this decision establish its replacement evidence.
          </p><PreviewDetail.facts label="Saved measurement identity">
            <tr>
              <th scope="row">Measurement identity</th><td>{@observation["id"]}</td>
            </tr><tr>
              <th scope="row">Runner session</th><td>{@observation["session_id"]}</td>
            </tr><tr>
              <th scope="row">Execution sequence</th><td>{@observation["sequence"]}</td>
            </tr>
          </PreviewDetail.facts><p :if={!@configuration} class="publication-message">
            The original configuration record is no longer retained.
          </p><div :if={@configuration} class="publication-message">
            <h3>Parameters used for this measurement</h3><pre class="preview-findings">{Jason.encode!(@configuration["params"] || %{}, pretty: true)}</pre>
          </div>
        </details>
      <% end %>
    </PreviewDetail.card>
    """
  end

  attr :listing, :map, required: true
  attr :event, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp event_pager(assigns) do
    ~H"""
    <div id={@id}>
      <PreviewPagination.pagination
        :if={!@disabled}
        page={@listing["page"] || 1}
        size={@listing["page_size"] || 25}
        total={@listing["total"] || 0}
        label={@label}
        event={@event}
      /><p :if={@disabled && pages(@listing) > 1} class="publication-message">
        Review again before paging this changed decision.
      </p>
    </div>
    """
  end

  defp entity_path(current, identity) do
    trail = InvestigationTrail.resolve(URI.decode_query(URI.parse(current).query || ""))

    case InvestigationTrail.open(trail, identity) do
      {:ok, next} -> InvestigationTrail.path(current, next)
      _ -> current
    end
  end

  defp owner_url(current, changes) do
    uri = URI.parse(current)

    params =
      URI.decode_query(uri.query || "")
      |> Map.drop(~w(inspect surface page_entity))
      |> Map.merge(changes)
      |> Map.reject(fn {_, value} -> value in [nil, ""] end)

    uri.path <>
      if(map_size(params) == 0, do: "", else: "?" <> URI.encode_query(Enum.sort(params)))
  end

  defp publication_back_label("/runners" <> _), do: "Back to runner"
  defp publication_back_label("/coverage/publishers" <> _), do: "Back to source publications"
  defp publication_back_label("/coverage" <> _), do: "Back to Coverage"
  defp publication_back_label(nil), do: "Back to source publications"
  defp publication_back_label(_), do: "Back"

  defp publication_meaning("retired"),
    do:
      "Retired from this controller. An offline runner may continue executing; stop or remove its deployment separately. Retained measurements and incident history remain inspectable. A later restoration creates new check instances using defaults from code and matching rules; individual exceptions and acknowledgements remain with the retired instances."

  defp publication_meaning("awaiting_inventory"),
    do:
      "Waiting for a new publication. Restoration permits a newer complete inventory; it does not revive previous health, result episodes or acknowledgements."

  defp publication_meaning(_),
    do:
      "This runner publishes its own source declarations and measurements. Other observers keep independent evidence."

  defp status_tone("active"), do: "pf-m-green"
  defp status_tone("awaiting_inventory"), do: "pf-m-orange"
  defp status_tone(_), do: ""
  defp health_tone("OK"), do: "pf-m-green"
  defp health_tone("CRIT"), do: "pf-m-red"
  defp health_tone("WARN"), do: "pf-m-orange"
  defp health_tone(_), do: ""

  defp count(map, key), do: (map || %{})[key] || 0

  defp retained_witness?(item),
    do:
      item["selected"] == true && item["replacement_status"] == "ready" &&
        not is_nil(item["successor_observation_id"])

  defp saved_result_label(witnesses, key) do
    case Enum.find(witnesses, &(&1["result_key"] == key)) do
      nil ->
        key

      witness ->
        Enum.join(
          Enum.reject([witness["check_label"], witness["result_label"]], &is_nil/1),
          " · "
        )
    end
  end

  defp health("OK"), do: "Healthy"
  defp health("WARN"), do: "Warning"
  defp health("CRIT"), do: "Critical"
  defp health(_), do: "Unknown"
  defp pages(map), do: max(1, ceil(count(map, "total") / ((map || %{})["page_size"] || 25)))
  defp positive(n) when is_integer(n), do: max(n, 1)

  defp positive(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, ""} -> max(1, value)
      _ -> 1
    end
  end

  defp positive(_), do: 1

  defp bounded_search(value) when is_binary(value) and byte_size(value) <= 200,
    do: if(String.valid?(value) and not String.contains?(value, <<0>>), do: value, else: "")

  defp bounded_search(_), do: ""

  defp same_id?(a, b) when (is_binary(a) or is_integer(a)) and (is_binary(b) or is_integer(b)),
    do: to_string(a) == to_string(b)

  defp same_id?(_, _), do: false

  defp publisher_name(p),
    do: p["runner_label"] || get_in(p, ["runner_context", "label"]) || "Publishing runner"

  defp publication_path(id, page \\ 1),
    do: "/coverage/publishers/#{id}" <> if(page > 1, do: "?history_page=#{page}", else: "")

  defp coverage_path(p) do
    filters = %{"source_id" => p["source_id"]}

    filters =
      if p["lifecycle_status"] == "active",
        do: Map.put(filters, "runner_id", p["runner_id"]),
        else: filters

    "/coverage?" <> URI.encode_query(filters)
  end

  defp checks_path(p),
    do: "/checks?" <> URI.encode_query(%{"runner_id" => p["runner_id"], "status" => "all"})

  defp status("retired"), do: "Retired from this controller"
  defp status("awaiting_inventory"), do: "Waiting for a new publication"
  defp status(_), do: "Active publication"
  defp action_name("replace"), do: "replacement"
  defp action_name("restore"), do: "restoration"
  defp action_name(_), do: "retirement"

  defp action_help("replace"),
    do:
      "Retire this publication and record where its exact selected scopes are now observed. This does not elect a permanent owner."

  defp action_help("restore"),
    do:
      "Permit a newer complete source inventory. Previous reports and controls are not reactivated."

  defp action_help(_),
    do:
      "Withdraw this publication from active coverage and stop accepting its current measurements. Offline execution can continue."

  defp preview_effect("restore"),
    do:
      "A newer complete inventory and fresh authorized measurements are required before this publication establishes coverage again."

  defp preview_effect(_),
    do:
      "Open result episodes end with an explicit monitoring lifecycle reason. Their history remains available; retirement is not measured recovery. Shared incidents can remain open through other contributions."

  defp receipt_notice(receipt, action) do
    if get_in(receipt, ["publisher", "lifecycle_revision"]) !=
         get_in(receipt, ["receipt", "lifecycle_revision"]) or
         get_in(receipt, ["publisher", "lifecycle_status"]) !=
           get_in(receipt, ["receipt", "after", "lifecycle_status"]) do
      "This decision was already recorded. The publication has changed since then; its current state is shown."
    else
      applied_notice(action)
    end
  end

  defp applied_notice("restore"),
    do: "Restoration recorded. Waiting for a new publication and fresh measurements."

  defp applied_notice("replace"),
    do:
      "Replacement recorded. The old publication is retired from this controller; its history is retained."

  defp applied_notice(_),
    do: "Publication retired from this controller. Stop or remove its deployment separately."

  defp history_action("restore"), do: "Restoration requested"
  defp history_action("replace"), do: "Replacement recorded"
  defp history_action(_), do: "Publication retired"
  defp replacement_status("ready"), do: "Replacement measurement ready"
  defp replacement_status("missing"), do: "No matching replacement result"
  defp replacement_status("unadmitted"), do: "Replacement result is not admitted"
  defp replacement_status("unconfirmed"), do: "Replacement catalogue is unconfirmed"
  defp replacement_status("not_fresh"), do: "Replacement needs a fresh desired measurement"
  defp replacement_status("incompatible"), do: "Replacement contract differs"
  defp replacement_status("unresolved"), do: "Scope is unresolved"
  defp replacement_status(_), do: "Inspect replacement evidence"

  defp version_difference?(preview) do
    a = preview["publisher"] || %{}
    b = preview["successor"] || %{}
    map_size(b) > 0 and Enum.any?(~w(code_revision runtime_revision), &(a[&1] != b[&1]))
  end

  defp utc(nil), do: "Not reported"
  defp utc(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp utc(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> utc(at)
      _ -> "Not reported"
    end
  end

  defp utc(_), do: "Not reported"
  defp error_message({:invalid, message}) when is_binary(message), do: message
  defp error_message(:not_found), do: "This source publication could not be found."

  defp error_message(:review_expired),
    do: "This review has expired. Preview the retained draft again."

  defp error_message(reason) when reason in [:stale, :review_changed, :invalid_review],
    do:
      "Publication state or the reviewed impact changed. Preview the retained draft again before applying it."

  defp error_message(_),
    do:
      "This decision could not be completed. Refresh the publication and review its impact again."
end

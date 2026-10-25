# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PublisherLive do
  use MondekWeb, :live_view

  alias Mondek.PublisherLifecycle
  alias Phoenix.LiveView.JS

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
  def handle_params(params, _uri, socket) do
    same? = socket.assigns.publication_id == params["id"]

    socket =
      assign(socket,
        publication_id: params["id"],
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
        key in ~w(action reason successor_id) and is_binary(value) and byte_size(value) <= 2048
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
    <MondekWeb.Layouts.app
      active={:coverage}
      page_title="Coverage"
      snapshot={@navigation_counts}
      now={@now}
      flash={@flash}
      main_class="publisher-page"
    >
      <MondekWeb.Layouts.section_header
        section="Coverage"
        description="Which results should exist, which runners are selected, and whether measurements are arriving."
        nav_label="Coverage views"
      >
        <:tabs>
          <.link navigate="/coverage">Intended results</.link><.link
            navigate="/coverage/publishers"
            aria-current="page"
          >Runner declarations</.link><.link navigate="/coverage/diagnostics">Unresolved declarations</.link>
        </:tabs>
      </MondekWeb.Layouts.section_header>
      <.link navigate="/coverage/publishers" class="back">All publishing runners</.link>
      <p :if={@error} id="publisher-error" class="notice error" role="alert">{@error}</p>
      <p :if={@notice} id="publisher-notice" class="notice" role="status">{@notice}</p>
      <div :if={is_nil(@detail)} class="panel panel-body" id="publisher-missing">
        <h2>Publication not found</h2><p>
          Choose a publication from Publishing runners to inspect its lifecycle.
        </p>
      </div>
      <.publication :if={@detail} detail={@detail} />
      <.lifecycle_form
        :if={@detail && @proposal}
        proposal={@proposal}
        publisher={@detail["publisher"]}
        preview={@preview}
        token={@review_token}
        stale={@review_stale}
        successors={@successors}
        search={@successor_search}
        successor_page={@successor_page}
        selected={@selected_successor}
      />
      <.history :if={@detail} history={@detail["history"]} publisher_id={@publication_id} />
      <.saved_event
        :if={@detail && @event}
        event={@event}
        publisher_id={@publication_id}
        history_page={@history_page}
      />
      <.saved_measurement
        :if={@detail && @event && @evidence_id}
        evidence={@evidence}
        missing={@evidence_missing}
      />
    </MondekWeb.Layouts.app>
    """
  end

  defp publication(assigns) do
    assigns =
      assign(assigns, publisher: assigns.detail["publisher"], summary: assigns.detail["summary"])

    ~H"""
    <div class="page-heading view-heading">
      <div>
        <div class="eyebrow">Source publication</div><h2 id="publisher-heading">
          {publisher_name(@publisher)}
        </h2><p>{@publisher["source_id"]}</p>
      </div><span id="publisher-status" class="badge">{status(@publisher["lifecycle_status"])}</span>
    </div>
    <section
      class="panel panel-body publisher-summary"
      id="publisher-summary"
      aria-label="Publication and monitoring scope"
    >
      <p :if={@publisher["lifecycle_status"] == "active"}>
        This runner publishes its own source declarations and measurements. Other observers keep independent evidence.
      </p>
      <p :if={@publisher["lifecycle_status"] == "retired"}>
        Retired from this controller. An offline runner may continue executing; stop or remove its deployment separately. Its retained measurements and incident history remain inspectable.
      </p>
      <p :if={@publisher["lifecycle_status"] == "awaiting_inventory"}>
        Waiting for a new publication. Restoration permits a newer complete inventory; it does not revive previous health, result episodes or acknowledgements.
      </p>
      <dl class="publisher-counts">
        <div>
          <dt>Active checks</dt><dd>{count(@summary, "assignments")}</dd>
        </div>
        <div>
          <dt>Active results</dt><dd>{count(@summary, "results")}</dd>
        </div>
        <div>
          <dt>
            {if @publisher["lifecycle_status"] == "active",
              do: "Declared scopes",
              else: "Retained declared scopes"}
          </dt><dd>{count(@summary, "declared_scopes")}</dd>
        </div>
        <div>
          <dt>Open result incidents</dt><dd>{count(@summary, "open_incidents")}</dd>
        </div>
      </dl>
      <div class="actions">
        <.link navigate={coverage_path(@publisher)} class="button secondary">{if @publisher[
                                                                                   "lifecycle_status"
                                                                                 ] == "active",
                                                                                 do:
                                                                                   "Inspect declared scopes",
                                                                                 else:
                                                                                   "Current scopes from remaining publishers"}</.link>
        <.link navigate={checks_path(@publisher)} class="button secondary">All checks and history from this runner</.link>
        <.link
          navigate={MondekWeb.RunnersLive.detail_path(@publisher["runner_id"])}
          class="text-link"
        >Inspect runner</.link>
        <.link
          :if={@publisher["replacement_id"]}
          navigate={publication_path(@publisher["replacement_id"])}
          class="text-link"
        >Inspect recorded replacement</.link>
      </div>
      <details
        id="publisher-provenance"
        class="diagnostic-details"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Publication and restoration details</summary>
        <dl class="coverage-identity">
          <div>
            <dt>Last controller contact</dt><dd>{utc(@publisher["last_seen_at"])}</dd>
          </div>
          <div>
            <dt>Accepted inventory</dt><dd>Version {@publisher["inventory_revision"]}</dd>
          </div>
          <div>
            <dt>Lifecycle revision</dt><dd>{@publisher["lifecycle_revision"]}</dd>
          </div>
          <div :if={@publisher["retired_at"]}>
            <dt>Retired</dt><dd>{utc(@publisher["retired_at"])}</dd>
          </div>
          <div :if={@publisher["retirement_reason"]}>
            <dt>Retirement reason</dt><dd>{@publisher["retirement_reason"]}</dd>
          </div>
          <div>
            <dt>Runner identity</dt><dd><code>{@publisher["runner_id"]}</code></dd>
          </div>
        </dl>
        <p :if={@publisher["lifecycle_status"] == "awaiting_inventory"} class="footnote">
          The current SDK rediscovers the installed consumer after receiving this restoration request and publishes a newer inventory. Failed discovery leaves this publication waiting. Upgrade older SDKs and restart the runner to support restoration. Cached inventories and old buffered reports cannot establish restored coverage.
        </p>
      </details>
    </section>
    """
  end

  defp lifecycle_form(assigns) do
    ~H"""
    <section class="panel publisher-lifecycle" aria-labelledby="publisher-lifecycle-heading">
      <div class="panel-heading">
        <h2 id="publisher-lifecycle-heading">Manage this publication</h2>
      </div>
      <div class="panel-body">
        <p>
          Review the exact impact before applying a decision. No action transfers measurements or individual acknowledgements to another observer.
        </p>
        <form
          id="publisher-lifecycle-form"
          phx-change="edit"
          phx-submit={if @preview && !@stale, do: "apply", else: "preview"}
          phx-auto-recover="recover"
        >
          <input type="hidden" name="_proposal" value={Jason.encode!(@proposal)} />
          <input :if={@token} type="hidden" name="_review_token" value={@token} />
          <input type="hidden" name="_preview_page" value={(@preview || %{})["page"] || 1} />
          <input type="hidden" name="_successor_page" value={@successor_page} />
          <input type="hidden" name="lifecycle[successor_id]" value={@proposal["successor_id"] || ""} />
          <label for="publisher-action">Decision</label>
          <select id="publisher-action" name="lifecycle[action]">
            <option value="retire" selected={@proposal["action"] == "retire"}>
              Retire this publication
            </option>
            <option value="replace" selected={@proposal["action"] == "replace"}>
              Retire with a recorded replacement
            </option>
            <option value="restore" selected={@proposal["action"] == "restore"}>
              Restore this publication
            </option>
          </select>
          <p class="footnote">{action_help(@proposal["action"])}</p>
          <fieldset :if={@proposal["action"] == "replace"} class="publisher-successor-picker">
            <legend>Replacement observer</legend>
            <p>
              Choose an active publication of the same source. The preview checks every selected result's exact scope and fresh desired measurement.
            </p>
            <p id="publisher-selected-successor" class="notice">
              {if @selected,
                do: "Selected: " <> publisher_name(@selected),
                else: "No replacement selected."}
            </p>
            <details id="publisher-successor-choices" open={is_nil(@preview)}>
              <summary>Choose or change replacement observer</summary>
              <label for="publisher-successor-search">Search replacement observers</label>
              <input
                id="publisher-successor-search"
                name="successor_search"
                value={@search}
                phx-debounce="300"
                placeholder="Runner name or context"
                maxlength="200"
              />
              <div id="publisher-successors">
                <p :if={@successors["items"] == []} class="space-top">
                  No active publications match. Deploy a runner for this source, or choose retirement without a replacement.
                </p>
                <article
                  :for={candidate <- @successors["items"] || []}
                  data-successor-id={candidate["id"]}
                >
                  <div>
                    <strong>{publisher_name(candidate)}</strong><p class="footnote">
                      Last contact: {utc(candidate["last_seen_at"])}
                    </p>
                  </div>
                  <button
                    type="button"
                    class="button small secondary"
                    phx-click="choose_successor"
                    phx-value-id={candidate["id"]}
                    disabled={same_id?(candidate["id"], @proposal["successor_id"])}
                    aria-label={"Choose observer " <> publisher_name(candidate)}
                  >{if same_id?(candidate["id"], @proposal["successor_id"]),
                    do: "Selected",
                    else: "Choose observer"}</button>
                </article>
              </div>
              <.event_pager
                listing={@successors}
                event="successor_page"
                id="publisher-successor-pages"
                label="Replacement observer pages"
              />
            </details>
          </fieldset>
          <label for="publisher-reason" class="space-top">Reason</label>
          <textarea
            id="publisher-reason"
            name="lifecycle[reason]"
            rows="3"
            maxlength="500"
            required
            aria-describedby="publisher-reason-help"
          >{@proposal["reason"]}</textarea>
          <p id="publisher-reason-help" class="footnote">
            Record why this publication is changing. The reason is retained in lifecycle history.
          </p>
          <div :if={is_nil(@preview) || @stale} class="actions space-top">
            <button id="publisher-preview-button" type="submit" class="button">{if @stale,
              do: "Preview again",
              else: "Preview impact"}</button>
          </div>
          <.preview :if={@preview} preview={@preview} stale={@stale} />
        </form>
      </div>
    </section>
    """
  end

  defp preview(assigns) do
    assigns =
      assign(assigns, summary: assigns.preview["summary"], proposal: assigns.preview["proposal"])

    ~H"""
    <section
      id="publisher-preview"
      class="publisher-preview"
      aria-labelledby="publisher-preview-heading"
    >
      <h3 id="publisher-preview-heading">Review {action_name(@proposal["action"])}</h3>
      <p><strong>Reason:</strong> {@proposal["reason"]}</p>
      <p :if={@stale} class="notice error">
        This review is no longer current. Your draft is retained; preview again before applying it.
      </p>
      <p :if={@preview["successor"]}>
        Recorded replacement: <strong>{publisher_name(@preview["successor"])}</strong>
      </p>
      <dl id="publisher-preview-summary" class="publisher-counts">
        <div>
          <dt>Checks affected</dt><dd>{count(@summary, "assignments")}</dd>
        </div>
        <div>
          <dt>Results affected</dt><dd>{count(@summary, "results")}</dd>
        </div>
        <div>
          <dt>Open result incidents</dt><dd>{count(@summary, "open_incidents")}</dd>
        </div>
        <div>
          <dt>Shared incidents involved</dt><dd>{count(@summary, "shared_incidents")}</dd>
        </div>
        <div :if={@proposal["action"] != "restore"}>
          <dt>Scopes losing their last publisher</dt><dd>
            {count(@summary, "scopes_losing_last_publisher")}
          </dd>
        </div>
        <div :if={@proposal["action"] != "restore"}>
          <dt>Scopes losing their last selected observer</dt><dd>
            {count(@summary, "scopes_losing_last_selected")}
          </dd>
        </div>
        <div :if={@proposal["action"] == "replace"}>
          <dt>Replacement results ready</dt><dd>{count(@summary, "matched_results")}</dd>
        </div>
        <div :if={@proposal["action"] == "replace"}>
          <dt>Replacement gaps</dt><dd>{count(@summary, "replacement_gaps")}</dd>
        </div>
      </dl>
      <p>{preview_effect(@proposal["action"])}</p>
      <p :if={@proposal["action"] == "restore"}>
        Restored checks use defaults from code and matching configuration rules. Individual check exceptions and acknowledgements remain with retired instances.
      </p>
      <p :if={@proposal["action"] == "replace"}>
        The replacement keeps its own effective settings. Individual check exceptions and acknowledgements are not transferred from this publication.
      </p>
      <p :if={@proposal["action"] == "retire"}>
        A later restoration creates new check instances using defaults from code and matching configuration rules. Individual check exceptions and acknowledgements remain with the retired instances.
      </p>
      <div :if={@preview["blockers"] != []} id="publisher-preview-blockers" class="notice error">
        <strong>This decision cannot be applied yet.</strong><ul>
          <li :for={blocker <- @preview["blockers"] || []}>{blocker}</li>
        </ul>
      </div>
      <p :if={version_difference?(@preview)} class="notice">
        The publications report different package or runtime versions. No shared latest release is inferred; inspect their declared contracts and reviewed impact.
      </p>
      <div class="actions space-top">
        <button
          id="publisher-apply"
          type="submit"
          class="button"
          disabled={@stale || !@preview["can_apply"]}
        >Apply {action_name(@proposal["action"])}</button>
        <button type="button" class="button secondary" phx-click="back">Discard review</button>
      </div>
      <details
        id="publisher-impact"
        class="diagnostic-details"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Inspect affected scopes ({@preview["total"]})</summary>
        <p class="footnote">
          Counts above cover the whole publication. Each page shows at most {@preview["page_size"] ||
            25} result declarations.
        </p>
        <p :if={@preview["items"] == []}>There are no result declarations in this publication.</p>
        <article
          :for={item <- @preview["items"] || []}
          class="publisher-impact-row"
          data-impact-scope={item["scope_id"]}
        >
          <h4>{item["check_label"]} · {item["result_label"]}</h4>
          <p>
            {get_in(item, ["target", "label"]) || "Unresolved target"} · {item["environment"] ||
              "Unscoped"}
          </p>
          <p>
            {if item["selected"], do: "Selected by this publication", else: "Declared but excluded"}
          </p>
          <p class="footnote">
            Remaining publishers: {item["remaining_publishers"] || 0}; selected observers: {item[
              "remaining_selected"
            ] || 0}.
          </p>
          <p :if={@proposal["action"] == "replace"}>
            {replacement_status(item["replacement_status"])}<span :if={item["replacement_reason"]}>: {item[
              "replacement_reason"
            ]}</span>
          </p>
          <div class="actions">
            <.link
              :if={item["scope_id"]}
              navigate={"/coverage/" <> item["scope_id"]}
              class="text-link"
            >Inspect declared scope</.link>
            <.link
              :if={item["stream_id"]}
              navigate={"/checks/" <> item["stream_id"]}
              class="text-link"
            >Inspect current result</.link>
            <.link
              :if={item["successor_stream_id"]}
              navigate={"/checks/" <> item["successor_stream_id"]}
              class="text-link"
            >Inspect replacement result</.link>
          </div>
        </article>
        <.event_pager
          listing={@preview}
          event="preview_page"
          id="publisher-impact-pages"
          label="Reviewed impact pages"
          disabled={@stale}
        />
      </details>
    </section>
    """
  end

  defp history(assigns) do
    ~H"""
    <section class="panel" id="publisher-history" aria-labelledby="publisher-history-heading">
      <div class="panel-heading">
        <h2 id="publisher-history-heading">Lifecycle history</h2>
      </div>
      <div class="panel-body">
        <p :if={(@history || %{})["items"] in [nil, []]}>
          No lifecycle decisions have been recorded.
        </p>
        <article :for={event <- (@history || %{})["items"] || []} class="publisher-history-event">
          <h3>{history_action(event["action"])}</h3><p>{event["reason"]}</p>
          <p class="footnote">
            {utc(event["inserted_at"])} · {event["actor"] || "Local operator"} · Lifecycle revision {event[
              "lifecycle_revision"
            ]}
          </p>
          <div class="actions">
            <.link
              patch={event_path(@publisher_id, event["id"], 1, @history["page"])}
              phx-click={JS.focus(to: "#publisher-saved-decision-heading")}
              class="text-link"
            >Inspect saved decision and evidence</.link>
            <.link
              :if={event["successor_id"]}
              navigate={publication_path(event["successor_id"])}
              class="text-link"
            >Inspect recorded replacement</.link>
          </div>
          <details
            id={"publisher-event-" <> to_string(event["id"])}
            class="diagnostic-details"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Reviewed impact</summary><p>
              {count(event["summary"], "assignments")} checks; {count(event["summary"], "results")} results; {count(
                event["summary"],
                "open_incidents"
              )} open result incidents.
            </p>
          </details>
        </article>
        <nav
          :if={pages(@history) > 1}
          id="publisher-history-pages"
          class="pagination"
          aria-label="Publication history pages"
        >
          <.link
            :if={@history["page"] > 1}
            patch={publication_path(@publisher_id, @history["page"] - 1)}
            class="button small secondary"
          >Previous</.link>
          <span>Page {@history["page"]} of {pages(@history)}</span>
          <.link
            :if={@history["page"] < pages(@history)}
            patch={publication_path(@publisher_id, @history["page"] + 1)}
            class="button small secondary"
          >Next</.link>
        </nav>
      </div>
    </section>
    """
  end

  defp saved_event(assigns) do
    ~H"""
    <section
      id="publisher-saved-decision"
      class="panel panel-body"
      aria-labelledby="publisher-saved-decision-heading"
      phx-mounted={JS.focus(to: "#publisher-saved-decision-heading")}
    >
      <h2 id="publisher-saved-decision-heading" tabindex="-1">
        Saved {action_name(@event["action"])} decision
      </h2>
      <p>{@event["reason"]}</p>
      <p class="footnote">
        Recorded {utc(@event["inserted_at"])}. These identities and measurements describe the saved decision; current coverage may have changed.
      </p>
      <p>
        {@event["total"]} affected result declarations. Showing page {@event["page"]} of {pages(
          @event
        )}.
      </p>
      <article :for={item <- @event["items"] || []} class="publisher-impact-row">
        <h3>{item["check_label"]} · {item["result_label"]}</h3>
        <p>
          {get_in(item, ["target", "label"]) || "Unresolved target"} · {item["environment"] ||
            "Unscoped"}
        </p>
        <p :if={item["catalogue_unknown"]}>
          This runner did not publish a supported declaration catalogue; retained scheduled results describe the known impact.
        </p>
        <p :if={item["successor_health"]}>
          Replacement's last measured health at the decision: {health(item["successor_health"])}
        </p>
        <div class="actions">
          <.link
            :if={retained_witness?(item)}
            patch={
              evidence_path(
                @publisher_id,
                @event["id"],
                @event["page"],
                @history_page,
                item["successor_observation_id"]
              )
            }
            phx-click={JS.focus(to: "#publisher-saved-measurement-heading")}
            class="text-link"
          >Inspect saved measurement</.link>
          <.link :if={item["stream_id"]} navigate={"/checks/" <> item["stream_id"]} class="text-link">Inspect predecessor result history</.link>
          <.link
            :if={item["successor_stream_id"]}
            navigate={"/checks/" <> item["successor_stream_id"]}
            class="text-link"
          >Inspect replacement result</.link>
        </div>
        <details :if={retained_witness?(item)} class="diagnostic-details">
          <summary>Saved replacement evidence reference</summary><p>
            Measurement <code>{item["successor_observation_id"]}</code>, configuration version {item[
              "successor_generation"
            ]}.
          </p>
        </details>
      </article>
      <nav
        :if={pages(@event) > 1}
        id="publisher-saved-decision-pages"
        class="pagination"
        aria-label="Saved decision impact pages"
      >
        <.link
          :if={@event["page"] > 1}
          patch={event_path(@publisher_id, @event["id"], @event["page"] - 1, @history_page)}
          phx-click={JS.focus(to: "#publisher-saved-decision-heading")}
          class="button small secondary"
        >Previous</.link>
        <span>Page {@event["page"]} of {pages(@event)}</span>
        <.link
          :if={@event["page"] < pages(@event)}
          patch={event_path(@publisher_id, @event["id"], @event["page"] + 1, @history_page)}
          phx-click={JS.focus(to: "#publisher-saved-decision-heading")}
          class="button small secondary"
        >Next</.link>
      </nav>
    </section>
    """
  end

  defp saved_measurement(assigns) do
    evidence = assigns.evidence || %{}
    observation = evidence["observation"] || %{}
    keys = evidence["referenced_result_keys"] || []

    results =
      (get_in(observation, ["payload", "results"]) || []) |> Enum.filter(&(&1["key"] in keys))

    assigns =
      assign(assigns,
        observation: observation,
        results: results,
        witnesses: evidence["witnesses"] || [],
        configuration: evidence["configuration"]
      )

    ~H"""
    <section
      id="publisher-saved-measurement"
      data-observation-id={@observation["id"]}
      class="panel panel-body"
      aria-labelledby="publisher-saved-measurement-heading"
      phx-mounted={JS.focus(to: "#publisher-saved-measurement-heading")}
    >
      <h2 id="publisher-saved-measurement-heading" tabindex="-1">Saved replacement measurement</h2>
      <p :if={@evidence}>
        This is the original measurement retained for this saved decision. It describes health at that time, not current health.
      </p>
      <p :if={@missing} id="publisher-saved-measurement-missing" class="notice">
        No retained measurement is available for this reference in this decision. Older records may have expired before evidence retention was introduced. The saved decision's identity and recorded health remain available above.
      </p>
      <div :if={@evidence}>
        <article
          :for={result <- @results}
          class="publisher-saved-result"
          data-saved-result-key={result["key"]}
        >
          <h3>{saved_result_label(@witnesses, result["key"])}</h3>
          <p class="publisher-saved-health">
            <strong>{health(result["health"])}</strong><span :if={!is_nil(result["value"])}> · Measured value: {result[
              "value"
            ]}</span>
          </p>
          <p class="publisher-saved-summary">{result["summary"]}</p>
          <p :if={result["details"] not in [nil, ""]} class="publisher-saved-details">
            {result["details"]}
          </p>
          <p :if={result["impacts"] not in [nil, []]}>
            Declared impacts: {Enum.map_join(result["impacts"], ", ", & &1["label"])}
          </p>
          <p class="footnote">
            Source time:
            <time datetime={result["source_at"]}>{result["source_at"] || "Not reported"}</time>
          </p>
        </article>
        <dl class="coverage-identity publisher-evidence-identity">
          <div>
            <dt>Evaluation completed</dt><dd>
              <time datetime={@observation["evaluated_at"]}>{@observation["evaluated_at"]}</time>
            </dd>
          </div>
          <div>
            <dt>Execution started</dt><dd>
              <time datetime={@observation["started_at"]}>{@observation["started_at"]}</time>
            </dd>
          </div>
          <div>
            <dt>Controller received</dt><dd>
              <time datetime={@observation["received_at"]}>{@observation["received_at"]}</time>
            </dd>
          </div>
          <div>
            <dt>Configuration version</dt><dd>{@observation["generation"]}</dd>
          </div>
        </dl>
        <details
          id="publisher-saved-measurement-provenance"
          class="diagnostic-details"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Original measurement and configuration details</summary>
          <p>
            Showing the result keys referenced by this decision. Other results in the same execution are not replacement evidence for this decision.
          </p>
          <dl class="coverage-identity">
            <div>
              <dt>Measurement identity</dt><dd><code>{@observation["id"]}</code></dd>
            </div>
            <div>
              <dt>Runner session</dt><dd><code>{@observation["session_id"]}</code></dd>
            </div>
            <div>
              <dt>Execution sequence</dt><dd>{@observation["sequence"]}</dd>
            </div>
          </dl>
          <p :if={is_nil(@configuration)}>The original configuration record is no longer retained.</p>
          <div :if={@configuration}>
            <h3>Parameters used for this measurement</h3>
            <pre>{Jason.encode!(@configuration["params"] || %{}, pretty: true)}</pre>
          </div>
        </details>
      </div>
    </section>
    """
  end

  attr :listing, :map, required: true
  attr :event, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  defp event_pager(assigns) do
    ~H"""
    <nav :if={pages(@listing) > 1} id={@id} class="pagination" aria-label={@label}>
      <button
        :if={@listing["page"] > 1}
        type="button"
        class="button small secondary"
        phx-click={@event}
        phx-value-page={@listing["page"] - 1}
        disabled={@disabled}
      >Previous</button>
      <span>Page {@listing["page"]} of {pages(@listing)}</span>
      <button
        :if={@listing["page"] < pages(@listing)}
        type="button"
        class="button small secondary"
        phx-click={@event}
        phx-value-page={@listing["page"] + 1}
        disabled={@disabled}
      >Next</button>
    </nav>
    """
  end

  defp count(map, key), do: (map || %{})[key] || 0

  defp event_path(id, event, page, history_page),
    do:
      "/coverage/publishers/#{id}?" <>
        URI.encode_query(%{
          "event_id" => event,
          "event_page" => page,
          "history_page" => history_page || 1
        })

  defp evidence_path(id, event, page, history_page, evidence),
    do:
      event_path(id, event, page, history_page) <>
        "&" <> URI.encode_query(%{"evidence_id" => evidence})

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
  defp bounded_search(value) when is_binary(value) and byte_size(value) <= 200, do: value
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

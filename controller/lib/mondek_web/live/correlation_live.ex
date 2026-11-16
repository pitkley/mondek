# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CorrelationLive do
  use MondekWeb, :live_view
  alias Mondek.{Correlations, Investigation, Monitoring}
  alias MondekWeb.PreviewDetail

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2000)

    {:ok,
     assign(socket,
       page_title: "Correlation cases",
       detail: nil,
       review: nil,
       error: nil,
       control_review: nil,
       control_draft: %{"action" => "acknowledge", "note" => "", "seconds" => ""},
       draft: %{
         "action" => "create",
         "title" => "",
         "reason" => "",
         "other_case_id" => "",
         "anchor" => "",
         "episodes" => []
       }
     )}
  end

  @impl true
  def handle_params(params, _, socket) do
    result =
      Investigation.read(fn ->
        %{
          "listing" => Correlations.list(params),
          "detail" => if(params["id"], do: Correlations.detail(params["id"], params)),
          "candidates" =>
            Correlations.candidates(
              %{"status" => "open", "page" => params["candidates_page"] || 1},
              Monitoring.now()
            )
        }
      end)

    case result do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           current_params: params,
           listing: data["listing"],
           detail: data["detail"],
           candidates: data["candidates"],
           current_path:
             if(params["id"], do: "/incidents/cases/#{params["id"]}", else: "/incidents/cases")
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Investigation unavailable.")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2000)
    handle_params(socket.assigns.current_params, nil, socket)
  end

  @impl true
  def handle_event("draft", %{"grouping" => draft}, socket),
    do: {:noreply, assign(socket, draft: draft, review: nil, error: nil)}

  def handle_event("review", %{"grouping" => draft}, socket) do
    proposal = proposal(draft, socket.assigns.detail)

    case Correlations.preview(proposal) do
      {:ok, preview} ->
        {:noreply, assign(socket, draft: draft, review: preview, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, draft: draft, review: nil, error: message(reason))}
    end
  end

  def handle_event("apply", _, %{assigns: %{review: %{"review_token" => token}}} = socket) do
    case Correlations.apply(token) do
      {:ok, receipt} ->
        {:noreply, push_navigate(socket, to: "/incidents/cases/#{receipt["case_id"]}")}

      {:error, reason} ->
        {:noreply, assign(socket, review: nil, error: message(reason))}
    end
  end

  def handle_event("apply", _, socket),
    do: {:noreply, assign(socket, error: "Review the change before applying.")}

  def handle_event("control_change", %{"control" => p}, socket),
    do: {:noreply, assign(socket, control_draft: p, control_review: nil)}

  def handle_event("control_review", %{"control" => p}, socket) do
    fields = %{"action" => p["action"], "note" => p["note"], "request_id" => Ecto.UUID.generate()}

    seconds =
      if p["seconds"] in [nil, ""] do
        nil
      else
        case Integer.parse(p["seconds"]) do
          {n, ""} -> n
          _ -> 0
        end
      end

    fields =
      if seconds && p["action"] == "acknowledge",
        do: Map.put(fields, "seconds", seconds),
        else: fields

    case Mondek.CaseControls.preview(socket.assigns.detail["case"]["id"], fields) do
      {:ok, review} ->
        {:noreply, assign(socket, control_review: review, control_draft: p, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, control_review: nil, control_draft: p, error: message(reason))}
    end
  end

  def handle_event(
        "control_apply",
        _,
        %{assigns: %{control_review: %{"review_token" => token}}} = socket
      ) do
    case Mondek.CaseControls.apply(token) do
      {:ok, _} -> {:noreply, push_navigate(socket, to: socket.assigns.current_path)}
      {:error, reason} -> {:noreply, assign(socket, error: message(reason), control_review: nil)}
    end
  end

  defp proposal(d, detail) do
    decode = fn s ->
      if s in [nil, ""],
        do: nil,
        else:
          s
          |> String.split(":", parts: 2)
          |> then(fn
            [type, id] -> %{"type" => type, "id" => id}
            _ -> %{"type" => "invalid", "id" => "invalid"}
          end)
    end

    %{
      "action" => d["action"] || "create",
      "request_id" => Ecto.UUID.generate(),
      "title" => d["title"] || "Correlation case",
      "reason" => d["reason"] || "Manual grouping",
      "episodes" => Enum.map(List.wrap(d["episodes"]), decode),
      "anchor" => decode.(d["anchor"]),
      "case_id" => detail && detail["case"]["id"],
      "other_case_id" => if(d["other_case_id"] in [nil, ""], do: nil, else: d["other_case_id"])
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> then(fn p ->
      allowed =
        case p["action"] do
          "create" -> ~w(action request_id title reason episodes anchor)
          "split" -> ~w(action request_id case_id title reason episodes anchor)
          "anchor" -> ~w(action request_id case_id reason anchor)
          "merge" -> ~w(action request_id case_id other_case_id reason)
          _ -> ~w(action request_id case_id reason episodes)
        end

      Map.take(p, allowed)
    end)
  end

  defp message({:invalid, m}), do: m

  defp message(reason),
    do: "Grouping could not be applied: #{reason}. Review the current records."

  defp encoded(r), do: r["type"] <> ":" <> r["id"]

  defp choices(detail, candidates) do
    Enum.map(
      Enum.filter((detail && detail["members"]["items"]) || [], &is_nil(&1["ended_at"])),
      & &1["episode"]
    ) ++
      Enum.map(candidates["items"], &%{"type" => &1["incident_type"], "id" => &1["id"]})
  end

  defp retained_anchor(draft, detail, candidates) do
    draft["anchor"] not in [nil, ""] and
      draft["anchor"] not in Enum.map(choices(detail, candidates), &encoded/1)
  end

  defp hidden_selection(draft, detail, candidates) do
    visible =
      candidates["items"]
      |> Enum.filter(&is_nil(&1["correlation"]))
      |> Enum.map(&(&1["incident_type"] <> ":" <> &1["id"]))

    members = (detail && detail["members"]["items"]) || []

    visible =
      visible ++
        (members |> Enum.filter(&is_nil(&1["ended_at"])) |> Enum.map(&encoded(&1["episode"])))

    (draft["episodes"] || []) -- visible
  end

  defp path(base, key, value), do: base <> "?" <> URI.encode_query(%{key => value})

  @impl true
  def render(assigns) do
    ~H"""
    <MondekWeb.PreviewLayouts.app active={:incidents} page_title={@page_title} flash={@flash}>
      <section class="preview-list" id="correlation-cases">
        <header class="preview-heading">
          <h1 class="pf-v6-c-title pf-m-2xl">Correlation cases</h1>
          <.link navigate="/incidents">All incidents</.link>
        </header>
        <p>
          Cases record suspected relationships. Native controls remain independent; enabled case policy can batch exact delivery or hold it under a reviewed acknowledgement.
        </p>
        <PreviewDetail.card id="case-list" title="Cases" level={2}>
          <ul>
            <li :for={c <- @listing["items"]}>
              <.link navigate={"/incidents/cases/#{c["id"]}"}>{c["title"]}</.link>
              — {c["status"]}, {c["open_count"]} unresolved of {c["member_count"]} members
            </li>
          </ul>
          <p :if={@listing["total"] == 0}>
            No cases yet. Select incident episodes below to create one.
          </p>
          <nav aria-label="Case pages">
            <.link
              :if={@listing["page"] > 1}
              patch={path("/incidents/cases", "page", @listing["page"] - 1)}
            >Previous</.link>
            <span>Page {@listing["page"]}</span>
            <.link
              :if={@listing["page"] * 25 < @listing["total"]}
              patch={path("/incidents/cases", "page", @listing["page"] + 1)}
            >Next</.link>
          </nav>
        </PreviewDetail.card>
        <PreviewDetail.card :if={@detail} id="case-detail" title={@detail["case"]["title"]} level={2}>
          <p>
            Correlation hypothesis · {@detail["case"]["status"]} · revision {@detail["case"][
              "revision"
            ]}
          </p>
          <p>Monitored environment: {@detail["case"]["environment"] || "Unspecified"}</p>
          <ul>
            <li :for={m <- @detail["members"]["items"]}>
              <.link navigate={"/incidents/health/#{m["episode"]["id"]}/full"}>{m["incident"][
                "display_title"
              ]}</.link>
              — {m["incident"]["status"]} {m["incident"]["health"]}
              <span :if={m["anchor"]}> · Suspected parent</span>
              <span :if={m["ended_at"]}> · Removed from case ({m["end_reason"]}); this is not recovery</span>
            </li>
          </ul>
          <nav aria-label="Member pages">
            <.link
              :if={@detail["members"]["page"] > 1}
              patch={path(@current_path, "page", @detail["members"]["page"] - 1)}
            >Previous members</.link>
            <.link
              :if={@detail["members"]["page"] * 25 < @detail["members"]["total"]}
              patch={path(@current_path, "page", @detail["members"]["page"] + 1)}
            >More members</.link>
          </nav>
          <h3>Decision history</h3>
          <ul>
            <li :for={d <- @detail["decisions"]["items"]}>
              {d.action} · {d.provenance} · {d.actor} · {Monitoring.iso(d.inserted_at)} · {d.reason}
            </li>
          </ul>
          <nav aria-label="History pages">
            <.link
              :if={@detail["decisions"]["page"] > 1}
              patch={path(@current_path, "history_page", @detail["decisions"]["page"] - 1)}
            >Previous decisions</.link>
            <.link
              :if={@detail["decisions"]["page"] * 25 < @detail["decisions"]["total"]}
              patch={path(@current_path, "history_page", @detail["decisions"]["page"] + 1)}
            >More decisions</.link>
          </nav>
        </PreviewDetail.card>
        <PreviewDetail.card
          :if={@detail}
          id="case-delivery"
          title="Case delivery and acknowledgement"
          level={2}
        >
          <p>
            Batching is {if @detail["delivery"].batching_enabled, do: "enabled", else: "disabled"}. Exact batches never cover later facts.
          </p>
          <p>
            Acknowledgement: {if @detail["delivery"].acknowledgement.active,
              do: "Active",
              else: "Inactive"}. Scope is reviewed members only; native controls remain independent.
          </p>
          <p :if={@detail["delivery"].acknowledgement.active} id="saved-case-ack">
            Saved note: {@detail["delivery"].acknowledgement.note} · ceiling {@detail["delivery"].acknowledgement.ceiling} · until {if @detail[
                                                                                                                                         "delivery"
                                                                                                                                       ].acknowledgement.until,
                                                                                                                                       do:
                                                                                                                                         Mondek.Monitoring.iso(
                                                                                                                                           @detail[
                                                                                                                                             "delivery"
                                                                                                                                           ].acknowledgement.until
                                                                                                                                         ),
                                                                                                                                       else:
                                                                                                                                         "Case ends"}
          </p>
          <.form
            for={%{}}
            as={:control}
            id="case-control-form"
            phx-change="control_change"
            phx-submit="control_review"
          >
            <div class="pf-v6-c-form">
              <label for="case-control-action">Control</label>
              <select id="case-control-action" name="control[action]"><option
                :for={a <- ~w(acknowledge end enable disable)}
                value={a}
                selected={@control_draft["action"] == a}
              >
                {String.capitalize(a)}
              </option></select>
              <label for="case-control-note">Note</label><textarea
                id="case-control-note"
                name="control[note]"
                required
                maxlength="2000"
              >{@control_draft["note"]}</textarea>
              <label for="case-control-seconds">Acknowledgement seconds (blank means until case ends)</label><input
                id="case-control-seconds"
                name="control[seconds]"
                value={@control_draft["seconds"]}
              />
              <button type="submit" class="pf-v6-c-button pf-m-secondary">Review control</button>
            </div>
          </.form>
          <section :if={@control_review} id="case-control-review">
            <h3>Review case control</h3><p>
              {@control_review["case_id"]}: {@control_review["proposal"]["action"]} · {@control_review[
                "proposal"
              ]["note"]}
            </p>
            <p>
              Ceiling: {@control_review["scope"].ceiling}; scope: {@control_review["scope"].scope}. Duration: {@control_review[
                "proposal"
              ]["seconds"] || "Until case ends"}
            </p>
            <ul>
              <li :for={m <- @control_review["scope"].members}>
                {m.label} · {m.episode["id"]} · {m.health} · impacts {Enum.join(m.impacts, ", ")}
              </li>
            </ul>
            <button type="button" phx-click="control_apply">Save case control</button>
          </section>
          <h3>Exact batches</h3>
          <p>
            {@detail["delivery"].batch_page.total} batches. Unfinished work first; terminal scope survives membership moves.
          </p>
          <nav aria-label="Batch pages">
            <.link
              :if={@detail["delivery"].batch_page.page > 1}
              patch={path(@current_path, "batch_page", @detail["delivery"].batch_page.page - 1)}
            >Previous batches</.link><.link
              :if={@detail["delivery"].batch_page.page * 25 < @detail["delivery"].batch_page.total}
              patch={path(@current_path, "batch_page", @detail["delivery"].batch_page.page + 1)}
            >More batches</.link>
          </nav>
          <ul>
            <li :for={b <- @detail["delivery"].batches}>
              {b.id}: {b.status}, terminal {b.terminal_status}
              <ul>
                <li :for={m <- b.members}>{m.occurrence_id}: {m.status}</li>
              </ul>
            </li>
          </ul>
        </PreviewDetail.card>

        <PreviewDetail.card
          :if={!@detail || @detail["case"]["status"] == "open"}
          id="grouping-controls"
          title="Manual grouping"
          level={2}
        >
          <p>
            Review the exact episodes and reason before saving. Create, attach and split use the selected episodes; detach removes selected current members; merge moves all members of the other case here.
          </p>
          <.form for={%{}} as={:grouping} id="grouping-form" phx-change="draft" phx-submit="review">
            <div class="pf-v6-c-form">
              <label for="grouping-action">Action</label>
              <select id="grouping-action" name="grouping[action]" class="pf-v6-c-form-control">
                <option
                  :for={a <- if(@detail, do: ~w(attach detach merge split anchor), else: ["create"])}
                  value={a}
                  selected={@draft["action"] == a}
                >
                  {String.capitalize(a)}
                </option>
              </select>
              <label for="grouping-title">Case title (new case for create or split)</label>
              <input
                id="grouping-title"
                name="grouping[title]"
                value={@draft["title"]}
                maxlength="200"
                required={@draft["action"] in [nil, "create", "split"]}
                class="pf-v6-c-form-control"
              />
              <label for="grouping-reason">Reason</label>
              <textarea
                id="grouping-reason"
                name="grouping[reason]"
                maxlength="2000"
                required
                class="pf-v6-c-form-control"
              >{@draft["reason"]}</textarea>
              <label for="other-case">Other case (merge)</label>
              <input
                id="other-case"
                name="grouping[other_case_id]"
                value={@draft["other_case_id"]}
                placeholder="Case ID"
                class="pf-v6-c-form-control"
              />
              <label for="case-anchor">Suspected parent (create or change parent)</label>
              <select id="case-anchor" name="grouping[anchor]" class="pf-v6-c-form-control">
                <option value="">No parent selected</option>
                <option
                  :if={retained_anchor(@draft, @detail, @candidates)}
                  value={@draft["anchor"]}
                  selected
                >
                  Selected parent: {@draft["anchor"]}
                </option>
                <option
                  :for={m <- (@detail && @detail["members"]["items"]) || []}
                  :if={!m["ended_at"]}
                  value={m["episode"]["type"] <> ":" <> m["episode"]["id"]}
                  selected={@draft["anchor"] == m["episode"]["type"] <> ":" <> m["episode"]["id"]}
                >
                  {m["incident"]["display_title"]}
                </option>
                <option
                  :for={c <- @candidates["items"]}
                  value={c["incident_type"] <> ":" <> c["id"]}
                  selected={@draft["anchor"] == c["incident_type"] <> ":" <> c["id"]}
                >
                  {c["display_title"]}
                </option>
              </select>
              <fieldset>
                <legend>Selected episodes</legend>
                <input
                  :for={id <- hidden_selection(@draft, @detail, @candidates)}
                  type="hidden"
                  name="grouping[episodes][]"
                  value={id}
                />
                <p>
                  Selected: {length(@draft["episodes"] || [])}. Selections persist across pages; clear selections before changing action.
                </p>
                <label :for={m <- (@detail && @detail["members"]["items"]) || []} :if={!m["ended_at"]}>
                  <input
                    type="checkbox"
                    name="grouping[episodes][]"
                    value={m["episode"]["type"] <> ":" <> m["episode"]["id"]}
                    checked={
                      (m["episode"]["type"] <> ":" <> m["episode"]["id"]) in (@draft["episodes"] || [])
                    }
                  /> Current member: {m["incident"]["display_title"]}
                </label>
                <label :for={c <- @candidates["items"]}>
                  <input
                    type="checkbox"
                    name="grouping[episodes][]"
                    value={c["incident_type"] <> ":" <> c["id"]}
                    disabled={!is_nil(c["correlation"])}
                    checked={(c["incident_type"] <> ":" <> c["id"]) in (@draft["episodes"] || [])}
                  /> {c["display_title"]} · {c["health"]}
                </label>
              </fieldset>
              <.link
                :if={@candidates["page"] > 1}
                patch={path(@current_path, "candidates_page", @candidates["page"] - 1)}
              >Previous episodes</.link>
              <.link
                :if={@candidates["page"] * @candidates["page_size"] < @candidates["total"]}
                patch={path(@current_path, "candidates_page", @candidates["page"] + 1)}
              >More episodes</.link>
              <button class="pf-v6-c-button pf-m-secondary" type="submit">Review change</button>
            </div>
          </.form>
          <p :if={@error} role="alert">{@error}</p>
          <section :if={@review} id="correlation-review">
            <h3>Review grouping change</h3>
            <ul>
              <li :for={c <- @review["cases"]}>
                {c["title"]}: {c["id"]} · revision {c["revision"]} · {c["member_count"]} current members
              </li>
            </ul>
            <ul>
              <li :for={r <- @review["proposal"]["episodes"]}>{r["type"]}: {r["id"]}</li>
            </ul>
            <p :if={@review["proposal"]["other_case_id"]}>
              Merge source case: {@review["proposal"]["other_case_id"]}
            </p>
            <p :if={@review["proposal"]["anchor"]}>Parent: {@review["proposal"]["anchor"]["id"]}</p>
            <p>
              {@review["proposal"]["action"]}: {@review["proposal"]["title"]} · {length(
                @review["proposal"]["episodes"]
              )} selected episodes
            </p>
            <p>{@review["proposal"]["reason"]}</p>
            <p>
              Case acknowledgement ends. Pending reservations are released; already admitted I/O may finish. Native controls stay unchanged.
            </p>
            <button type="button" phx-click="apply" class="pf-v6-c-button pf-m-primary">Save reviewed change</button>
          </section>
        </PreviewDetail.card>
      </section>
    </MondekWeb.PreviewLayouts.app>
    """
  end
end

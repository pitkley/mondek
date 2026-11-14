# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnerDetail do
  @moduledoc "Canonical runner evidence shared by investigation panels and direct pages."
  use MondekWeb, :html
  alias MondekWeb.{AgentPrompts, PreviewDetail}
  alias Phoenix.LiveView.JS
  import MondekWeb.EvidencePresentation, only: [age: 2, time: 1]

  attr :runner, :any, required: true
  attr :now, :any, required: true
  attr :full_page, :boolean, default: false
  attr :id_prefix, :string, default: ""
  attr :heading_id, :string, default: "overview-panel-title"
  attr :current, :string, default: "/runners"
  attr :controller_url, :string, default: ""

  def body(assigns) do
    runner = assigns.runner || %{}
    status = runner["status"] || %{}

    assigns =
      assign(assigns,
        status: status,
        scheduler: status["scheduler"] || %{},
        coverage: runner["coverage"] || %{},
        context: %{
          "controller_url" => assigns.controller_url,
          "page_path" => "/runners/" <> (runner["id"] || ""),
          "runner_id" => runner["id"],
          "runner_name" => runner["label"]
        }
      )

    ~H"""
    <div class="runner-detail" id={@id_prefix <> "runner-detail"}>
      <header class="preview-incident-intro">
        <p class="preview-caption">Observing runner</p>
        <PreviewDetail.heading level={if @full_page, do: 1, else: 2} id={@heading_id}>
          {if @runner, do: @runner["label"] || "Unnamed runner", else: "Runner not found"}
        </PreviewDetail.heading>
        <p :if={@runner} class="preview-caption">{execution_context(@runner)}</p>
      </header>
      <p :if={!@runner} class="preview-empty">This installation identity is not registered.</p>
      <%= if @runner do %>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "runner-measurements"}
          title="Measurement coverage"
        >
          <PreviewDetail.facts label="Runner measurement coverage">
            <tr>
              <th scope="row">Collection</th><td>
                <.collection_badge value={@runner["collection_status"]} />
                <span>{@coverage["fresh"]} of {@coverage["active"]} active results fresh</span>
              </td>
            </tr>
            <tr :if={@coverage["active"] == 0}>
              <th scope="row">Expected results</th><td>
                No active published results are expected from this runner. Review source declarations and placement in Coverage.
              </td>
            </tr>
            <tr
              :for={
                {key, title, filter} <- [
                  {"unavailable", "Unavailable", "unavailable"},
                  {"stale", "Stale", "stale"},
                  {"awaiting", "Awaiting measurement", "awaiting"}
                ]
              }
              :if={(@coverage[key] || 0) > 0}
            >
              <th scope="row">{title}</th><td>
                <.link navigate={checks_path(@runner["id"], @current, filter)}>{@coverage[key]} {title}</.link>
              </td>
            </tr>
            <tr>
              <th scope="row">Results</th><td>
                <.link navigate={checks_path(@runner["id"], @current)}>Inspect all results</.link>
                ·
                <.link navigate={"/configuration?" <> URI.encode_query(%{"runner_id" => @runner["id"]})}>{@runner[
                  "check_count"
                ]} scheduled {plural(@runner["check_count"], "check")}</.link>
              </td>
            </tr>
            <tr>
              <th scope="row">Monitoring gaps</th><td>
                <.link navigate={"/coverage?" <> URI.encode_query(%{"runner_id" => @runner["id"], "return_to" => @current})}>Declared coverage</.link>
                ·
                <.link navigate={"/incidents?" <> URI.encode_query(%{"type" => "loss", "runner_id" => @runner["id"], "return_to" => @current})}>Monitoring loss incidents</.link>
              </td>
            </tr>
          </PreviewDetail.facts>
          <p class="runner-section-note">
            Fresh Warning or Critical measurements still confirm collection. Target health and runner contact are separate.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "runner-contact"}
          title="Controller connection"
        >
          <PreviewDetail.facts label="Runner controller connection">
            <tr>
              <th scope="row">Contact</th><td>
                <.contact_badge value={@runner["contact_status"]} />
              </td>
            </tr>
            <tr>
              <th scope="row">Last contact</th><td>
                <.timestamp value={@runner["last_seen_at"]} now={@now} />
              </td>
            </tr>
            <tr>
              <th scope="row">Recent for</th><td>
                {@runner["contact_seconds"]} seconds · communication, not a successful measurement
              </td>
            </tr>
          </PreviewDetail.facts>
          <p :if={@runner["contact_status"] != "recent"} class="runner-section-note">
            Inspect the runner process and server connection from its host. Checks may still execute and buffer evidence while disconnected.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "runner-last-report"}
          title="Last reported execution & upload"
        >
          <p class="runner-section-note">
            These values may predate the latest contact and stay fixed until another status report. They do not identify a specific blocked check.
          </p>
          <PreviewDetail.facts label="Last reported runner scheduling and upload">
            <tr :for={
              {key, label} <- [
                {"active_checks", "Active checks on runner"},
                {"running_checks", "Running checks"},
                {"max_concurrency", "Maximum concurrent checks"},
                {"due_waiting_checks", "Due, waiting for a slot"},
                {"preparation_pending_checks", "Waiting for preparation"},
                {"prepared_waiting_checks", "Prepared, awaiting activation"}
              ]
            }>
              <th scope="row">{label}</th><td>{reported(@scheduler[key])}</td>
            </tr>
            <tr>
              <th scope="row">Oldest due wait</th><td>{seconds(@scheduler["oldest_due_seconds"])}</td>
            </tr>
            <tr>
              <th scope="row">Buffered reports</th><td>{reported(@status["queue_count"])}</td>
            </tr>
            <tr>
              <th scope="row">Spool usage</th><td>{bytes(@status["queue_bytes"])}</td>
            </tr>
            <tr>
              <th scope="row">Oldest buffered report</th><td>
                <.timestamp :if={@status["oldest_at"]} value={@status["oldest_at"]} now={@now} /><span :if={
                  !@status["oldest_at"]
                }>{if @status["queue_count"] == 0, do: "No buffered reports", else: "Not reported"}</span>
              </td>
            </tr>
            <tr>
              <th scope="row">Reports dropped since journal creation</th><td>
                {reported(@status["dropped"])}
              </td>
            </tr>
          </PreviewDetail.facts>
          <p :if={positive?(@scheduler["due_waiting_checks"])} class="runner-section-note">
            Executions were waiting for capacity. Inspect slow checks and the concurrency limit before changing schedules.
          </p>
          <p :if={positive?(@status["queue_count"])} class="runner-section-note">
            A brief queue can be normal. If it persists, inspect reachability and upload responses from the runner.
          </p>
          <p :if={positive?(@status["dropped"])} class="runner-section-note">
            This cumulative count records past evidence loss. It does not by itself show a current outage.
          </p>
          <details
            :if={@status["diagnostic"] not in [nil, "", %{}, []]}
            id={@id_prefix <> "runner-diagnostic"}
            phx-mounted={JS.ignore_attributes("open")}
            class="runner-disclosure"
          >
            <summary>Last recorded diagnostic</summary>
            <div>
              <p class="runner-section-note">
                This message may describe an earlier problem and survive recovery. Use measurement coverage and contact to assess the current state.
              </p><pre>{diagnostic(@status["diagnostic"])}</pre>
            </div>
          </details>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "runner-publications"}
          title="Published sources & placement"
        >
          <p class="runner-section-note">
            Execution context describes where this runner operates. Monitored environments belong to each result and can differ.
          </p>
          <p :if={(@runner["publications"] || []) == []} class="preview-empty">
            No source inventory has been published. <.link navigate="/guide">Review runner setup</.link>.
          </p>
          <table
            :if={(@runner["publications"] || []) != []}
            class="pf-v6-c-table pf-m-compact preview-table runner-publication-table"
            aria-label="Runner published sources"
          >
            <thead class="pf-v6-c-table__thead">
              <tr>
                <th class="pf-v6-c-table__th" scope="col">Source</th><th
                  class="pf-v6-c-table__th"
                  scope="col"
                >
                  State
                </th><th class="pf-v6-c-table__th" scope="col">
                  Execution context
                </th><th class="pf-v6-c-table__th" scope="col">Revision</th><th
                  class="pf-v6-c-table__th"
                  scope="col"
                >
                  Received
                </th>
              </tr>
            </thead>
            <tbody class="pf-v6-c-table__tbody">
              <tr :for={publication <- @runner["publications"] || []}>
                <td class="pf-v6-c-table__td" data-label="Source">
                  <.link navigate={"/coverage/publishers/" <> to_string(publication["id"])}>{publication[
                    "source_id"
                  ]}</.link><div class="preview-caption">
                    <.link navigate={"/coverage?" <> URI.encode_query(%{"source_id" => publication["source_id"], "runner_id" => @runner["id"], "return_to" => @current})}>Inspect declarations and placement</.link>
                  </div>
                </td>
                <td class="pf-v6-c-table__td" data-label="State">
                  {publication_state(publication)}
                </td>
                <td class="pf-v6-c-table__td" data-label="Execution context">
                  {publication_context(publication)}
                </td><td class="pf-v6-c-table__td" data-label="Revision">
                  {publication["revision"] || "Not recorded"}
                </td><td class="pf-v6-c-table__td" data-label="Received">
                  <.timestamp value={publication["received_at"]} now={@now} />
                </td>
              </tr>
            </tbody>
          </table>
          <p
            :if={(@runner["publication_count"] || 0) > length(@runner["publications"] || [])}
            class="runner-section-note"
          >
            Showing {length(@runner["publications"])} of {@runner["publication_count"]} retained source publications.
            <.link navigate={"/coverage/publishers?" <> URI.encode_query(%{"runner_id" => @runner["id"], "lifecycle" => "all"})}>Browse publications</.link>
            for the rest.
          </p>
        </PreviewDetail.card>
        <PreviewDetail.card
          level={if @full_page, do: 2, else: 3}
          id={@id_prefix <> "runner-identity"}
          title="Installation & session"
        >
          <PreviewDetail.facts label="Runner identity">
            <tr>
              <th scope="row">Installation ID</th><td>{@runner["id"]}</td>
            </tr>
            <tr>
              <th scope="row">Current session</th><td>{@runner["session_id"] || "Not recorded"}</td>
            </tr>
            <tr>
              <th scope="row">Boot sequence</th><td>{@runner["boot"] || "Not recorded"}</td>
            </tr>
            <tr>
              <th scope="row">Retired checks</th><td>{@runner["retired_check_count"] || 0}</td>
            </tr>
          </PreviewDetail.facts>
          <details
            class="runner-disclosure"
            id={@id_prefix <> "runner-provenance"}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Reported status data</summary><div>
              <pre>{Jason.encode!(@status, pretty: true)}</pre><p class="runner-section-note">
                The installation identity survives restarts when its state directory is retained. A new session does not make buffered evidence new.
              </p>
            </div>
          </details>
        </PreviewDetail.card>
        <div class="runner-agent-help">
          <AgentPrompts.library
            id={@id_prefix <> "runner-agent-prompts"}
            kinds={[:collection, :deployment]}
            context={@context}
          />
        </div>
      <% end %>
    </div>
    """
  end

  attr :value, :any, required: true

  def contact_badge(assigns) do
    ~H"""
    <span class={["pf-v6-c-label", if(@value == "recent", do: "pf-m-green", else: "pf-m-orange")]}><span class="pf-v6-c-label__content">{contact_label(
      @value
    )}</span></span>
    """
  end

  attr :value, :any, required: true

  def collection_badge(assigns) do
    ~H"""
    <span class={[
      "pf-v6-c-label",
      if(@value == "fresh",
        do: "pf-m-green",
        else: if(@value == "issues", do: "pf-m-orange", else: "")
      )
    ]}><span class="pf-v6-c-label__content">{collection_label(@value)}</span></span>
    """
  end

  attr :value, :any, required: true
  attr :now, :any, required: true

  def timestamp(assigns) do
    ~H"""
    <time :if={@value} datetime={@value} title={time(@value)}>{time(@value)}
    <span class="preview-caption">({age(@value, @now)})</span></time><span :if={!@value}>Not recorded</span>
    """
  end

  def contact_label("recent"), do: "Recent contact"
  def contact_label("overdue"), do: "Contact overdue"
  def contact_label(_), do: "Never contacted"
  def collection_label("fresh"), do: "All results fresh"
  def collection_label("issues"), do: "Measurement gaps"
  def collection_label(_), do: "No active results"

  defp publication_state(%{"retired_at" => value}) when not is_nil(value), do: "Retired"

  defp publication_state(%{"resume_after_revision" => value}) when not is_nil(value),
    do: "Awaiting inventory"

  defp publication_state(_), do: "Active"

  def publication_context(publication) do
    context = publication["runner_context"] || %{}
    label = context["label"] || context["id"] || "Context not declared"
    environment = context["local_environment"]
    label <> if(is_binary(environment) && environment != "", do: " · " <> environment, else: "")
  end

  def execution_context(runner) do
    contexts =
      runner["publications"]
      |> List.wrap()
      |> Enum.reject(& &1["retired_at"])
      |> Enum.map(&publication_context/1)
      |> Enum.uniq()

    if contexts == [],
      do: "Execution context not declared",
      else:
        Enum.join(Enum.take(contexts, 2), " · ") <>
          if(length(contexts) > 2, do: " · +#{length(contexts) - 2} contexts", else: "")
  end

  def source_summary(runner) do
    case runner["publications"] |> List.wrap() |> Enum.reject(& &1["retired_at"]) do
      [] ->
        "No active source publication"

      [publication] ->
        publication["source_id"]

      publications ->
        "#{runner["active_publication_count"] || length(publications)} sources"
    end
  end

  defp checks_path(id, return_to, freshness \\ nil),
    do:
      "/checks?" <>
        URI.encode_query(
          Map.reject(
            %{"runner_id" => id, "return_to" => return_to, "freshness" => freshness},
            fn {_, value} -> is_nil(value) end
          )
        )

  defp reported(value) when is_number(value) and value >= 0, do: value
  defp reported(_), do: "Not reported"
  defp positive?(value), do: is_number(value) && value > 0

  defp seconds(value) when is_number(value) and value >= 0,
    do: "#{Float.round(value * 1.0, 1)} seconds"

  defp seconds(_), do: "Not reported"

  defp bytes(value) when is_number(value) and value >= 0,
    do: "#{Float.round(value / 1024, 1)} KiB"

  defp bytes(_), do: "Not reported"
  defp diagnostic(value) when is_binary(value), do: value
  defp diagnostic(value), do: Jason.encode!(value, pretty: true)
  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end

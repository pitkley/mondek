# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CollectionDiagnostics do
  @moduledoc "Shared current execution, configuration and runner evidence; never a combined target-health verdict."
  use MondekWeb, :html

  alias MondekWeb.{
    AgentPrompts,
    CheckDetails,
    CheckDiagnostics,
    EvidencePresentation,
    PreviewDetail,
    RunnerDetail
  }

  alias Phoenix.LiveView.JS

  attr :inspection, :map, required: true
  attr :runner, :any, default: nil
  attr :now, :any, required: true
  attr :id_prefix, :string, default: ""
  attr :runner_path, :any, required: true
  attr :configuration_path, :string, required: true
  attr :configuration_patch, :boolean, default: false
  attr :current, :string, required: true

  attr :full_page, :boolean, default: false

  def body(assigns) do
    assignment = assigns.inspection["assignment"] || %{}
    result = assigns.inspection["stream"] || assignment
    runner = assigns.runner || %{}

    {kind, title, explanation, next_step} =
      CheckDiagnostics.finding(result, assignment, runner, assigns.now)

    status = runner["status"] || %{}

    assigns =
      assign(assigns,
        assignment: assignment,
        result: result,
        current_evidence: result["current"] || %{},
        runner: runner,
        status: status,
        scheduler: status["scheduler"] || %{},
        kind: kind,
        title: title,
        explanation: explanation,
        next_step: next_step
      )

    ~H"""
    <PreviewDetail.card
      level={if @full_page, do: 2, else: 3}
      id={@id_prefix <> "collection-diagnostics"}
      title="Collection diagnostics"
    >
      <PreviewDetail.facts label="Collection assessment">
        <tr>
          <th scope="row">Finding</th><td>
            <strong>{@title}</strong><div class="preview-caption">{@explanation}</div>
          </td>
        </tr>
        <tr>
          <th scope="row">Next step</th><td>{@next_step}</td>
        </tr>
      </PreviewDetail.facts>
      <div class="preview-recorded-actions">
        <.link :if={@kind == :contact && @runner["id"]} patch={@runner_path.(@runner["id"])}>Inspect runner connection</.link>
        <.link
          :if={@kind == :configuration}
          navigate={if !@configuration_patch, do: @configuration_path}
          patch={if @configuration_patch, do: @configuration_path}
        >Review pending configuration</.link>
        <.link :if={@kind == :unassigned} navigate="/guide">Set up a runner</.link>
      </div>
      <.dynamic_tag tag_name={if @full_page, do: "h3", else: "h4"} class="preview-section-heading">
        Latest execution evidence
      </.dynamic_tag>
      <PreviewDetail.facts label="Latest execution evidence">
        <tr>
          <th scope="row">Reported configuration version</th><td>
            {value(@current_evidence["generation"])}
          </td>
        </tr>
        <tr>
          <th scope="row">Collection</th><td>
            {value(@current_evidence["execution_summary"] || @current_evidence["diagnostic"])}
          </td>
        </tr>
        <tr :if={
          @current_evidence["diagnostic"] &&
            @current_evidence["diagnostic"] != @current_evidence["execution_summary"]
        }>
          <th scope="row">Diagnostic</th><td>{@current_evidence["diagnostic"]}</td>
        </tr>
        <tr :if={@current_evidence["execution_details"] not in [nil, ""]}>
          <th scope="row">Collection details</th><td>
            <CheckDetails.check_details text={@current_evidence["execution_details"]} />
          </td>
        </tr>
        <tr>
          <th scope="row">Source time</th><td>
            {EvidencePresentation.time(@current_evidence["reported_source_at"])}
          </td>
        </tr>
        <tr>
          <th scope="row">Evaluated</th><td>
            {EvidencePresentation.time(@current_evidence["evaluated_at"])}
          </td>
        </tr>
        <tr>
          <th scope="row">Received</th><td>
            {EvidencePresentation.time(@current_evidence["received_at"])}
          </td>
        </tr>
      </PreviewDetail.facts>
      <p class="collection-note">
        Execution evidence can be newer than retained health. Retry and receipt do not change its original source time.
      </p>
      <.dynamic_tag tag_name={if @full_page, do: "h3", else: "h4"} class="preview-section-heading">
        Configuration and controller contact
      </.dynamic_tag>
      <PreviewDetail.facts label="Collection configuration and runner contact">
        <tr>
          <th scope="row">Desired version</th><td>{value(@assignment["desired_generation"])}</td>
        </tr>
        <tr>
          <th scope="row">Prepared / active</th><td>
            {value(@assignment["prepared_generation"])} / {value(@assignment["active_generation"])}
          </td>
        </tr>
        <tr>
          <th scope="row">Runner</th><td>
            <.link :if={@runner["id"]} patch={@runner_path.(@runner["id"])}>{@runner["label"] ||
              @runner["id"]}</.link><span :if={!@runner["id"]}>No runner recorded</span>
          </td>
        </tr>
        <tr :if={@runner["id"]}>
          <th scope="row">Controller contact</th><td>
            <RunnerDetail.contact_badge value={@runner["contact_status"]} />
            · {EvidencePresentation.time(@runner["last_seen_at"])}
          </td>
        </tr>
      </PreviewDetail.facts>
      <details
        id={@id_prefix <> "reported-runner-signals"}
        phx-mounted={JS.ignore_attributes("open")}
        class="collection-reported-signals"
      >
        <summary>Last reported runner signals</summary>
        <p class="collection-note">
          These values cover the runner, may predate its latest contact, and stay unchanged between reports. Historical drops alone do not establish a current outage.
        </p>
        <PreviewDetail.facts label="Last reported runner signals">
          <tr>
            <th scope="row">Running executions</th><td>{value(@scheduler["running_checks"])}</td>
          </tr>
          <tr>
            <th scope="row">Waiting for a slot</th><td>{value(@scheduler["due_waiting_checks"])}</td>
          </tr>
          <tr>
            <th scope="row">Reports awaiting upload</th><td>{value(@status["queue_count"])}</td>
          </tr>
          <tr>
            <th scope="row">Historical dropped reports</th><td>{value(@status["dropped"])}</td>
          </tr>
          <tr :if={@status["diagnostic"]}>
            <th scope="row">Recorded diagnostic</th><td>{@status["diagnostic"]}</td>
          </tr>
        </PreviewDetail.facts>
      </details>
    </PreviewDetail.card>
    <AgentPrompts.prompt
      id={@id_prefix <> "collection-agent-prompt"}
      kind={:collection}
      context={
        %{
          "page_path" => @current,
          "check_id" => @assignment["id"],
          "check_name" => @result["label"] || @assignment["label"],
          "runner_id" => @runner["id"],
          "runner_name" => @runner["label"],
          "source_id" => @assignment["source_id"],
          "monitored_environment" => @result["environment"],
          "freshness" => @current_evidence["knowledge"]
        }
      }
    />
    """
  end

  defp value(value) when value in [nil, ""], do: "Not reported"
  defp value(value), do: value
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Contract do
  @moduledoc "Operation declarations shared by controller callbacks and contract tooling."
  alias OpenApiSpex.{Operation, Parameter, RequestBody, Response, MediaType, Schema}
  alias MondekWeb.API.Schemas, as: S

  def operation(action) do
    route =
      Enum.find(
        MondekWeb.Router.__routes__(),
        &(&1.plug_opts == action and String.starts_with?(&1.path, "/api/v1/"))
      )

    # The process probe is deliberately outside the JSON API contract.
    if route do
      params =
        for segment <- String.split(route.path, "/"),
            String.starts_with?(segment, ":"),
            do: path_parameter(String.trim_leading(segment, ":"), action)

      query =
        Enum.map(query_fields(action), fn name ->
          %Parameter{
            name: String.to_atom(name),
            in: :query,
            schema: query_schema(name, action),
            description: query_description(name)
          }
        end)

      %Operation{
        operationId: operation_id(action),
        summary: summary(action),
        description: description(action),
        tags: [route.plug |> Module.split() |> List.last() |> String.replace("Controller", "")],
        parameters: params ++ query,
        requestBody:
          if(route.verb in [:post, :put, :patch],
            do: %RequestBody{
              required: true,
              description:
                "Operation input. Reviewed and runner semantics are enforced by the domain context.",
              content: %{"application/json" => %MediaType{schema: request_schema(action)}}
            }
          ),
        responses:
          Map.new([200, 400, 404, 406, 409, 413, 415, 422, 500, 503], fn code ->
            {code,
             %Response{
               description:
                 if(code == 200, do: "Success", else: Plug.Conn.Status.reason_phrase(code)),
               content: %{
                 "application/json" => %MediaType{
                   schema: if(code == 200, do: S.response(action), else: S.ref("Error"))
                 }
               }
             }}
          end)
      }
    end
  end

  def operation_id(action),
    do:
      Map.get(
        %{
          checks: "listResults",
          check: "getResult",
          evidence: "listResultEvidence",
          observation: "getResultObservation",
          configuration: "listAssignments",
          assignment_configurations: "listAssignmentConfigurations",
          assignment: "getAssignment",
          assignment_inspection: "getAssignmentConfiguration",
          incidents: "listHealthIncidents",
          incident: "getHealthIncident",
          monitoring_incidents: "listMonitoringLossIncidents",
          monitoring_incident: "getMonitoringLossIncident",
          inventory: "publishRunnerInventory",
          schema_migration_preview: "previewSchemaMigration",
          control: "exchangeRunnerControl",
          observations: "submitRunnerObservations",
          runner_state: "exchangeRunnerState",
          consumer_state: "listConsumerState",
          consumer_state_entry: "getConsumerState"
        },
        action,
        Atom.to_string(action)
      )

  defp summary(action),
    do: action |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp description(:observations),
    do:
      "Accepted envelopes contain 1–32 report objects. Report validation is independent: invalid reports receive rejected dispositions beside valid reports. Invalid report IDs are null; receipt order follows input order. CanonicalReport documents producer output, not a whole-batch validation gate. Exact replay retains identity and original age."

  defp description(:control),
    do:
      "Durable session/configuration exchange. Waits at most 10 seconds outside any database transaction. Authoritative membership, preparation and activation are distinct. Response budget is 4 MiB."

  defp description(:inventory),
    do:
      "Complete source-owned inventory. Admission is atomic; stale, conflicting and fenced publications cannot remove accepted membership. Request budget is 4 MiB."

  defp description(:schema_migration_preview),
    do:
      "Read-only comparison of a complete candidate inventory against an accepted source installation. Pages share a review digest for the same revisions. Request budget is 4 MiB."

  defp description(:monitoring_incident),
    do:
      "Open membership is live and paged; closed membership is a retained snapshot of at most 100 members with affected_total and truncated. No further page recovers omitted historical members."

  defp description(:observation),
    do:
      "Exact selected-output projection scoped to this result incarnation. A 404 means unavailable, pruned or out of scope, never proof that execution did not happen."

  defp description(action) when action in [:checks, :configuration],
    do:
      "Active membership by default. Pages are independent live reads, not a snapshot export. Retained health, freshness and latest execution are independent facts."

  defp description(_),
    do:
      "Experimental same-release contract. Review tokens and revisions retain their domain scope; source and definition revisions are not Git revisions."

  defp path_parameter(name, action) do
    schema =
      if name in ~w(observation_id) or
           (name == "id" and
              action in [
                :consumer_state_entry,
                :correlation_case,
                :check,
                :result_inspection,
                :evidence,
                :observation,
                :incident,
                :monitoring_incident,
                :runner,
                :notification,
                :retry_notification
              ]),
         do: S.uuid(),
         else: %Schema{
           type: :string,
           minLength: 1,
           maxLength: 240,
           pattern: "^[^\x00-\x1F\x7F]+$"
         }

    %Parameter{
      name: String.to_atom(name),
      in: :path,
      required: true,
      schema: schema,
      description: "Opaque #{name}; preserve the exact supplied identity."
    }
  end

  def query_fields(action) do
    case action do
      :consumer_state ->
        ~w(source_id scope key page)

      :correlation_candidates ->
        ~w(page source_id runner_id environment search)

      :correlation_cases ->
        ~w(page status)

      :correlation_case ->
        ~w(page history_page batch_page)

      :result_inspection ->
        []

      :checks ->
        ~w(page source_id runner_id environment search attention membership status health freshness target_scope unacknowledged page_size)

      a when a in [:configuration, :assignment_configurations] ->
        ~w(page source_id runner_id environment search membership status configuration_stage page_size)

      :assignment ->
        ~w(page)

      :check ->
        []

      :evidence ->
        ~w(page)

      :observation ->
        []

      :incidents ->
        ~w(page status source_id runner_id environment search acknowledgement health grouping opened_since page_size)

      :incident ->
        ~w(page state contradiction_page notification_page notification_status)

      :monitoring_incidents ->
        ~w(page status source_id runner_id search acknowledgement opened_since)

      :monitoring_incident ->
        ~w(page members_page)

      :runners ->
        ~w(page page_size search source_id contact collection sort)

      :notifications ->
        ~w(page notification_status notification_event notification_channel notification_type search)

      :policy_export ->
        ~w(project)

      :policy_values ->
        ~w(source_id page)

      :maintenance_seed ->
        ~w(stream_id)

      :maintenance_windows ->
        ~w(page status kind search assignment_id source_id environment target_kind target_key)

      :maintenance_series ->
        ~w(occurrence_page result_page history_page page)

      :coverage ->
        ~w(page search source_id runner_id environment target_kind target_key status lifecycle)

      :coverage_publishers ->
        ~w(page source_id runner_id environment target_kind target_key search status lifecycle)

      :coverage_diagnostics ->
        ~w(page source_id runner_id environment target_kind target_key search status lifecycle)

      :coverage_observers ->
        ~w(page source_id runner_id environment target_kind target_key search status lifecycle)

      :publisher_successors ->
        ~w(page search)

      action when action in [:publisher, :publisher_event, :rules, :schema_migration_preview] ->
        ~w(page)

      _ ->
        []
    end
  end

  defp query_schema(name, action) do
    cond do
      name in ~w(page batch_page history_page occurrence_page result_page members_page contradiction_page notification_page evidence_page) ->
        %Schema{type: :integer, minimum: 1, maximum: 1_000_000}

      name == "page_size" ->
        %Schema{type: :integer, minimum: 1, maximum: 100}

      name in ~w(attention unacknowledged) ->
        S.boolean()

      name == "runner_id" ->
        S.uuid()

      name == "state" ->
        S.enum(~w(open history all uncovered))

      name == "contact" ->
        S.enum(~w(all recent overdue never))

      name == "collection" ->
        S.enum(~w(all empty fresh issues))

      name == "sort" ->
        S.enum(~w(attention name last_contact))

      name == "notification_status" ->
        S.enum(~w(unresolved exhausted pending retrying delivering delivered superseded all))

      name == "notification_event" ->
        S.enum(~w(firing update resolved))

      name == "notification_channel" ->
        S.enum(~w(email webhook))

      name == "notification_type" ->
        S.enum(~w(health loss))

      name == "membership" ->
        S.enum(~w(active retired all))

      name == "acknowledgement" ->
        S.enum(~w(all acknowledged unacknowledged))

      name == "status" and action in [:incidents, :monitoring_incidents] ->
        S.enum(~w(open closed all))

      name == "health" ->
        S.enum(~w(OK WARN CRIT UNKNOWN not_measured))

      name == "opened_since" ->
        %Schema{type: :string, format: :"date-time"}

      true ->
        %Schema{type: :string, minLength: 1, maxLength: 240}
    end
  end

  defp query_description("page"),
    do: "Positive live page number. Investigation pages beyond the end are empty."

  defp query_description(name), do: "Filter: #{name}."

  def request_schema(action)
      when action in [
             :correlation_preview,
             :correlation_apply,
             :case_control_preview,
             :case_control_apply
           ],
      do: MondekWeb.API.CorrelationSchemas.request(action)

  def request_schema(action) do
    case action do
      :runner_state ->
        S.ref("ConsumerStateRequest")

      :control ->
        S.ref("ControlRequest")

      a when a in [:inventory, :schema_migration_preview] ->
        S.ref("InventoryRequest")

      :observations ->
        S.ref("ObservationEnvelope")

      :maintenance_project_plan ->
        S.record(%{manifest: S.ref("MaintenanceProjectManifest"), base_revision: S.string()}, [
          :manifest
        ])

      :maintenance_project_apply ->
        S.record(%{manifest: S.ref("MaintenanceProjectManifest"), review_token: S.string()}, [
          :manifest,
          :review_token
        ])

      :save ->
        S.record(%{revision: S.integer(), params: S.object()}, [:revision, :params])

      :acknowledge ->
        S.record(%{
          mode: S.enum(~w(end duration until until_incident_ends)),
          revision: S.integer(),
          attention_revision: S.integer(),
          seconds: S.number(),
          expires_at: S.string(),
          note: S.string()
        })

      :retry_notification ->
        S.record(%{reason: S.string()}, [:reason])

      _ ->
        workflow_request(action)
    end
  end

  defp workflow_request(action) do
    keys =
      case action do
        :policy_plan -> ~w(manifest base_head)
        :policy_apply -> ~w(manifest review_token)
        :bulk_select -> ~w(filters)
        :bulk_prepare -> ~w(selection page)
        :bulk_preview -> ~w(prepare_token params page)
        :bulk_apply -> ~w(review_token params)
        :bulk_status -> ~w(receipts page)
        :exception_preview -> ~w(revision)
        :exception_reset -> ~w(review_token)
        :maintenance_cancel -> ~w(revision reason)
        :maintenance_series_cancel_preview -> ~w(revision reason page review_token)
        :maintenance_series_cancel -> ~w(review_token reason)
        _ -> ~w(proposal review_token page occurrence_page result_page)
      end

    props =
      Map.new(keys, fn key ->
        schema =
          cond do
            key in ~w(review_token prepare_token reason base_head) ->
              S.nullable(S.string())

            key in ~w(page batch_page history_page occurrence_page result_page revision) ->
              S.integer()

            key in ~w(selection receipts) ->
              S.array(S.object())

            key == "manifest" ->
              S.ref("PolicyManifest")

            key == "params" ->
              S.ref("ParameterValues")

            key == "proposal" and action in [:rule_preview, :rule_apply] ->
              S.ref("RuleProposal")

            key == "proposal" and action in [:publisher_preview, :publisher_apply] ->
              S.ref("PublisherProposal")

            key == "proposal" and action in [:maintenance_preview, :maintenance_apply] ->
              S.ref("MaintenanceProposal")

            true ->
              S.object()
          end

        {String.to_atom(key), schema}
      end)

    S.record(props)
  end
end

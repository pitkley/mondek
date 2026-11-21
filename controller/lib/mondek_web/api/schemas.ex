# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Schemas do
  @moduledoc "Explicit HTTP schemas. Dynamic consumer metadata and reviewed proposals remain JSON objects."
  alias OpenApiSpex.Schema
  def string, do: %Schema{type: :string}
  def nullable(%OpenApiSpex.Reference{} = schema), do: %Schema{allOf: [schema], nullable: true}
  def nullable(schema), do: %{schema | nullable: true}
  def uuid, do: %Schema{type: :string, format: :uuid}
  def integer, do: %Schema{type: :integer}
  def number, do: %Schema{type: :number}
  def boolean, do: %Schema{type: :boolean}
  def time, do: nullable(%Schema{type: :string, format: :"date-time"})
  def object, do: %Schema{type: :object, additionalProperties: true}
  def array(item), do: %Schema{type: :array, items: item}
  def enum(values), do: %Schema{type: :string, enum: values}
  def fields(names, schema), do: Map.new(String.split(names), &{String.to_atom(&1), schema})

  def record(properties, required \\ []),
    do: %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: false
    }

  def ref(name), do: %OpenApiSpex.Reference{"$ref": "#/components/schemas/#{name}"}

  defp incident_schema(summary?, types \\ ["individual", "condition"]) do
    schema =
      record(
        Map.merge(
          fields(
            "id assignment_id stream_id result_key condition_incident_id environment environment_label check_label result_label runner_label display_title label scope_kind source_id runner_id closure_reason acknowledgement_mode acknowledgement_note acknowledgement_scope kind ui_path incident_kind",
            nullable(string())
          ),
          Map.merge(
            fields("opened_at closed_at acknowledged_until acknowledged_at", time()),
            Map.merge(
              fields(
                "opening_observation_id latest_observation_id latest_failure_observation_id closing_observation_id",
                nullable(uuid())
              ),
              %{
                impacts: array(record(%{key: string(), label: string()}, [:key, :label])),
                health: nullable(enum(~w(OK WARN CRIT UNKNOWN))),
                status: enum(~w(open closed)),
                incident_type: enum(~w(individual condition)),
                member_count: nullable(integer()),
                open_contributions: integer(),
                contribution_count: integer(),
                open_contribution_count: integer(),
                result_count: integer(),
                observer_count: integer(),
                matching_result_count: integer(),
                scope_filtered: boolean(),
                opening_generation: nullable(integer()),
                attention_revision: integer(),
                acknowledgement_revision: integer(),
                acknowledgement_active: boolean(),
                target: nullable(ref("Target")),
                correlation: nullable(ref("CorrelationMembership"))
              }
            )
          )
        ),
        [:id, :status, :incident_type]
      )

    if summary? do
      %{
        schema
        | required:
            schema.required ++
              ~w(display_title check_label result_label environment_label runner_label acknowledgement_active)a,
          properties:
            Map.merge(schema.properties, %{
              display_title: string(),
              acknowledgement_active: boolean(),
              incident_type: enum(types)
            })
      }
    else
      schema
    end
  end

  def definitions do
    Map.merge(MondekWeb.API.WorkflowSchemas.definitions(), %{
      "Error" =>
        record(
          %{
            error:
              record(%{code: string(), message: string(), details: object()}, [:code, :message]),
            request_id: string()
          },
          [:error, :request_id]
        ),
      "Meta" => %Schema{
        type: :object,
        required: [:as_of],
        properties: %{
          as_of: time(),
          total: integer(),
          page: integer(),
          page_size: integer(),
          next_page: nullable(integer())
        },
        additionalProperties: true
      },
      "Target" =>
        record(%{kind: nullable(string()), key: nullable(string()), label: nullable(string())}),
      "CurrentResult" =>
        record(
          Map.merge(
            fields(
              "health knowledge summary diagnostic execution_summary reported_health",
              nullable(string())
            ),
            Map.merge(
              fields(
                "source_at confirmed_evaluated_at started_at evaluated_at received_at reported_source_at",
                time()
              ),
              Map.merge(
                fields(
                  "confirmed_observation_id confirmed_session_id observation_id session_id",
                  nullable(uuid())
                ),
                %{
                  generation: nullable(integer()),
                  confirmed_generation: nullable(integer()),
                  value: nullable(number()),
                  complete: nullable(boolean())
                }
              )
            )
          )
        ),
      "OutputQualification" =>
        record(
          %{
            duration_seconds: %Schema{type: :integer, minimum: 0, maximum: 86_400},
            effective_health: nullable(enum(~w(OK WARN CRIT))),
            effective_observation_id: nullable(uuid()),
            pending: %Schema{type: :array, maxItems: 2, items: ref("PendingOutputSeverity")}
          },
          ~w(duration_seconds effective_health effective_observation_id pending)a
        ),
      "PendingOutputSeverity" =>
        record(
          %{health: enum(~w(WARN CRIT)), first_observation_id: uuid(), started_at: time()},
          ~w(health first_observation_id started_at)a
        ),
      "Result" =>
        record(
          Map.merge(
            fields(
              "id assignment_id result_key label check_label runner_id runner_label source_id source_key source_revision definition_revision environment environment_label retirement_reason ui_path",
              nullable(string())
            ),
            %{
              retired: boolean(),
              params_owner: nullable(string()),
              desired_generation: nullable(integer()),
              authorized_generation: nullable(integer()),
              prepared_generation: nullable(integer()),
              active_generation: nullable(integer()),
              observed_generation: nullable(integer()),
              check_group: nullable(object()),
              condition: nullable(object()),
              target: ref("Target"),
              qualification: nullable(ref("OutputQualification")),
              predecessor_stream_id: nullable(uuid()),
              current: ref("CurrentResult")
            }
          ),
          [:id, :assignment_id, :current, :target]
        ),
      "ResultMeasurementHistoryRow" =>
        record(
          %{
            stream_id: uuid(),
            observation_id: uuid(),
            generation: integer(),
            disposition: enum(~w(current historical)),
            source_at: time(),
            evaluated_at: time(),
            received_at: time(),
            health: enum(~w(OK WARN CRIT UNKNOWN)),
            summary: string(),
            evidence_path: string()
          },
          ~w(stream_id observation_id generation disposition source_at evaluated_at received_at health summary evidence_path)a
        ),
      "Incident" => incident_schema(false),
      "IncidentSummary" => incident_schema(true),
      "IndividualIncidentSummary" => incident_schema(true, ["individual"]),
      "SharedIncidentSummary" => incident_schema(true, ["condition"]),
      "RecordedMeasurement" =>
        record(
          %{
            status: enum(~w(available unavailable)),
            basis: nullable(enum(~w(latest_failure opening_failure notification_reference))),
            measurement: nullable(ref("IncidentMeasurement")),
            gaps: %Schema{type: :array, maxItems: 3, items: ref("IncidentEvidenceGap")}
          },
          [:status, :basis, :measurement, :gaps]
        ),
      "IncidentEvidenceGap" =>
        record(
          %{
            role: enum(~w(latest_failure opening_failure notification_reference)),
            observation_id: nullable(uuid()),
            reason:
              enum(
                ~w(missing_reference observation_unavailable out_of_scope result_not_in_observation not_a_failure)
              )
          },
          [:role, :observation_id, :reason]
        ),
      "IncidentMeasurement" =>
        record(
          %{
            result_key: string(),
            health: enum(~w(WARN CRIT)),
            summary: string(),
            details: nullable(string()),
            value: nullable(number()),
            impacts: array(object()),
            source_at: time(),
            evaluated_at: time(),
            received_at: time(),
            observation_id: uuid(),
            provenance: ref("IncidentMeasurementProvenance")
          },
          [
            :result_key,
            :health,
            :summary,
            :details,
            :observation_id,
            :source_at,
            :evaluated_at,
            :received_at,
            :provenance
          ]
        ),
      "IncidentMeasurementProvenance" =>
        record(
          Map.merge(
            fields(
              "assignment_id stream_id installation_id session_id disposition source_revision definition_revision",
              nullable(string())
            ),
            %{generation: integer(), sequence: integer()}
          ),
          ~w(assignment_id stream_id installation_id session_id disposition source_revision definition_revision generation sequence)a
        ),
      "IncidentContribution" =>
        record(
          %{
            incident: ref("IncidentSummary"),
            stream: nullable(ref("Result")),
            assignment: nullable(ref("Assignment")),
            contribution_state: string(),
            last_failure_health: string(),
            recorded_measurement: ref("RecordedMeasurement"),
            evidence_ids: object(),
            coverage: object()
          },
          [:incident, :recorded_measurement]
        ),
      "Assignment" =>
        record(
          Map.merge(
            fields(
              "id label source_id source_key source_revision definition_revision runner_id runner_label environment environment_label params_owner parameter_contract retirement_reason configuration_stage parameter_schema_fingerprint",
              nullable(string())
            ),
            Map.merge(
              fields(
                "revision desired_generation prepared_generation authorized_generation active_generation observed_generation result_count",
                nullable(integer())
              ),
              Map.merge(fields("interval_seconds timeout_seconds freshness_seconds", number()), %{
                retired: boolean(),
                retired_at: time()
              })
            )
          ),
          [:id]
        ),
      "EvidenceResult" =>
        record(
          %{
            key: string(),
            health: enum(~w(OK WARN CRIT UNKNOWN)),
            summary: string(),
            details: nullable(string()),
            value: nullable(number()),
            source_at: time()
          },
          [:key, :health, :summary]
        ),
      "Evidence" =>
        record(
          Map.merge(
            fields("id assignment_id installation_id session_id disposition", string()),
            Map.merge(
              fields("generation sequence", integer()),
              Map.merge(fields("started_at evaluated_at received_at", time()), %{
                complete: boolean(),
                diagnostic: nullable(string()),
                result: nullable(ref_schema("EvidenceResult")),
                result_present: boolean(),
                configuration_retained: boolean(),
                configuration_provenance: nullable(ref_schema("ConfigurationProvenance"))
              })
            )
          ),
          [:id, :assignment_id, :result_present, :configuration_retained]
        ),
      "ObservationEnvelope" =>
        record(
          %{
            version: %Schema{type: :integer, enum: [1]},
            installation_id: uuid(),
            session_id: uuid(),
            reports: %Schema{type: :array, minItems: 1, maxItems: 32, items: object()}
          },
          [:version, :installation_id, :session_id, :reports]
        )
        |> Map.put(:additionalProperties, true),
      "ObservationReceipt" =>
        record(
          %{
            version: %Schema{type: :integer, enum: [1]},
            dispositions:
              array(
                record(
                  %{
                    id: nullable(uuid()),
                    disposition: enum(~w(current historical duplicate conflict rejected)),
                    original_disposition: enum(~w(current historical)),
                    reason: string(),
                    error: string()
                  },
                  [:id, :disposition]
                )
              )
          },
          [:version, :dispositions]
        ),
      "ControlRequest" => %Schema{
        type: :object,
        required: [:version, :installation_id, :session_id, :boot],
        properties: %{
          version: %Schema{type: :integer, enum: [1]},
          installation_id: uuid(),
          session_id: uuid(),
          boot: %Schema{type: :integer, minimum: 1},
          runner_label: nullable(string()),
          status: object(),
          prepared: %Schema{
            type: :object,
            additionalProperties: %Schema{type: :integer, minimum: 1, maximum: 2_147_483_647}
          },
          active: %Schema{
            type: :object,
            additionalProperties: %Schema{type: :integer, minimum: 1, maximum: 2_147_483_647}
          },
          wait_seconds: %Schema{type: :integer, minimum: 0, maximum: 10}
        },
        additionalProperties: true
      },
      "ControlReceipt" =>
        record(
          %{
            version: integer(),
            assignments_authoritative: boolean(),
            assignments: %Schema{type: :array, maxItems: 512, items: ref("RunnerAssignment")},
            authorized: %Schema{type: :object, additionalProperties: integer()},
            inventory_refresh: object()
          },
          [:version, :assignments_authoritative, :assignments, :authorized]
        ),
      "InventoryRequest" => %Schema{
        type: :object,
        required: [
          :version,
          :installation_id,
          :session_id,
          :boot,
          :source_id,
          :inventory_revision,
          :source_revision,
          :complete,
          :checks
        ],
        properties: %{
          version: %Schema{type: :integer, enum: [1]},
          installation_id: uuid(),
          session_id: uuid(),
          boot: integer(),
          source_id: string(),
          inventory_revision: integer(),
          source_revision: string(),
          complete: %Schema{type: :boolean, enum: [true]},
          checks: %Schema{type: :array, maxItems: 512, items: ref("InventoryCheck")},
          coverage: ref("CoverageCatalogue"),
          runner_label: nullable(string()),
          restoration_revision: integer()
        },
        additionalProperties: true
      },
      "InventoryReceipt" =>
        record(
          %{
            version: integer(),
            source_id: string(),
            inventory_revision: integer(),
            accepted_checks: integer()
          },
          [:version, :source_id, :inventory_revision, :accepted_checks]
        ),
      "CanonicalReport" => %Schema{
        type: :object,
        required: [
          :id,
          :assignment_id,
          :installation_id,
          :session_id,
          :generation,
          :sequence,
          :started_at,
          :evaluated_at,
          :complete,
          :results
        ],
        properties: %{
          id: uuid(),
          assignment_id: uuid(),
          installation_id: uuid(),
          session_id: uuid(),
          generation: %Schema{type: :integer, minimum: 1, maximum: 2_147_483_647},
          sequence: %Schema{type: :integer, minimum: 1, maximum: 9_223_372_036_854_775_806},
          started_at: %Schema{type: :string, format: :"date-time"},
          evaluated_at: %Schema{type: :string, format: :"date-time"},
          complete: boolean(),
          diagnostic: nullable(string()),
          results: %Schema{type: :array, maxItems: 16, items: ref("CanonicalResult")}
        },
        additionalProperties: true
      }
    })
    |> Map.merge(MondekWeb.API.RunnerSchemas.definitions())
    |> Map.merge(MondekWeb.API.ConsumerStateSchemas.definitions())
    |> Map.merge(MondekWeb.API.CorrelationSchemas.definitions())
  end

  # Inline nullable references are represented with allOf for OpenAPI 3.0 consumers.
  defp ref_schema(name), do: %Schema{allOf: [ref(name)]}

  def response(action) do
    data =
      case action do
        :consumer_state ->
          array(ref("ConsumerStateMetadata"))

        :consumer_state_entry ->
          ref("ConsumerStateEntry")

        :runner_state ->
          ref("ConsumerStateReceipt")

        a
        when a in [
               :correlation_candidates,
               :correlation_cases,
               :correlation_case,
               :correlation_preview,
               :case_control_preview,
               :case_control_apply,
               :correlation_apply
             ] ->
          MondekWeb.API.CorrelationSchemas.response(a)

        :checks ->
          array(ref("Result"))

        :check ->
          ref("Result")

        :evidence ->
          array(ref("Evidence"))

        :observation ->
          ref("Evidence")

        :configuration ->
          array(ref("Assignment"))

        :assignment ->
          record(
            %{
              check: ref("Assignment"),
              source_mapping: ref("SourceMapping"),
              results: object(),
              ui_path: string()
            },
            [:check, :results]
          )

        :incidents ->
          array(ref("IncidentSummary"))

        :observations ->
          ref("ObservationReceipt")

        :control ->
          ref("ControlReceipt")

        :inventory ->
          ref("InventoryReceipt")

        _ ->
          MondekWeb.API.WorkflowSchemas.response(action)
      end

    if action in reads(), do: record(%{data: data, meta: ref("Meta")}, [:data, :meta]), else: data
  end

  def reads,
    do:
      ~w(consumer_state consumer_state_entry correlation_candidates correlation_cases correlation_case snapshot overview coverage coverage_publishers coverage_diagnostics coverage_observers coverage_scope publisher publisher_successors publisher_event publisher_evidence maintenance_windows maintenance_seed maintenance_window maintenance_series rules configuration_revision policy_export policy_values rule_seed rule runners runner notifications notification assignment_configurations configuration assignment assignment_inspection checks check result_inspection evidence observation incidents incident monitoring_incidents monitoring_incident)a
end

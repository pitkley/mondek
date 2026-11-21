# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.WorkflowSchemas do
  @moduledoc "Named operator DTOs and reviewed command inputs; consumer values stay scalar JSON."
  alias OpenApiSpex.Schema
  alias MondekWeb.API.Schemas, as: S
  defp n(schema), do: S.nullable(schema)
  defp scalar, do: %Schema{anyOf: [S.string(), S.boolean(), S.number()]}
  defp json, do: S.ref("JSONValue")
  defp obj(keys), do: S.record(Map.new(String.split(keys), &{String.to_atom(&1), field(&1)}))

  defp incident_summary_schema(schema) do
    %{
      schema
      | required: [
          :display_title,
          :check_label,
          :result_label,
          :environment_label,
          :runner_label,
          :acknowledgement_active
        ],
        properties:
          Map.merge(schema.properties, %{
            display_title: S.string(),
            acknowledgement_active: S.boolean()
          })
    }
  end

  def definitions do
    %{
      "JSONValue" => %Schema{
        nullable: true,
        anyOf: [
          S.string(),
          S.number(),
          S.boolean(),
          %Schema{type: :object, additionalProperties: json()},
          S.array(json())
        ]
      },
      "ParameterValues" => %Schema{
        type: :object,
        maxProperties: 32,
        additionalProperties: scalar(),
        description:
          "Complete scalar values. Context enforces 16 KiB canonical JSON and exact numeric constraints."
      },
      "ParameterField" => %Schema{
        type: :object,
        required: [:type],
        properties: %{
          type: S.enum(~w(number integer string boolean)),
          label: S.string(),
          unit: S.string(),
          minimum: S.number(),
          maximum: S.number(),
          max_length: %Schema{type: :integer, minimum: 1, maximum: 2048},
          choices: %Schema{type: :array, minItems: 1, maxItems: 32, items: scalar()}
        },
        additionalProperties: true
      },
      "ParameterSchema" => %Schema{
        type: :object,
        required: [:fields],
        properties: %{
          fields: %Schema{
            type: :object,
            maxProperties: 32,
            additionalProperties: S.ref("ParameterField")
          },
          comparisons: %Schema{
            type: :array,
            maxItems: 32,
            items:
              S.record(%{left: S.string(), right: S.string(), op: S.enum(~w(lt lte))}, [
                :left,
                :right,
                :op
              ])
          }
        },
        additionalProperties: true
      },
      "SelectionEntry" =>
        S.record(
          %{
            id: S.string(),
            revision: %Schema{type: :integer, minimum: 1, maximum: 2_147_483_647}
          },
          [:id, :revision]
        ),
      "ConfigurationReceipt" =>
        S.record(
          %{
            id: S.string(),
            revision: S.integer(),
            target_generation: S.integer(),
            changed: S.boolean()
          },
          [:id, :revision, :target_generation, :changed]
        ),
      "ConfigurationRule" =>
        obj(
          "id revision name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params saved_at managed_project managed_key match_count conflict_count diagnostics"
        ),
      "RuleProposal" =>
        obj(
          "id revision name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params"
        ),
      "PolicyManifest" =>
        S.record(
          %{
            version: %Schema{type: :integer, enum: [1]},
            project: %Schema{type: :string, pattern: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$"},
            rules: %Schema{
              type: :array,
              maxItems: 64,
              items:
                obj(
                  "key name source_id parameter_contract environment target_kind target_key priority enabled params"
                )
            }
          },
          [:version, :project, :rules]
        ),
      "MaintenanceSelector" =>
        S.record(
          %{
            scope: S.enum(~w(check stable_check target)),
            assignment_id: n(S.string()),
            source_id: n(S.string()),
            source_key: S.string(),
            environment: n(S.string()),
            target_kind: n(S.string()),
            target_key: n(S.string())
          },
          [:scope]
        ),
      "MaintenanceProposal" =>
        obj(
          "id revision name reason scope assignment_id source_id environment target_kind target_key selections timezone start_mode starts_local ends_local start_fold end_fold"
        ),
      "MaintenanceWindow" =>
        obj(
          "id series_id series_index revision name reason scope assignment_id source_id environment target_kind target_key selections selection_count timezone starts_at ends_at starts_local ends_local start_fold end_fold tzdata_version actor inserted_at updated_at cancelled_at cancelled_by cancellation_reason status kind exception check_label runner_label matching_stream_ids"
        ),
      "MaintenanceSeries" =>
        obj(
          "id revision name reason scope assignment_id source_id environment target_kind target_key selections selection_count timezone starts_local ends_local start_fold end_fold tzdata_version actor inserted_at updated_at cancelled_at cancelled_by cancellation_reason status kind exception cadence weekdays duration_seconds starts_on ends_on local_time occurrence_count next_occurrence recurrence active_count upcoming_count ended_count cancelled_count remaining_count occurrence_total next_starts_at final_ends_at"
        )
        |> with_properties(%{
          generation_enabled: S.boolean(),
          generation_issue: n(S.string()),
          generation_stopped_at: S.time()
        }),
      "PlannedMaintenanceOccurrence" =>
        maintenance_occurrence(%{
          overlap_count: S.integer(),
          touches_previous: S.boolean()
        }),
      "SavedMaintenanceOccurrence" =>
        maintenance_occurrence(%{
          series_id: S.uuid(),
          series_index: S.integer(),
          revision: S.integer(),
          name: S.string(),
          reason: S.string(),
          actor: S.string(),
          kind: S.enum(["window"]),
          status: S.enum(~w(upcoming active ended cancelled)),
          exception: S.boolean(),
          timezone: S.string(),
          tzdata_version: n(S.string()),
          start_fold: S.string(),
          end_fold: S.string(),
          original_starts_local: S.string(),
          original_ends_local: S.string(),
          original_starts_at: S.time(),
          original_ends_at: S.time(),
          inserted_at: S.time(),
          updated_at: S.time(),
          cancelled_at: S.time(),
          cancelled_by: n(S.string()),
          cancellation_reason: n(S.string()),
          check_label: n(S.string()),
          runner_label: n(S.string()),
          selection_count: n(S.integer())
        }),
      "Publisher" =>
        obj(
          "id runner_id runner_label source_id revision source_revision received_at inventory_revision last_seen_at code_revision runtime_revision coverage_revision coverage_received_at coverage_confirmed coverage_context runner_context audit_status lifecycle_status lifecycle_revision retired_at retirement_reason replacement_id resume_after_revision declared_count selected_count excluded_count unresolved_count declaration_count selected_result_count capability_count check_count"
        ),
      "PublisherProposal" =>
        S.record(
          %{
            publisher_id: %Schema{type: :integer, minimum: 1},
            action: S.enum(~w(retire replace restore)),
            reason: %Schema{type: :string, minLength: 1, maxLength: 500},
            successor_id: n(S.integer())
          },
          [:publisher_id, :action, :reason]
        ),
      "Runner" =>
        Map.update!(
          obj(
            "id installation_id label session_id boot last_seen_at status contact_status contact_seconds collection_status check_count retired_check_count coverage publications publication_count active_publication_count publications_omitted"
          ),
          :properties,
          &Map.put(&1, :status, S.object())
        ),
      "CoverageScope" =>
        obj(
          "id source_id source_key check_key check_label result_key result_label label environment environment_label target definition_revision counts code_variants runtime_variants definition_variants latest_source_at status knowledge expected_count observed_count selected_count publisher_count runner_count diagnostic"
        ),
      "CoverageObserver" =>
        obj(
          "id runner_id runner_label source_id source_key check_label result_key result_label label environment environment_label target selected exclusion_reason scope_resolved scope_reason definition_revision assignment_id stream_id configuration current measurement_state coverage_received_at coverage_source_revision source_revision runner_context"
        ),
      "CoveragePublisher" =>
        obj(
          "id runner_id runner_label source_id source_revision revision received_at code_revision runtime_revision audit_status lifecycle_status lifecycle_revision retired_at retirement_reason replacement_id resume_after_revision runner_context coverage_revision coverage_received_at coverage_confirmed declaration_count declared_count selected_count excluded_count unresolved_count check_count"
        ),
      "SourceMapping" =>
        S.record(
          %{
            status: S.enum(["requires_local_mapping"]),
            source_id: n(S.string()),
            check_key: n(S.string()),
            note: S.string()
          },
          [:status, :source_id, :check_key, :note]
        ),
      "ConfigurationProvenance" =>
        S.record(
          S.fields(
            "source_id source_key source_revision definition_revision environment params_owner",
            n(S.string())
          )
        ),
      "ConfigurationCurrent" => %Schema{
        type: :object,
        additionalProperties: true,
        properties: %{
          confirmed_params: n(S.ref("ParameterValues")),
          value: n(S.number()),
          knowledge: S.string(),
          health: n(S.string())
        }
      },
      "AssignmentConfiguration" =>
        obj(
          "id kind label params revision parameter_schema params_owner parameter_contract source_id source_key source_revision definition_revision environment environment_label runner_id current desired_generation authorized_generation prepared_generation active_generation observed_generation interval_seconds timeout_seconds freshness_seconds expected_keys outputs retired retired_at retirement_reason configuration_origin configuration_stage effective_configuration configuration_rule configuration_exception configuration_error instance_exception source_defaults parameter_schema_fingerprint configuration_exception_key last_sequence discovery streams runner_label"
        ),
      "Notification" =>
        obj(
          "id assignment_id incident_id monitoring_incident_id condition_incident_id condition_fact_id covered_warn_fact_id gate_revision stream_id result_key kind status health label summary payload destination inserted_at delivered_at updated_at attempts_count next_retry_at gated_until gates attempt_count latest_attempt waiting_on_gates occurrence_id can_retry check_label incident_status gated_indefinitely maintenance_windows delivery_enabled"
        ),
      "Attempt" => obj("id occurrence_id started_at finished_at status http_status error"),
      "Control" =>
        obj(
          "id assignment_id incident_id monitoring_incident_id condition_incident_id stream_id occurrence_id kind actor reason until acknowledgement_impacts acknowledgement_mode acknowledgement_revision acknowledgement_ceiling inserted_at"
        ),
      "HistoricalReport" =>
        obj(
          "id assignment_id installation_id session_id generation sequence started_at evaluated_at received_at disposition payload included_result_keys excerpt original_result_count omitted_result_count"
        ),
      "LossMember" =>
        obj(
          "key stream_id assignment_id label source_id environment knowledge observation_id source_at coverage_id runner_id since_at ready_at target"
        ),
      "MonitoringLossIncident" =>
        obj(
          "id scope_key scope_kind runner_id source_id label display_title check_label result_label environment_label runner_label acknowledgement_active status opened_at closed_at closure_reason member_count opening_observation_id latest_observation_id closing_observation_id acknowledgement_revision attention_revision acknowledgement_mode acknowledged_until acknowledged_at acknowledgement_note"
        )
        |> incident_summary_schema()
    }
  end

  def response(action) do
    case action do
      :assignment_configurations ->
        S.array(S.ref("AssignmentConfiguration"))

      :assignment_inspection ->
        S.ref("AssignmentConfiguration")

      :coverage ->
        S.array(S.ref("CoverageScope"))

      :coverage_scope ->
        S.ref("CoverageScope")

      :coverage_observers ->
        S.array(S.ref("CoverageObserver"))

      :coverage_publishers ->
        S.array(S.ref("CoveragePublisher"))

      :coverage_diagnostics ->
        S.array(S.object())

      :runners ->
        S.array(S.ref("Runner"))

      :runner ->
        S.ref("Runner")

      :rules ->
        obj("rules diagnostics sources total page page_size")

      :rule ->
        S.ref("ConfigurationRule")

      :monitoring_incidents ->
        S.array(S.ref("MonitoringLossIncident"))

      :monitoring_incident ->
        obj(
          "id scope_key scope_kind runner_id source_id label display_title check_label result_label environment_label runner_label status opened_at closed_at closure_reason member_count member_snapshot opening_observation_id latest_observation_id closing_observation_id acknowledgement_revision attention_revision acknowledgement_mode acknowledged_until acknowledged_at acknowledgement_note members occurrences controls limits acknowledgement_active maintenance_windows gates"
        )
        |> incident_summary_schema()

      :configuration_revision ->
        obj("head installation_id")

      :policy_export ->
        S.ref("PolicyManifest")

      :policy_values ->
        obj("rows total page page_size source_id")

      :policy_plan ->
        obj(
          "version manifest project project_revision changes counts rows review_token repository_head base_head head installation_id"
        )

      :policy_apply ->
        obj(
          "project manifest changes changed_count receipts replayed superseded applied_project_revision current_project_revision head repository_head installation_id"
        )

      :rule_seed ->
        S.ref("RuleProposal")

      :rule_preview ->
        obj(
          "proposal review_token fingerprint scope_counts rows counts total page page_size pages"
        )

      :rule_apply ->
        obj("rule receipts changed_count head installation_id repository_head")

      :exception_preview ->
        obj(
          "proposal review_token assignment current_params proposed_params current_origin proposed_origin rows counts total page page_size"
        )

      :exception_reset ->
        obj("assignment receipts changed_count head installation_id repository_head")

      :bulk_select ->
        obj("selection total_matching eligible_count excluded_count")

      a when a in [:bulk_prepare, :bulk_preview] ->
        obj(
          "rows total page page_size pages parameter_schema schema_fingerprint common_params mixed_fields selected_count selected_result_count expires_in_seconds prepare_token review_token changed_count unchanged_count affected_results source_id parameter_contract"
        )

      :bulk_apply ->
        obj("receipts changed_count unchanged_count head installation_id repository_head")

      :bulk_status ->
        obj("rows total page page_size pages counts")

      :publisher ->
        obj("publisher summary history at")

      :publisher_successors ->
        S.array(S.ref("Publisher"))

      :publisher_event ->
        S.array(S.object())

      :publisher_evidence ->
        obj("publisher_id event_id observation configuration referenced_result_keys witnesses")

      :publisher_preview ->
        obj(
          "items total page page_size pages proposal publisher successor summary blockers can_apply review_token expires_in_seconds"
        )

      :publisher_apply ->
        obj("publisher receipt replayed")

      :maintenance_seed ->
        obj("proposal scope_options assignment_id")

      :maintenance_preview ->
        obj(
          "proposal review_token fingerprint rows selection_summary counts page page_size total pages overlaps starts_at ends_at"
        )

      a when a in [:maintenance_apply, :maintenance_cancel] ->
        S.ref("MaintenanceWindow")

      :maintenance_window ->
        merge_ref(
          "MaintenanceWindow",
          obj(
            "proposal scope_options current_matches match_count history history_count selection_summary"
          )
        )

      :maintenance_windows ->
        obj("windows series total page page_size pages status counts")

      a when a in [:maintenance_series, :maintenance_series_apply, :maintenance_series_cancel] ->
        merge_ref(
          "MaintenanceSeries",
          obj(
            "proposal scope_options rows current_matches match_count history history_count history_page history_pages limits selection_summary counts page_size recurrence timezone_version check_label runner_label"
          )
          |> with_properties(series_pagination("SavedMaintenanceOccurrence"))
          |> with_properties(%{history_page: S.integer(), history_pages: S.integer()})
        )

      :maintenance_series_preview ->
        obj(
          "proposal recurrence timezone review_token rows selection_summary counts page_size overlaps"
        )
        |> with_properties(series_pagination("PlannedMaintenanceOccurrence"))
        |> with_properties(%{
          timezone_version: S.string(),
          first_starts_at: S.time(),
          final_ends_at: S.time(),
          overlap_total: S.integer(),
          overlap_omitted: S.integer()
        })

      :maintenance_series_cancel_preview ->
        obj("id revision name reason timezone review_token page page_size total pages")
        |> with_properties(%{
          rows: S.array(S.ref("SavedMaintenanceOccurrence")),
          active_count: S.integer(),
          upcoming_count: S.integer(),
          stops_generation: S.boolean()
        })

      :save ->
        S.ref("AssignmentConfiguration")

      :acknowledge ->
        S.ref("IncidentSummary")

      :retry_notification ->
        S.ref("Notification")

      :notification ->
        obj("occurrence attempts notification_attempts jobs")

      :notifications ->
        obj(
          "occurrences notification_page attempts notification_attempts jobs notification_backlog delivery_enabled"
        )

      :incident ->
        obj(
          "incident assignment stream counts contributions contribution_page contradictions contradiction_page occurrences notification_page notification_counts attempts controls evidence closing_evidence recorded_measurement evidence_projection as_of limits"
        )
        |> then(fn schema ->
          %{
            schema
            | required: [:incident],
              properties: Map.put(schema.properties, :incident, S.ref("IncidentSummary")),
              anyOf: [
                %Schema{
                  type: :object,
                  required: [:recorded_measurement],
                  properties: %{
                    recorded_measurement: S.ref("RecordedMeasurement"),
                    incident: S.ref("IndividualIncidentSummary")
                  }
                },
                %Schema{
                  type: :object,
                  required: [:contributions],
                  properties: %{
                    contributions: S.array(S.ref("IncidentContribution")),
                    incident: S.ref("SharedIncidentSummary")
                  }
                }
              ]
          }
        end)

      :result_inspection ->
        obj("stream assignment incidents controls occurrences evidence limits")
        |> with_properties(%{
          stream: S.ref("Result"),
          measurement_history: %Schema{
            type: :array,
            maxItems: 12,
            items: S.ref("ResultMeasurementHistoryRow")
          }
        })

      :snapshot ->
        obj(
          "assignments assignment_limits streams runners incidents condition_incidents monitoring_incidents occurrences attempts controls evidence overview configuration coverage retention notification_backlog jobs"
        )

      :overview ->
        obj(
          "assignment_count result_count runner_count incident_count open_alert_count open_incident_count unacknowledged_incident_count acknowledged_incident_count monitoring_loss coverage health freshness counts total attention healthy runners retention configuration"
        )

      :health ->
        obj("status")
    end
  end

  defp maintenance_occurrence(properties) do
    dates = %{
      id: S.uuid(),
      index: S.integer(),
      starts_local: S.string(),
      ends_local: S.string(),
      starts_at: %{S.time() | nullable: false},
      ends_at: %{S.time() | nullable: false},
      elapsed_seconds: S.number()
    }

    S.record(
      Map.merge(dates, properties),
      ~w(id index starts_local ends_local starts_at ends_at elapsed_seconds)a
    )
  end

  defp series_pagination(occurrence) do
    "occurrence_page occurrence_pages occurrence_total result_page result_pages result_total"
    |> S.fields(S.integer())
    |> Map.put(:occurrences, S.array(S.ref(occurrence)))
  end

  defp with_properties(schema, properties),
    do: %{schema | properties: Map.merge(schema.properties, properties)}

  defp merge_ref(name, extra),
    do: %{extra | properties: Map.merge(definitions()[name].properties, extra.properties)}

  defp field(key) do
    cond do
      key in ~w(source_defaults params common_params current_params proposed_params masked_params values) ->
        n(S.ref("ParameterValues"))

      key == "parameter_schema" ->
        S.ref("ParameterSchema")

      key == "manifest" ->
        S.ref("PolicyManifest")

      key == "proposal" ->
        n(S.object())

      key == "publisher" or key == "successor" ->
        n(S.ref("Publisher"))

      key in ~w(display_title check_label result_label environment_label runner_label) ->
        n(S.string())

      key == "stream" ->
        n(S.ref("Result"))

      key == "recorded_measurement" ->
        S.ref("RecordedMeasurement")

      key == "contributions" ->
        S.array(S.ref("IncidentContribution"))

      key == "incident" ->
        S.ref("Incident")

      key == "occurrence" ->
        S.ref("Notification")

      key == "assignment" ->
        n(S.ref("Assignment"))

      key == "current" ->
        S.ref("ConfigurationCurrent")

      key == "target" ->
        n(S.ref("Target"))

      key == "selection" ->
        %Schema{type: :array, maxItems: 512, items: S.ref("SelectionEntry")}

      key == "selections" ->
        %Schema{type: :array, maxItems: 512, items: S.ref("MaintenanceSelector")}

      key == "receipts" ->
        S.array(S.ref("ConfigurationReceipt"))

      key == "evidence" ->
        S.array(S.ref("HistoricalReport"))

      key == "closing_evidence" ->
        n(S.ref("HistoricalReport"))

      key == "controls" ->
        S.array(S.ref("Control"))

      key == "attempts" ->
        S.array(S.ref("Attempt"))

      key == "occurrences" ->
        S.array(S.ref("Notification"))

      key == "condition_incidents" ->
        S.array(S.ref("Incident"))

      key == "incidents" ->
        S.array(S.ref("Incident"))

      key == "runners" ->
        S.array(S.ref("Runner"))

      key == "streams" ->
        S.array(S.ref("Result"))

      key == "assignments" ->
        S.array(S.ref("AssignmentConfiguration"))

      key == "windows" or key == "overlaps" ->
        S.array(S.ref("MaintenanceWindow"))

      key == "monitoring_incidents" ->
        S.array(S.ref("MonitoringLossIncident"))

      key in ~w(sources mixed_fields matching_stream_ids expected_keys included_result_keys referenced_result_keys blockers weekdays) ->
        S.array(S.string())

      key in ~w(witnesses publications rows items contributions contradictions jobs current_matches selection_summary outputs diagnostics scope_options rules) ->
        S.array(S.object())

      key in ~w(member_snapshot) ->
        S.array(S.ref("LossMember"))

      key in ~w(can_retry gated_indefinitely waiting_on_gates delivery_enabled enabled changed replayed superseded exception can_apply acknowledged acknowledgement_active retired selected scope_resolved coverage_confirmed) ->
        n(S.boolean())

      key in ~w(id revision series_index open_alert_count target_generation generation sequence http_status gate_revision desired_generation authorized_generation prepared_generation active_generation observed_generation boot lifecycle_revision resume_after_revision coverage_revision publication_count active_publication_count publications_omitted check_count retired_check_count selected_count excluded_count unresolved_count declared_count declaration_count selected_result_count capability_count member_count attention_revision acknowledgement_revision attempt_count attempts_count affected_results matched_checks match_count conflict_count selection_count history_count total page page_size pages total_matching eligible_count selected_result_count changed_count unchanged_count project_revision applied_project_revision current_project_revision expires_in_seconds original_result_count omitted_result_count version priority occurrence_count inventory_revision code_variants runtime_variants definition_variants) ->
        if(key == "id", do: n(%Schema{anyOf: [S.string(), S.integer()]}), else: n(S.integer()))

      key in ~w(contact_seconds interval_seconds timeout_seconds freshness_seconds duration_seconds) ->
        n(S.number())

      key in ~w(error occurrence_id covered_warn_fact_id assignment_id runner_id installation_id session_id source_id source_key check_key check_label result_key result_label label name reason scope kind status health knowledge environment environment_label target_kind target_key parameter_contract params_owner definition_revision source_revision coverage_source_revision code_revision runtime_revision schema_fingerprint fingerprint head repository_head base_head managed_project managed_key project key actor cancelled_by cancellation_reason retirement_reason closure_reason scope_key scope_kind observation_id opening_observation_id latest_observation_id closing_observation_id acknowledgement_mode acknowledgement_note review_token prepare_token start_mode start_fold end_fold starts_local ends_local timezone tzdata_version cadence starts_on ends_on local_time diagnostic measurement_state contact_status collection_status audit_status lifecycle_status evidence_projection configuration_stage source_mapping) ->
        n(S.string())

      key in ~w(until delivered_at started_at finished_at evaluated_at received_at last_seen_at inserted_at updated_at retired_at opened_at closed_at saved_at cancelled_at starts_at ends_at acknowledged_until acknowledged_at coverage_received_at next_retry_at gated_until latest_source_at source_at since_at ready_at at as_of) ->
        S.time()

      # These are named heterogeneous domain aggregates, not inferred Ecto data.
      key in ~w(summary counts matching_counts filters configuration configuration_origin effective_configuration configuration_rule configuration_exception instance_exception configuration_error coverage_context runner_context coverage gates payload receipt report status scheduler telemetry members notification_attempts notification_page notification_counts notification_backlog contribution_page contradiction_page results result_page occurrence_page limits history retention overview attention healthy monitoring_loss health freshness changes before after last_failure_health measured_result evidence_ids proposed_origin current_origin masked_origin) ->
        n(json())

      true ->
        n(json())
    end
  end
end

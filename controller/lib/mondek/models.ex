# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Runner do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runners" do
    field :session_id, Ecto.UUID
    field :boot, :integer
    field :last_seen_at, :utc_datetime_usec
    field :status, :map, default: %{}
    field :label, :string
  end
end

defmodule Mondek.Assignment do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "assignments" do
    field :kind, :string
    field :label, :string
    field :runner_id, Ecto.UUID
    field :revision, :integer, default: 1
    field :desired_generation, :integer, default: 1
    field :prepared_generation, :integer
    field :authorized_generation, :integer
    field :active_generation, :integer
    field :observed_generation, :integer
    field :params, :map
    field :source_defaults, :map, default: %{}
    field :instance_exception, :map
    field :configuration_exception_key, :string
    field :configuration_origin, :map, default: %{}
    field :interval_seconds, :float, default: 3.0
    field :timeout_seconds, :float, default: 2.0
    field :freshness_seconds, :float, default: 12.0
    field :expected_keys, {:array, :string}
    field :last_sequence, :integer, default: 0
    field :current, :map, default: %{}
    field :retired_at, :utc_datetime_usec
    field :retirement_reason, :string
    field :source_id, :string
    field :source_key, :string
    field :source_revision, :string
    field :definition_revision, :string
    field :environment, :string
    field :environment_label, :string
    field :params_owner, :string, default: "ui"
    field :parameter_contract, :string
    field :parameter_schema_fingerprint, :string
    field :parameter_schema, :map, default: %{}
    field :discovery, :map, default: %{}
    field :outputs, {:array, :map}, default: []
  end
end

defmodule Mondek.MaintenanceWindow do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "maintenance_windows" do
    field :series_id, Ecto.UUID
    field :series_index, :integer
    field :selection_count, :integer, virtual: true
    field :revision, :integer, default: 1
    field :name, :string
    field :reason, :string
    field :actor, :string
    field :scope, :string
    field :selections, {:array, :map}, default: []
    field :assignment_id, :string
    field :source_id, :string
    field :environment, :string
    field :target_kind, :string
    field :target_key, :string
    field :timezone, :string, default: "Etc/UTC"
    field :tzdata_version, :string
    field :starts_local, :string
    field :ends_local, :string
    field :start_fold, :string, default: "reject"
    field :end_fold, :string, default: "reject"
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :cancelled_by, :string
    field :cancellation_reason, :string
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Mondek.MaintenanceSeries do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "maintenance_series" do
    field :revision, :integer, default: 1
    field :name, :string
    field :reason, :string
    field :actor, :string
    field :proposal, :map
    field :resolved_windows, {:array, :map}, default: []
    field :tzdata_version, :string
    field :inserted_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Mondek.MaintenanceSeriesEvent do
  use Ecto.Schema

  schema "maintenance_series_events" do
    field :series_id, Ecto.UUID
    field :revision, :integer
    field :kind, :string
    field :actor, :string
    field :reason, :string
    field :snapshot, :map
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.MaintenanceEvent do
  use Ecto.Schema

  schema "maintenance_events" do
    field :window_id, Ecto.UUID
    field :revision, :integer
    field :kind, :string
    field :actor, :string
    field :reason, :string
    field :snapshot, :map
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.ConfigurationRule do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "configuration_rules" do
    field :repository_key, :string
    field :managed_project, :string
    field :managed_key, :string
    field :revision, :integer, default: 1
    field :name, :string
    field :source_id, :string
    field :parameter_contract, :string
    field :environment, :string
    field :target_kind, :string
    field :target_key, :string
    field :priority, :integer, default: 0
    field :enabled, :boolean, default: true
    field :parameter_schema, :map
    field :params, :map
    field :saved_at, :utc_datetime_usec
  end
end

defmodule Mondek.ConfigurationPolicyProject do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "configuration_policy_projects" do
    field :revision, :integer, default: 0
  end
end

defmodule Mondek.ConfigurationPolicyReceipt do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "configuration_policy_receipts" do
    field :project, :string
    field :project_revision, :integer
    field :manifest_hash, :string
    field :response, :map
    field :applied_at, :utc_datetime_usec
  end
end

defmodule Mondek.ConfigurationRuleDiagnostic do
  use Ecto.Schema

  schema "configuration_rule_diagnostics" do
    field :source_id, :string
    field :runner_id, Ecto.UUID
    field :source_key, :string
    field :source_revision, :string
    field :inventory_revision, :integer
    field :rule_ids, {:array, Ecto.UUID}, default: []
    field :message, :string
    field :recorded_at, :utc_datetime_usec
  end
end

defmodule Mondek.Configuration do
  use Ecto.Schema

  schema "configurations" do
    field :assignment_id, :string
    field :generation, :integer
    field :params, :map
    field :definition, :map, default: %{}
    field :saved_at, :utc_datetime_usec
  end
end

defmodule Mondek.Observation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "observations" do
    field :assignment_id, :string
    field :installation_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :generation, :integer
    field :sequence, :integer
    field :started_at, :utc_datetime_usec
    field :evaluated_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :payload, :map
    field :disposition, :string
  end
end

defmodule Mondek.Incident do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "incidents" do
    field :condition_incident_id, Ecto.UUID
    field :opening_observation_id, Ecto.UUID
    field :latest_observation_id, Ecto.UUID
    field :impacts, {:array, :map}, default: []
    field :acknowledgement_impacts, {:array, :string}, default: []
    field :assignment_id, :string
    field :result_key, :string
    field :stream_id, Ecto.UUID
    field :environment, :string
    field :environment_label, :string
    field :health, :string
    field :status, :string, default: "open"
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :closure_reason, :string
    field :closing_observation_id, Ecto.UUID
    field :opening_generation, :integer
    field :attention_revision, :integer, default: 1
    field :acknowledged_until, :utc_datetime_usec
    field :acknowledgement_mode, :string
    field :acknowledgement_revision, :integer, default: 0
    field :acknowledgement_note, :string
    field :acknowledged_by, :string
    field :acknowledgement_ceiling, :string
  end
end

defmodule Mondek.SourceInventory do
  use Ecto.Schema

  schema "source_inventories" do
    field :runner_id, Ecto.UUID
    field :source_id, :string
    field :revision, :integer
    field :source_revision, :string
    field :payload, :map
    field :received_at, :utc_datetime_usec
    field :coverage_version, :integer
    field :coverage_revision, :integer
    field :coverage_received_at, :utc_datetime_usec
    field :coverage_source_revision, :string
    field :coverage_code_revision, :string
    field :coverage_runtime_revision, :string
    field :coverage_context, :map
    field :coverage_confirmed, :boolean, default: false
    field :lifecycle_revision, :integer, default: 1
    field :retired_at, :utc_datetime_usec
    field :retirement_reason, :string
    field :replacement_id, :integer
    field :resume_after_revision, :integer
  end
end

defmodule Mondek.PublisherLifecycleEvent do
  use Ecto.Schema

  schema "publisher_lifecycle_events" do
    field :publisher_id, :integer
    field :lifecycle_revision, :integer
    field :action, :string
    field :reason, :string
    field :actor, :string
    field :successor_id, :integer
    field :review_digest, :string
    field :proposal, :map
    field :snapshot, :map
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.PublisherLifecycleEvidence do
  use Ecto.Schema
  @primary_key false

  schema "publisher_lifecycle_evidence" do
    field :event_id, :integer, primary_key: true
    field :observation_id, Ecto.UUID, primary_key: true
  end
end

defmodule Mondek.CoverageDeclaration do
  use Ecto.Schema

  schema "coverage_declarations" do
    field :source_inventory_id, :integer
    field :runner_id, Ecto.UUID
    field :source_id, :string
    field :source_key, :string
    field :result_key, :string
    field :scope_id, :string
    field :environment, :string
    field :environment_label, :string
    field :target_kind, :string
    field :target_key, :string
    field :target_label, :string
    field :check_group, :map
    field :check_label, :string
    field :result_label, :string
    field :selected, :boolean
    field :exclusion_reason, :string
    field :scope_resolved, :boolean
    field :scope_reason, :string
    field :definition_revision, :string
    field :assignment_id, :string
  end
end

defmodule Mondek.ResultStream do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "result_streams" do
    field :assignment_id, :string
    field :admission_generation, :integer, default: 1
    field :retirement_generation, :integer
    field :result_key, :string
    field :label, :string
    field :target, :map
    field :condition, :map
    field :check_group, :map
    field :environment, :string
    field :environment_label, :string
    field :current, :map, default: %{}
    field :retired_at, :utc_datetime_usec
    field :retirement_reason, :string
  end
end

defmodule Mondek.Occurrence do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "occurrences" do
    field :monitoring_incident_id, Ecto.UUID
    field :condition_incident_id, Ecto.UUID
    field :condition_fact_id, Ecto.UUID
    field :covered_warn_fact_id, Ecto.UUID
    field :gate_revision, :integer, default: 0
    field :incident_id, Ecto.UUID
    field :kind, :string
    field :attention_revision, :integer
    field :payload, :map
    field :destination, :string
    field :status, :string, default: "pending"
    field :inserted_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
  end
end

defmodule Mondek.Attempt do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attempts" do
    field :occurrence_id, Ecto.UUID
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :http_status, :integer
    field :error, :string
  end
end

defmodule Mondek.Control do
  use Ecto.Schema

  schema "controls" do
    field :monitoring_incident_id, Ecto.UUID
    field :condition_incident_id, Ecto.UUID
    field :acknowledgement_impacts, {:array, :string}, default: []
    field :acknowledgement_mode, :string
    field :acknowledgement_revision, :integer
    field :acknowledgement_ceiling, :string
    field :assignment_id, :string
    field :stream_id, Ecto.UUID
    field :incident_id, Ecto.UUID
    field :occurrence_id, Ecto.UUID
    field :kind, :string
    field :actor, :string
    field :reason, :string
    field :until, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.MonitoringGap do
  use Ecto.Schema
  @primary_key {:key, :string, autogenerate: false}
  schema "monitoring_gaps" do
    field :identity, Ecto.UUID, autogenerate: true
    field :scope_key, :string
    field :details, :map
    field :since_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
  end
end

defmodule Mondek.MonitoringIncident do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "monitoring_incidents" do
    field :scope_key, :string
    field :scope_kind, :string
    field :runner_id, Ecto.UUID
    field :source_id, :string
    field :label, :string
    field :status, :string, default: "open"
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :closure_reason, :string
    field :had_withdrawals, :boolean, default: false
    field :member_count, :integer
    field :member_snapshot, {:array, :map}, default: []
    field :closing_evidence, {:array, :map}, default: []
    field :attention_revision, :integer, default: 1
    field :acknowledgement_mode, :string
    field :acknowledgement_revision, :integer, default: 0
    field :acknowledged_until, :utc_datetime_usec
    field :acknowledgement_note, :string
    field :acknowledged_by, :string
  end
end

defmodule Mondek.ConditionIncident do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "condition_incidents" do
    field :namespace, :string
    field :key, :string
    field :environment, :string
    field :label, :string
    field :health, :string
    field :impacts, {:array, :map}, default: []
    field :status, :string, default: "open"
    field :opened_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :closure_reason, :string
    field :closure_reasons, {:array, :string}, default: []
    field :closing_observation_id, Ecto.UUID
    field :attention_revision, :integer, default: 1
    field :support_fingerprint, :string
    field :acknowledgement_mode, :string
    field :acknowledgement_revision, :integer, default: 0
    field :acknowledgement_ceiling, :string
    field :acknowledgement_impacts, {:array, :string}, default: []
    field :acknowledged_until, :utc_datetime_usec
    field :acknowledged_by, :string
    field :acknowledgement_note, :string
  end
end

defmodule Mondek.ConditionFact do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "condition_facts" do
    field :condition_incident_id, Ecto.UUID
    field :kind, :string
    field :key, :string
    field :label, :string
    field :opened_at, :utc_datetime_usec
    field :opening_observation_id, Ecto.UUID
    field :opening_incident_id, Ecto.UUID
    field :ended_at, :utc_datetime_usec
    field :end_reason, :string
    field :covered_by_occurrence_id, Ecto.UUID
    field :covered_at, :utc_datetime_usec
  end
end

defmodule Mondek.OccurrenceEvidence do
  use Ecto.Schema
  @primary_key false
  schema "occurrence_evidence" do
    field :occurrence_id, Ecto.UUID, primary_key: true
    field :observation_id, Ecto.UUID, primary_key: true
    field :incident_id, Ecto.UUID, primary_key: true
    field :result_key, :string
    field :generation, :integer
    field :role, :string
  end
end

defmodule Mondek.DiscoveryChange do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "discovery_changes" do
    field(:assignment_id, :string)
    field(:source_id, :string)
    field(:scope, :string)
    field(:params, :map)
    field(:members, {:array, :map})
    field(:pending, :boolean, default: true)
    field(:resource, :map, default: %{})
    field(:saved_at, :utc_datetime_usec)
  end
end

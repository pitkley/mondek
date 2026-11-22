# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddGroupingEvaluations do
  use Ecto.Migration

  def change do
    alter table(:correlation_memberships) do
      add :provenance, :text, null: false, default: "operator"
    end

    create table(:correlation_grouping_evaluations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :incident_id, references(:incidents, type: :uuid, on_delete: :delete_all)

      add :condition_incident_id,
          references(:condition_incidents, type: :uuid, on_delete: :delete_all)

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :nilify_all)
      add :disposition, :text, null: false
      add :reason, :text, null: false
      add :evidence, :map, null: false
      add :evaluated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:correlation_grouping_evaluations, [:incident_id])
    create unique_index(:correlation_grouping_evaluations, [:condition_incident_id])

    create constraint(:correlation_grouping_evaluations, :one_grouping_subject,
             check: "num_nonnulls(incident_id, condition_incident_id) = 1"
           )
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddCorrelationAutomationPolicy do
  use Ecto.Migration

  def change do
    create table(:correlation_automation_rules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :source_id, :text, null: false
      add :check_id, :text, null: false
      add :output_key, :text, null: false
      add :hint, :map, null: false
      add :enabled, :boolean, null: false
      add :revision, :bigint, null: false
      add :reason, :text, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:correlation_automation_rules, [:source_id, :check_id, :output_key])
    create index(:correlation_automation_rules, [:id], where: "enabled")

    create table(:correlation_automation_overrides, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :incident_id, references(:incidents, type: :uuid, on_delete: :delete_all)
      add :condition_id, references(:condition_incidents, type: :uuid, on_delete: :delete_all)
      add :active, :boolean, null: false
      add :revision, :bigint, null: false
      add :reason, :text, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :request_id, :uuid
    end

    create constraint(:correlation_automation_overrides, :correlation_override_exact_endpoint,
             check: "num_nonnulls(incident_id, condition_id) = 1"
           )

    create unique_index(:correlation_automation_overrides, [:incident_id])
    create unique_index(:correlation_automation_overrides, [:condition_id])
  end
end

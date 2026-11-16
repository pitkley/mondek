# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddCorrelations do
  use Ecto.Migration

  def change do
    create table(:correlation_cases, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :title, :text, null: false
      add :environment, :text
      add :revision, :bigint, null: false, default: 1
      add :inserted_at, :utc_datetime_usec, null: false
      add :terminal_reason, :text
      add :terminal_at, :utc_datetime_usec
    end

    create table(:correlation_memberships, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :delete_all),
        null: false

      add :incident_id, references(:incidents, type: :uuid)
      add :condition_incident_id, references(:condition_incidents, type: :uuid)
      add :anchor, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :end_reason, :text
    end

    create constraint(:correlation_memberships, :one_episode,
             check: "num_nonnulls(incident_id, condition_incident_id) = 1"
           )

    create unique_index(:correlation_memberships, [:incident_id], where: "ended_at IS NULL")

    create unique_index(:correlation_memberships, [:condition_incident_id],
             where: "ended_at IS NULL"
           )

    create unique_index(:correlation_memberships, [:case_id],
             where: "ended_at IS NULL AND anchor"
           )

    create index(:correlation_memberships, [:incident_id],
             name: :correlation_membership_history_incident
           )

    create index(:correlation_memberships, [:condition_incident_id],
             name: :correlation_membership_history_condition
           )

    create index(:correlation_memberships, [:case_id, :inserted_at, :id])

    create table(:correlation_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :delete_all),
        null: false

      add :action, :text, null: false
      add :provenance, :text, null: false
      add :actor, :text, null: false
      add :reason, :text, null: false
      add :confidence, :float
      add :inserted_at, :utc_datetime_usec, null: false
      add :change, :map, null: false
    end

    create index(:correlation_decisions, [:case_id, :inserted_at, :id])

    create table(:correlation_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :fingerprint, :text, null: false

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :delete_all),
        null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end

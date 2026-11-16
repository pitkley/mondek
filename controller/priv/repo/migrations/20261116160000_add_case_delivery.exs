# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddCaseDelivery do
  use Ecto.Migration

  def change do
    alter table(:correlation_cases) do
      add :topology_revision, :bigint, null: false, default: 1
      add :batching_enabled, :boolean, null: false, default: false
    end

    create table(:correlation_acknowledgements, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :delete_all),
        null: false

      add :revision, :bigint, null: false
      add :topology_revision, :bigint, null: false
      add :mode, :text, null: false
      add :until, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :end_reason, :text
      add :ceiling, :text, null: false
      add :note, :text, null: false
      add :actor, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:correlation_acknowledgements, [:case_id, :inserted_at])

    create table(:correlation_witnesses, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :ack_id, references(:correlation_acknowledgements, type: :uuid, on_delete: :delete_all),
        null: false

      add :incident_id, references(:incidents, type: :uuid)
      add :condition_incident_id, references(:condition_incidents, type: :uuid)
      add :ceiling, :text, null: false
      add :impacts, {:array, :text}, null: false, default: []
      add :invalidated_at, :utc_datetime_usec
      add :reason, :text
    end

    create constraint(:correlation_witnesses, :one_witness_episode,
             check: "num_nonnulls(incident_id,condition_incident_id)=1"
           )

    create index(:correlation_witnesses, [:incident_id])
    create index(:correlation_witnesses, [:condition_incident_id])

    create table(:correlation_batches, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :case_id, references(:correlation_cases, type: :uuid, on_delete: :delete_all),
        null: false

      add :topology_revision, :bigint, null: false
      add :status, :text, null: false
      add :payload, :map, null: false
      add :destination, :text, null: false
      add :transport, :map, null: false
      add :limit, :integer, null: false
      add :attempts, :integer, null: false, default: 0
      add :deadline, :utc_datetime_usec, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :accepted_at, :utc_datetime_usec
      add :terminal_id, :uuid, null: false
      add :terminal_payload, :map
      add :terminal_attempts, :integer, null: false, default: 0
      add :terminal_status, :text, null: false, default: "none"
    end

    create index(:correlation_batches, [:case_id, :inserted_at])

    create table(:correlation_credits, primary_key: false) do
      add :occurrence_id, references(:occurrences, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :epoch, :bigint, null: false
      add :limit, :integer, null: false
      add :spent, :integer, null: false, default: 0
      add :handover_until, :utc_datetime_usec
    end

    create constraint(:correlation_credits, :credit_bound,
             check: "spent>=0 AND spent<=\"limit\" AND \"limit\">0"
           )

    create table(:correlation_reservations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :batch_id, references(:correlation_batches, type: :uuid, on_delete: :delete_all),
        null: false

      add :occurrence_id, references(:occurrences, type: :uuid), null: false
      add :epoch, :bigint, null: false
      add :membership_id, references(:correlation_memberships, type: :uuid), null: false
      add :status, :text, null: false
    end

    # Case deletion cascades memberships and batches in the same transaction.
    # Retain the reference check until both cascades have completed.
    execute(
      "ALTER TABLE correlation_reservations DROP CONSTRAINT correlation_reservations_membership_id_fkey",
      "SELECT 1"
    )

    execute(
      "ALTER TABLE correlation_reservations ADD CONSTRAINT correlation_reservations_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES correlation_memberships(id) DEFERRABLE INITIALLY DEFERRED",
      "ALTER TABLE correlation_reservations DROP CONSTRAINT correlation_reservations_membership_id_fkey"
    )

    create unique_index(:correlation_reservations, [:occurrence_id], where: "status='reserved'")
    create index(:correlation_reservations, [:batch_id])

    create index(:correlation_reservations, [:occurrence_id],
             name: :reservation_history_occurrence
           )

    create table(:correlation_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :batch_id, references(:correlation_batches, type: :uuid, on_delete: :delete_all),
        null: false

      add :kind, :text, null: false
      add :status, :text, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :error, :text
    end

    create index(:correlation_attempts, [:batch_id, :started_at])
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddCorrelationRelationships do
  use Ecto.Migration

  def change do
    create table(:correlation_relationships, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :sequence, :bigserial, null: false
      add :subject_incident_id, references(:incidents, type: :uuid)
      add :subject_condition_id, references(:condition_incidents, type: :uuid)
      add :target_incident_id, references(:incidents, type: :uuid)
      add :target_condition_id, references(:condition_incidents, type: :uuid)
      add :dimension, :text, null: false
      add :matches, {:array, :map}, null: false
      add :actor, :text, null: false
      add :reason, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :removed_at, :utc_datetime_usec
      add :removed_by, :text
      add :removal_reason, :text
    end

    create constraint(:correlation_relationships, :typed_distinct_endpoints,
             check: """
             num_nonnulls(subject_incident_id, subject_condition_id) = 1 AND
             num_nonnulls(target_incident_id, target_condition_id) = 1 AND
             (subject_incident_id IS NULL OR target_incident_id IS DISTINCT FROM subject_incident_id) AND
             (subject_condition_id IS NULL OR target_condition_id IS DISTINCT FROM subject_condition_id)
             """
           )

    create constraint(:correlation_relationships, :consistent_removal,
             check:
               "num_nonnulls(removed_at, removed_by, removal_reason) IN (0, 3) AND (removed_at IS NULL OR removed_at >= inserted_at)"
           )

    for subject <- [:subject_incident_id, :subject_condition_id],
        target <- [:target_incident_id, :target_condition_id] do
      create unique_index(:correlation_relationships, [subject, target, :dimension],
               name: :"unique_#{subject}_#{target}_link",
               where: "removed_at IS NULL AND #{subject} IS NOT NULL AND #{target} IS NOT NULL"
             )
    end

    for endpoint <- [
          :subject_incident_id,
          :subject_condition_id,
          :target_incident_id,
          :target_condition_id
        ] do
      create index(:correlation_relationships, [endpoint, :inserted_at, :id],
               name: :"relationship_history_#{endpoint}"
             )
    end

    create table(:correlation_relationship_receipts, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :relationship_id,
          references(:correlation_relationships, type: :uuid, on_delete: :delete_all), null: false

      add :fingerprint, :text, null: false
    end
  end
end

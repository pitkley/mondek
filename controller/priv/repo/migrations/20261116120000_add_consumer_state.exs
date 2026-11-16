# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddConsumerState do
  use Ecto.Migration

  def change do
    alter table(:runners) do
      add :state_window_at, :utc_datetime_usec
      add :state_requests, :integer, null: false, default: 0
    end

    create table(:consumer_state_namespaces, primary_key: false) do
      add :source_id, :text, primary_key: true
      add :bytes, :integer, null: false, default: 0
      add :entries, :integer, null: false, default: 0
    end

    create constraint(:consumer_state_namespaces, :consumer_state_quota,
             check: "bytes BETWEEN 0 AND 1048576 AND entries BETWEEN 0 AND 1024"
           )

    create table(:consumer_state_entries, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :source_id, references(:consumer_state_namespaces, column: :source_id, type: :text),
        null: false

      add :scope, :text, null: false
      add :key, :text, null: false
      # Wrapper permits any JSON value, including null, with Ecto's map type.
      add :payload, :map, null: false
      add :version, :uuid, null: false
      add :bytes, :integer, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec
      # Attribution is not an ownership FK: cleanup never locks these parents.
      add :installation_id, :uuid, null: false
      add :session_id, :uuid, null: false
      add :assignment_id, :text, null: false
      add :generation, :integer, null: false
    end

    create unique_index(:consumer_state_entries, [:source_id, :scope, :key])
    create index(:consumer_state_entries, [:expires_at])

    create constraint(:consumer_state_entries, :consumer_state_entry_bounds,
             check: "bytes BETWEEN 1 AND 65736 AND octet_length(key) BETWEEN 1 AND 200"
           )
  end
end

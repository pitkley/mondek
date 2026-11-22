# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddProviderDecisions do
  use Ecto.Migration

  def change do
    create table(:correlation_provider_decisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :subject_type, :text, null: false
      add :subject_id, :uuid, null: false
      add :subject_revision, :map, null: false
      add :provider_id, :text, null: false
      add :config_revision, :text, null: false
      add :request_bytes, :binary, null: false
      add :candidates, {:array, :map}, null: false
      add :resolved_at, :utc_datetime_usec
      add :requested_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :status, :text, null: false
      add :attempts, :integer, null: false, default: 0
      add :lease, :uuid
      add :leased_until, :utc_datetime_usec
      add :reply_digest, :text
      add :selected_handle, :text
      add :reason, :text
      add :confidence, :float
      add :case_id, :uuid
    end

    create index(
             :correlation_provider_decisions,
             [:subject_type, :subject_id, :requested_at, :id],
             name: :provider_decisions_subject_history
           )

    create index(:correlation_provider_decisions, [:expires_at])
  end
end

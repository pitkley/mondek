# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddMaintenanceProjects do
  use Ecto.Migration

  def change do
    create table(:maintenance_projects, primary_key: false) do
      add :id, :text, primary_key: true
      add :revision, :bigint, null: false
      add :receipt, :map
    end

    create table(:managed_maintenance_schedules, primary_key: false) do
      add :project, references(:maintenance_projects, type: :text), primary_key: true
      add :key, :text, primary_key: true
      add :series_id, references(:maintenance_series, type: :binary_id, on_delete: :nilify_all)
      add :proposal, :map, null: false
      add :active, :boolean, default: true, null: false
    end

    create unique_index(:managed_maintenance_schedules, [:series_id])

    create constraint(:managed_maintenance_schedules, :managed_live_series,
             check: "NOT active OR series_id IS NOT NULL"
           )
  end
end

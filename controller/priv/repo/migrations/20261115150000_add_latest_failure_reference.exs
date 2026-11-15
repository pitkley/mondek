# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddLatestFailureReference do
  use Ecto.Migration

  def change do
    alter table(:incidents) do
      add :latest_failure_observation_id, references(:observations, type: :uuid)
    end

    create index(:incidents, [:latest_failure_observation_id])
  end
end

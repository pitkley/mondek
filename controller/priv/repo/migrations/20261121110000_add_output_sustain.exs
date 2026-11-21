# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddOutputSustain do
  use Ecto.Migration

  def change do
    alter table(:result_streams) do
      add :sustain, :map, null: false, default: %{}
    end
  end
end

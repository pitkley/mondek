# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.CurrentBaseline do
  use Ecto.Migration

  def up do
    # This baseline deliberately does not upgrade pre-publication installations.
    # Fail before changing any application or job data on an old database.
    %{rows: [[count]]} = repo().query!("SELECT count(*) FROM schema_migrations")

    if count != 0 do
      raise "Mondek baseline requires a fresh database; use the private experimental installation transition before upgrading retained state"
    end

    Oban.Migration.up(version: 14)
    execute "SET LOCAL check_function_bodies = off"

    Application.app_dir(:mondek, "priv/repo/baseline.sql")
    |> File.read!()
    |> String.split("-- mondek:statement\n")
    |> tl()
    |> Enum.each(&execute/1)
  end

  def down do
    raise "The initial baseline cannot be rolled back destructively; restore a coordinated backup or recreate an explicitly disposable database"
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Release do
  require Logger

  def migrate do
    Application.load(:mondek)

    {:ok, versions, _} =
      Ecto.Migrator.with_repo(Mondek.Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true, log: :debug)
      end)

    Logger.info("Database migrations complete: #{length(versions)} applied")
  end
end

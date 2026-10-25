# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Release do
  def migrate do
    Application.load(:mondek)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Mondek.Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)
  end
end

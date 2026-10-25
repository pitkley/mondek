# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mondek,
      version: "0.0.1-alpha.2",
      package: [licenses: ["Apache-2.0"]],
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]

  def application,
    do: [mod: {Mondek.Application, []}, extra_applications: [:logger, :inets, :ssl]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps,
    do: [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:oban, "~> 2.19"},
      {:bandit, "~> 1.13.1"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.1.2"},
      {:tz, "~> 0.28.2"},
      {:gen_smtp, "~> 1.3.0"},
      {:lazy_html, "~> 0.1.13", only: :test}
    ]

  defp aliases,
    do: [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
end

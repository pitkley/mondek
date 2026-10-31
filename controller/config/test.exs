# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import Config
config :mondek, Mondek.Repo, pool: Ecto.Adapters.SQL.Sandbox
config :mondek, Oban, testing: :manual, plugins: false, queues: false
config :mondek, MondekWeb.Endpoint, server: false
config :mondek, :sweep_enabled, false
config :logger, level: :warning

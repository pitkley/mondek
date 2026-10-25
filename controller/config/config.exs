# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import Config
config :mondek, ecto_repos: [Mondek.Repo]

config :mondek, MondekWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MondekWeb.ErrorHTML, json: MondekWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mondek.PubSub,
  live_view: [signing_salt: "local-mondek"]

config :mondek, Oban,
  repo: Mondek.Repo,
  queues: [notifications: 4],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    # Outlive the worker's one-minute execution limit, including database work.
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(2)}
  ]

config :phoenix, :json_library, Jason
config :logger, :console, format: "$time $metadata[$level] $message\n"
import_config "#{config_env()}.exs"

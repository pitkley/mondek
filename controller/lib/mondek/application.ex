# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Application do
  use Application

  def start(_type, _args) do
    children =
      [
        Mondek.Repo,
        {Phoenix.PubSub, name: Mondek.PubSub},
        {Oban, Application.fetch_env!(:mondek, Oban)},
        MondekWeb.Endpoint
      ] ++
        if(Application.get_env(:mondek, :sweep_enabled, true),
          do: [Mondek.Sweeper],
          else: []
        )

    Supervisor.start_link(children, strategy: :one_for_one, name: Mondek.Supervisor)
  end

  def config_change(changed, _new, removed),
    do: MondekWeb.Endpoint.config_change(changed, removed)
end

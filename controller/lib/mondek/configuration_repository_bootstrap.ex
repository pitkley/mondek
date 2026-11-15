# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationRepositoryBootstrap do
  @moduledoc "Initialize the configuration journal before HTTP starts, after database migrations."
  def child_spec(_),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}

  def start_link(_) do
    case Mondek.ConfigurationRepository.state() do
      {:ok, _} -> :ignore
      {:error, reason} -> {:error, reason}
    end
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RuntimeSession do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(options) do
    %{
      local: Plug.Session.init(options),
      deployment: Plug.Session.init(Keyword.put(options, :secure, true)),
      rewrite: Plug.RewriteOn.init([:x_forwarded_proto])
    }
  end

  @impl true
  def call(conn, options) do
    if Application.get_env(:mondek, :deployment_mode, false) do
      # The deployment profile exposes HTTP only to its private Docker networks.
      # Traefik terminates TLS and supplies this header. Host and client identity
      # are deliberately not rewritten from forwarded headers.
      conn
      |> Plug.RewriteOn.call(options.rewrite)
      |> Plug.Session.call(options.deployment)
    else
      Plug.Session.call(conn, options.local)
    end
  end
end

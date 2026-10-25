# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0 AND MIT
# Portions derived from Phoenix scaffolding, Copyright (c) 2014 Chris McCord.
# See licensing/PHOENIX-LICENSE.md.
defmodule MondekWeb do
  def controller,
    do:
      quote(
        do:
          (
            use Phoenix.Controller, formats: [:html, :json]
            import Plug.Conn
          )
      )

  def html,
    do:
      quote(
        do:
          (
            use Phoenix.Component
            import Phoenix.HTML
          )
      )

  def live_view,
    do:
      quote(
        do:
          (
            use Phoenix.LiveView, layout: false
            import Phoenix.HTML
          )
      )

  defmacro __using__(which), do: apply(__MODULE__, which, [])
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.Controller do
  @moduledoc false
  defmacro __using__(_) do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      import MondekWeb.API.Response
      plug OpenApiSpex.Plug.PutApiSpec, module: MondekWeb.API.ApiSpec
      plug MondekWeb.API.Validate
    end
  end
end

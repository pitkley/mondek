# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo do
  use Ecto.Repo, otp_app: :mondek, adapter: Ecto.Adapters.Postgres
end

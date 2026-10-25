# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Licenses do
  @moduledoc "Build-time notices; releases need neither dependency sources nor network access."
  @inventory Path.expand("../../priv/licenses.json", __DIR__)
  @license Path.expand("../../priv/LICENSE", __DIR__)
  @notices Path.expand("../../priv/THIRD_PARTY_LICENSES.md", __DIR__)
  @external_resource @inventory
  @external_resource @license
  @external_resource @notices
  @components @inventory |> File.read!() |> Jason.decode!() |> Map.fetch!("components")
  @application_license File.read!(@license)
  @third_party_notices File.read!(@notices)

  def components, do: @components
  def application_license, do: @application_license
  def third_party_notices, do: @third_party_notices
end

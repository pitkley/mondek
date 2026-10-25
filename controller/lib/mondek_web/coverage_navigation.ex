# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageNavigation do
  @moduledoc "Bounded coverage filters shared by browsing and investigation returns."
  @filters ~w(search source_id environment runner_id status lifecycle page list_page)

  @doc false
  def filters(params) do
    filters =
      params
      |> Map.take(@filters)
      |> Map.filter(fn {_key, value} ->
        (is_binary(value) and byte_size(value) <= 200 and String.valid?(value) and
           not String.match?(value, ~r/[\x00-\x1f\x7f]/)) or is_integer(value)
      end)

    case origin(params["return_to"]) do
      nil -> filters
      path -> Map.put(filters, "return_to", path)
    end
  end

  # Coverage can return to a specific incident or runner, never another coverage
  # URL. Their own helpers bound further context and prevent recursive chains.
  def origin(value) do
    MondekWeb.MonitoringIncidentNavigation.return_path(value) ||
      MondekWeb.RunnerNavigation.return_path(value)
  end

  def return_path(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if is_nil(uri.scheme) && is_nil(uri.host) && is_nil(uri.fragment) &&
         (uri.path in ["/coverage", "/coverage/publishers", "/coverage/diagnostics"] ||
            (is_binary(uri.path) && Regex.match?(~r"\A/coverage/[a-f0-9]{64}\z", uri.path))) do
      query =
        uri.query
        |> Kernel.||("")
        |> URI.decode_query()
        |> filters()
        |> Enum.sort()
        |> URI.encode_query()

      uri.path <> if(query == "", do: "", else: "?" <> query)
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MonitoringIncidentNavigation do
  @moduledoc "Canonical monitoring-loss incident filters and bounded return destinations."
  def list_path(filters), do: "/monitoring-incidents" <> query(filters)

  def detail_path(id, filters), do: "/monitoring-incidents/" <> id <> query(filters)

  defp query(filters),
    do: if(map_size(filters) == 0, do: "", else: "?" <> URI.encode_query(filters))

  def page_path(filters, nil, page), do: list_path(Map.put(filters, "page", page))
  def page_path(filters, id, page), do: detail_path(id, Map.put(filters, "members_page", page))
  @doc false
  def return_path(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.fragment) and is_binary(uri.path) do
      case String.split(uri.path, "/", trim: true) do
        ["monitoring-incidents", id] ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> detail_path(id, normalize_filters(URI.decode_query(uri.query || "")))
            _ -> nil
          end

        _ ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil

  def normalize_filters(params) do
    filters =
      params
      |> Map.take(~w(status runner_id source_id page members_page))
      |> Map.filter(fn {_key, value} -> is_binary(value) and byte_size(value) <= 200 end)

    case runner_return(params["return_to"]) do
      nil -> filters
      path -> Map.put(filters, "return_to", path)
    end
  end

  defp runner_return(value) do
    MondekWeb.NotificationNavigation.return_path(value) ||
      MondekWeb.RunnerNavigation.return_path(value)
  end
end

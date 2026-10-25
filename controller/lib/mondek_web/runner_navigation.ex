# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnerNavigation do
  @moduledoc "Canonical fleet and runner investigation URLs with bounded return destinations."
  alias Mondek.RunnerFleet
  @filter_keys ~w(search contact collection source_id sort page page_size)

  def path(filters) do
    query =
      filters
      |> RunnerFleet.normalize()
      |> Map.take(@filter_keys)
      |> Enum.reject(fn {key, value} ->
        value in [nil, "", "all"] || (key == "page" && value in [1, "1"]) ||
          (key == "sort" && value == "attention") || (key == "page_size" && value in [25, "25"])
      end)
      |> Enum.sort()
      |> URI.encode_query()

    "/runners" <> if(query == "", do: "", else: "?" <> query)
  end

  def detail_path(id, return_to \\ nil) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        "/runners/" <>
          id <> if(return_to, do: "?" <> URI.encode_query(%{"return_to" => return_to}), else: "")

      :error ->
        "/runners/not-found"
    end
  end

  @doc "Canonical runner destinations for bounded return navigation."
  def return_path(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)
    params = URI.decode_query(uri.query || "")

    if uri.scheme == nil && uri.host == nil && uri.fragment == nil do
      cond do
        uri.path == "/runners" ->
          path(params)

        is_binary(uri.path) && String.starts_with?(uri.path, "/runners/") ->
          id = String.replace_prefix(uri.path, "/runners/", "")

          case Ecto.UUID.cast(id) do
            {:ok, id} -> detail_path(id, fleet_return(params["return_to"]))
            :error -> nil
          end

        true ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  def return_path(_), do: nil

  defp fleet_return(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.host == nil && uri.fragment == nil && uri.path == "/runners",
      do: path(URI.decode_query(uri.query || ""))
  end

  defp fleet_return(_), do: nil

  def safe_return(value) when is_binary(value) and byte_size(value) <= 8192 do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.host == nil && uri.fragment == nil do
      cond do
        uri.path == "/runners" ->
          path(URI.decode_query(uri.query || ""))

        is_binary(uri.path) &&
            Regex.match?(
              ~r"\A/(checks|resources)/[a-zA-Z0-9_-]{1,128}(/diagnostics)?\z",
              uri.path
            ) ->
          case inventory_return(URI.decode_query(uri.query || "")["return_to"]) do
            nil -> uri.path
            return_to -> uri.path <> "?" <> URI.encode_query(%{"return_to" => return_to})
          end

        is_binary(uri.path) && String.starts_with?(uri.path, "/coverage") ->
          MondekWeb.CoverageNavigation.return_path(value)

        uri.path == "/monitoring-incidents" ||
            (is_binary(uri.path) && String.starts_with?(uri.path, "/monitoring-incidents/")) ->
          MondekWeb.MonitoringIncidentNavigation.return_path(value)

        true ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  def safe_return(_), do: nil

  defp inventory_return(value) when is_binary(value) and byte_size(value) <= 4096 do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.host == nil && uri.fragment == nil do
      cond do
        uri.path == "/checks" ->
          URI.decode_query(uri.query || "")
          |> Map.delete("return_to")
          |> MondekWeb.CheckNavigation.normalize()
          |> MondekWeb.CheckNavigation.path()

        is_binary(uri.path) && String.starts_with?(uri.path, "/coverage") ->
          MondekWeb.CoverageNavigation.return_path(value)

        is_binary(uri.path) && String.starts_with?(uri.path, "/incidents/") ->
          MondekWeb.InvestigationNavigation.safe_return_path(value)

        is_binary(uri.path) && String.starts_with?(uri.path, "/monitoring-incidents/") ->
          MondekWeb.MonitoringIncidentNavigation.return_path(value)

        true ->
          nil
      end
    end
  end

  defp inventory_return(_), do: nil

  def checks_path(id, return_to, freshness \\ nil),
    do:
      "/checks?" <>
        URI.encode_query(
          Enum.reject(
            %{"runner_id" => id, "return_to" => return_to, "freshness" => freshness},
            fn {_key, value} -> is_nil(value) end
          )
        )
end

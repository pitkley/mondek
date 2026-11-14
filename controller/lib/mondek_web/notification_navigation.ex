# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationNavigation do
  @moduledoc "Canonical bounded notification URLs shared by delivery and incident inspection."
  def filters(params), do: Mondek.NotificationFilters.params(params)

  def path(params \\ %{}),
    do:
      "/notifications" <>
        query(
          filters(params)
          |> Map.reject(fn {key, value} ->
            (key == "notification_status" && value == "unresolved") || value == ""
          end)
        )

  def detail_path(id, return_to \\ nil) do
    return_to = list_return(return_to)
    "/notifications/" <> id <> query(if(return_to, do: %{"return_to" => return_to}, else: %{}))
  end

  def return_path(value) when is_binary(value) and byte_size(value) <= 2048 do
    uri = URI.parse(value)

    if is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.fragment) do
      params = URI.decode_query(uri.query || "")

      case String.split(uri.path || "", "/") do
        ["", "notifications"] ->
          path(params)

        ["", "notifications", id] ->
          case Ecto.UUID.cast(id) do
            {:ok, id} -> detail_path(id, params["return_to"])
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

  defp list_return(value) when is_binary(value) and byte_size(value) <= 1024 do
    uri = URI.parse(value)

    if is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.fragment) and
         uri.path == "/notifications",
       do: path(URI.decode_query(uri.query || ""))
  rescue
    ArgumentError -> nil
  end

  defp list_return(_), do: nil

  defp query(params) when map_size(params) == 0, do: ""
  defp query(params), do: "?" <> URI.encode_query(Enum.sort(params))
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationNavigation do
  @moduledoc "Canonical bounded notification URLs shared by delivery and incident inspection."
  @statuses ~w(unresolved exhausted pending retrying delivering delivered superseded all)

  def filters(params) do
    status = if params["notification_status"] in @statuses, do: params["notification_status"]

    value = params["notification_page"]

    input =
      if is_integer(value) or (is_binary(value) and byte_size(value) <= 10),
        do: to_string(value),
        else: "1"

    page =
      case Integer.parse(input) do
        {number, ""} when number > 1 -> min(number, 100_000)
        _ -> nil
      end

    %{"notification_status" => status, "notification_page" => page}
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  def path(params \\ %{}), do: "/notifications" <> query(filters(params))

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

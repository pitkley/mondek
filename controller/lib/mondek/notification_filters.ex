# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationFilters do
  @moduledoc "Bounded list filters shared by notification queries and their chip picker."
  @choices %{
    "notification_status" => [
      {"unresolved", "Outstanding"},
      {"exhausted", "Exhausted retries"},
      {"pending", "Queued"},
      {"retrying", "Retrying"},
      {"delivering", "In progress"},
      {"delivered", "Receiver accepted"},
      {"superseded", "Superseded"},
      {"all", "Any status"}
    ],
    "notification_event" => [
      {"firing", "Failure"},
      {"update", "Severity change"},
      {"resolved", "Incident ended"}
    ],
    "notification_channel" => [{"email", "Email"}, {"webhook", "Webhook"}],
    "notification_type" => [{"health", "Health incident"}, {"loss", "Monitoring loss"}]
  }
  def fields,
    do: [
      {"notification_status", "Status", "info"},
      {"notification_event", "Event", "pulse"},
      {"notification_channel", "Channel", "send"},
      {"notification_type", "Type", "grid"}
    ]

  def choices(field), do: Map.get(@choices, field, [])

  def params(params) when is_map(params) do
    selected =
      for {field, choices} <- @choices,
          value = params[field],
          List.keymember?(choices, value, 0),
          into: %{},
          do: {field, value}

    selected = Map.put_new(selected, "notification_status", "unresolved")

    selected =
      case params["search"] do
        value when is_binary(value) and byte_size(value) <= 800 ->
          if String.valid?(value),
            do:
              Map.put(selected, "search", String.slice(String.replace(value, <<0>>, ""), 0, 200)),
            else: selected

        _ ->
          selected
      end

    selected = Map.reject(selected, fn {key, value} -> key == "search" && value == "" end)

    case integer(params["notification_page"]) do
      page when page > 1 -> Map.put(selected, "notification_page", min(page, 100_000))
      _ -> selected
    end
  end

  def params(_), do: params(%{})
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> 1
    end
  end

  defp integer(_), do: 1
end

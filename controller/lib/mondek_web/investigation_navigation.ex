# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationNavigation do
  @moduledoc "Local workflow links and human-readable return labels."

  def filter_path(:configuration, filters) do
    query = filters |> Enum.reject(fn {_, value} -> value in [nil, ""] end) |> URI.encode_query()
    "/configuration" <> if(query == "", do: "", else: "?" <> query)
  end

  def detail_path(path, nil), do: path

  def detail_path(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  def return_label(nil, fallback), do: fallback

  def return_label(path, fallback) do
    case URI.parse(path).path do
      "/" ->
        "Back to overview"

      "/checks" ->
        "Back to checks"

      "/incidents" ->
        "Back to incidents"

      "/configuration" ->
        "Back to scheduled checks"

      "/notifications" ->
        "Back to notifications"

      "/runners" ->
        "Back to runners"

      "/coverage" ->
        "Back to coverage"

      "/maintenance" ->
        "Back to maintenance"

      path when is_binary(path) ->
        cond do
          String.starts_with?(path, "/results/") -> "Back to result"
          String.starts_with?(path, "/checks/") -> "Back to result"
          String.starts_with?(path, "/executions/") -> "Back to scheduled execution"
          String.starts_with?(path, "/incidents/") -> "Back to incident"
          String.starts_with?(path, "/runners/") -> "Back to runner"
          String.starts_with?(path, "/notifications/") -> "Back to notification"
          String.starts_with?(path, ["/coverage/", "/expected/"]) -> "Back to coverage"
          String.starts_with?(path, "/configuration/") -> "Back to configuration"
          String.starts_with?(path, "/maintenance/") -> "Back to maintenance"
          true -> fallback
        end

      _ ->
        fallback
    end
  end
end

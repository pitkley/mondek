# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewNavigation do
  @moduledoc "Local preview list and result URLs shared by page owners and detail components."

  def path(filters, action \\ :index, id \\ nil, full \\ false) do
    base =
      case action do
        :checks ->
          "/checks"

        :checks_result ->
          "/checks/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :checks_result_page ->
          "/checks/" <> URI.encode(id || "", &URI.char_unreserved?/1) <> "/full"

        :result ->
          "/results/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :result_page ->
          "/results/" <> URI.encode(id || "", &URI.char_unreserved?/1) <> "/full"

        :coverage ->
          "/coverage"

        :coverage_diagnostic ->
          "/coverage/diagnostics/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :coverage_result ->
          "/coverage/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :expected ->
          "/expected/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        _ ->
          "/"
      end

    query =
      filters |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new() |> URI.encode_query()

    base = if full, do: base <> "/full", else: base
    if query == "", do: base, else: base <> "?" <> query
  end
end

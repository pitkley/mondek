# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewNavigation do
  @moduledoc "Local preview list and result URLs shared by page owners and detail components."

  def path(filters, action \\ :index, id \\ nil, full \\ false) do
    base =
      case action do
        :checks ->
          "/next/checks"

        :checks_result ->
          "/next/checks/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :checks_result_page ->
          "/next/checks/" <> URI.encode(id || "", &URI.char_unreserved?/1) <> "/full"

        :result ->
          "/next/results/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :result_page ->
          "/next/results/" <> URI.encode(id || "", &URI.char_unreserved?/1) <> "/full"

        :coverage ->
          "/next/coverage"

        :coverage_diagnostic ->
          "/next/coverage/diagnostics/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :coverage_result ->
          "/next/coverage/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        :expected ->
          "/next/expected/" <> URI.encode(id || "", &URI.char_unreserved?/1)

        _ ->
          "/next"
      end

    query =
      filters |> Enum.reject(fn {_, v} -> v in [nil, ""] end) |> Map.new() |> URI.encode_query()

    base = if full, do: base <> "/full", else: base
    if query == "", do: base, else: base <> "?" <> query
  end
end

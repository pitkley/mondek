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
        value in [nil, ""] || (key in ~w(contact collection) && value == "all") ||
          (key == "page" && value in [1, "1"]) ||
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

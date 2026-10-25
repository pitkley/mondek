# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.TextContractTest do
  use ExUnit.Case, async: true
  import Mondek.Fixtures

  test "shared summary corpus matches independent controller admission" do
    cases =
      Path.expand("../../../contracts/v1/result-text.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    for example <- cases do
      value =
        cond do
          Map.has_key?(example, "utf8_bytes") ->
            :erlang.list_to_binary(example["utf8_bytes"])

          is_binary(example["value"]) ->
            String.duplicate(example["value"], example["repeat"] || 1)

          true ->
            example["value"]
        end

      payload = report()
      [result] = payload["results"]
      payload = Map.put(payload, "results", [Map.put(result, "summary", value)])
      assert Mondek.Protocol.report(payload, at()) == :ok == example["valid"], example["name"]
    end
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationBoundsTest do
  use Mondek.DataCase, async: false
  @moduletag empty_source_fixture: true
  alias Mondek.{Configuration, Runner}

  test "integer literals retain exact supported values and reject oversized schema metadata" do
    supported = Integer.pow(10, 4096) - 1
    oversized = supported + 1

    for type <- ["integer", "number"], sign <- [1, -1] do
      schema = %{"fields" => %{"limit" => %{"type" => type}}}
      assert :ok = Mondek.Parameters.validate(schema, %{"limit" => sign * supported})

      assert {:error, message} =
               Mondek.Parameters.validate(schema, %{"limit" => sign * oversized})

      assert message =~ "4096"
      assert Mondek.Protocol.json_text?(%{"literal" => sign * supported})
      refute Mondek.Protocol.json_text?(%{"literal" => sign * oversized})
    end

    for field <- [
          %{"type" => "integer", "maximum" => oversized},
          %{"type" => "integer", "minimum" => -oversized},
          %{"type" => "integer", "choices" => [1, oversized]},
          %{"type" => "integer", "metadata" => %{"numeric_literal" => oversized}}
        ] do
      assert {:error, message} =
               Mondek.Parameters.validate(%{"fields" => %{"limit" => field}}, %{"limit" => 1})

      assert message =~ "4096"
    end

    p = inventory([check("metadata", "source", 1)])
    poisoned = put_in(p, ["checks", Access.at(0), "outputs", Access.at(0), "extra"], oversized)
    assert {:error, {:invalid, _}} = Monitoring.inventory(poisoned, at())
    refute Repo.exists?(from a in Assignment, where: a.source_id == "bounds")
  end

  test "complete parameter JSON is bounded across ASCII and Unicode encodings" do
    definition = check("editable", "ui", 9)
    assert {:ok, _} = Monitoring.inventory(inventory([definition]), at())
    a = Repo.get_by!(Assignment, source_key: "editable")
    accepted = Map.new(a.params, fn {key, _} -> {key, String.duplicate("x", 1800)} end)
    assert {:ok, saved} = Monitoring.save_assignment(a.id, 1, accepted)

    for value <- [String.duplicate("x", 2000), String.duplicate("€", 600)] do
      oversized = Map.new(a.params, fn {key, _} -> {key, value} end)

      assert {:error, {:invalid, message}} =
               Monitoring.save_assignment(a.id, saved["revision"], oversized)

      assert message =~ "16 KiB"
      assert Repo.get!(Assignment, a.id).params == accepted

      assert Repo.aggregate(from(c in Configuration, where: c.assignment_id == ^a.id), :count) ==
               2
    end

    unicode = Map.new(a.params, fn {key, _} -> {key, String.duplicate("€", 600)} end)
    assert byte_size(Jason.encode!(unicode)) < 16_384
    assert byte_size(Jason.encode!(unicode, escape: :unicode_safe)) > 16_384
  end

  test "disjoint saves serialize their shared runner budget and roll back the losing configuration" do
    definitions =
      for n <- 1..290, do: check("check-#{n}", if(n <= 2, do: "ui", else: "source"), 7)

    p = inventory(definitions)
    assert {:ok, _} = Monitoring.inventory(p, at())
    runner_id = p["installation_id"]
    rows = Repo.all(from a in Assignment, where: a.runner_id == ^runner_id)
    budget = 4_194_304 - 10_000 - control_size(rows)
    assert budget > 0 and budget <= 288 * 7 * 2048

    {expanded, remaining} =
      Enum.map_reduce(definitions, budget, fn definition, available ->
        if definition["params_owner"] == "source" do
          {entries, rest} =
            Enum.map_reduce(Enum.sort(Map.keys(definition["params"])), available, fn key, left ->
              size = min(left, 2048)
              {{key, String.duplicate("x", size)}, left - size}
            end)

          {Map.put(definition, "params", Map.new(entries)), rest}
        else
          {definition, available}
        end
      end)

    assert remaining == 0

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "checks" => expanded}),
               at()
             )

    rows = Repo.all(from a in Assignment, where: a.runner_id == ^runner_id)
    assert control_size(rows) == 4_194_304 - 10_000
    editable = Enum.filter(rows, &(&1.params_owner == "ui"))
    before_count = Repo.aggregate(Configuration, :count)

    {:ok, tasks} =
      Repo.transaction(fn ->
        Repo.one!(from r in Runner, where: r.id == ^runner_id, lock: "FOR UPDATE")

        tasks =
          for a <- editable do
            Task.async(fn ->
              params = Map.new(a.params, fn {key, _} -> {key, String.duplicate("y", 1000)} end)
              Monitoring.save_assignment(a.id, a.revision, params)
            end)
          end

        # Both saves must wait at the shared runner fence before writing.
        for task <- tasks, do: assert(is_nil(Task.yield(task, 100)))
        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert [{:error, {:invalid, message}}] = Enum.filter(results, &match?({:error, _}, &1))
    assert message =~ "4 MiB"
    assert Repo.aggregate(Configuration, :count) == before_count + 1
    rows = Repo.all(from a in Assignment, where: a.runner_id == ^runner_id)
    assert control_size(rows) == 4_194_304 - 3000
    assert Enum.count(rows, &(&1.params_owner == "ui" and &1.revision == 1)) == 1

    # A different check can consume the remaining budget after a valid preview.
    # Commit must recheck the shared budget and roll back every attempted write.
    winner = Enum.find(rows, &(&1.params_owner == "ui" and &1.revision == 2))
    loser = Enum.find(rows, &(&1.params_owner == "ui" and &1.revision == 1))
    selection = [%{"id" => loser.id, "revision" => loser.revision}]
    proposed = Map.new(loser.params, fn {key, _} -> {key, String.duplicate("z", 300)} end)
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection)
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], proposed)
    enlarged = Map.new(winner.params, fn {key, _} -> {key, String.duplicate("y", 1200)} end)
    assert {:ok, _} = Monitoring.save_assignment(winner.id, winner.revision, enlarged)
    count = Repo.aggregate(Configuration, :count)

    assert {:error, {:invalid, message}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], proposed)

    assert message =~ "4 MiB"
    assert Repo.aggregate(Configuration, :count) == count
    assert Repo.get!(Assignment, loser.id).params == loser.params
    assert Repo.get!(Assignment, loser.id).revision == loser.revision
  end

  defp control_size(rows) do
    %{
      "version" => 1,
      "assignments_authoritative" => true,
      "assignments" => Enum.map(rows, &Monitoring.wire/1),
      "authorized" => Map.new(rows, &{&1.id, &1.desired_generation})
    }
    |> Jason.encode!()
    |> byte_size()
  end

  defp inventory(checks) do
    control()
    |> Map.merge(%{
      "runner_label" => "Bounded runner",
      "source_id" => "bounds",
      "source_revision" => String.duplicate("a", 64),
      "inventory_revision" => 1,
      "complete" => true,
      "checks" => checks
    })
  end

  defp check(key, owner, count) do
    fields = Map.new(1..count, &{"p#{&1}", %{"type" => "string", "max_length" => 2048}})

    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => owner,
      "parameter_contract" => if(owner == "ui", do: "string-settings"),
      "parameter_schema" => %{"fields" => fields},
      "params" => Map.new(fields, fn {key, _} -> {key, ""} end),
      "interval_seconds" => 60,
      "timeout_seconds" => 2,
      "freshness_seconds" => 120,
      "outputs" => [
        %{
          "key" => "value",
          "label" => key,
          "target" => %{"key" => key, "kind" => "host", "label" => key}
        }
      ]
    }
  end
end

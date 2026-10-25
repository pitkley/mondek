# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NumericParametersTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Configuration, Parameters, SourceInventory}

  @binary_integer 99_999_999_999_999_991_611_392
  @wire_integer 100_000_000_000_000_000_000_000
  @wire_float 1.0e23

  test "bounds, choices and comparisons use the exact JSON decimal retained by PostgreSQL" do
    assert postgres_json(%{"value" => @wire_float})["value"] === @wire_integer

    for {field, value} <- [
          {%{"type" => "number", "maximum" => @binary_integer}, @wire_float},
          {%{"type" => "number", "minimum" => -@binary_integer}, -@wire_float},
          {%{"type" => "number", "choices" => [@binary_integer]}, @wire_float}
        ] do
      assert {:error, _} = Parameters.validate(schema(field), %{"limit" => value})
      assert {:error, _} = Parameters.validate(postgres_json(schema(field)), %{"limit" => value})
    end

    refute Parameters.schema?(
             schema(%{
               "type" => "number",
               "minimum" => @wire_float,
               "maximum" => @binary_integer
             })
           )

    pair = %{
      "fields" => %{"left" => %{"type" => "number"}, "right" => %{"type" => "number"}},
      "comparisons" => [%{"left" => "left", "op" => "lt", "right" => "right"}]
    }

    assert :ok = Parameters.validate(pair, %{"left" => @binary_integer, "right" => @wire_float})

    assert {:error, _} =
             Parameters.validate(pair, %{"left" => @wire_float, "right" => @binary_integer})

    assert {:error, _} =
             Parameters.validate(put_in(pair, ["comparisons", Access.at(0), "op"], "lte"), %{
               "left" => @wire_float,
               "right" => @binary_integer
             })

    largest = Integer.pow(10, 4096) - 1
    assert :ok = Parameters.validate(pair, %{"left" => largest - 1, "right" => largest})
    assert {:error, _} = Parameters.validate(pair, %{"left" => largest, "right" => largest - 1})

    assert :ok =
             Parameters.validate(
               schema(%{"type" => "number", "minimum" => 0.1, "maximum" => 0.2}),
               %{"limit" => 0.15}
             )

    refute Parameters.same_json?(%{"limit" => @wire_float}, %{"limit" => @binary_integer})
    assert Parameters.same_json?(%{"limit" => @wire_float}, %{"limit" => @wire_integer})
    assert Parameters.same_json?([0.0, 1.0, 0.25], [0, 1, 0.25])
    refute Parameters.same_json?([true, "1"], [1, 1])
  end

  test "single saves distinguish adjacent large values and replay equivalent decimal proposals as no-ops" do
    publish([check("editable", @binary_integer)])
    original = assignment("editable")
    assert {:ok, saved} = Monitoring.save_assignment(original.id, 1, %{"limit" => @wire_float})
    assert saved["revision"] == 2
    persisted = Repo.get!(Assignment, original.id)
    assert persisted.params["limit"] === @wire_integer

    assert Repo.get_by!(Configuration, assignment_id: original.id, generation: 2).params["limit"] ===
             @wire_integer

    for value <- [@wire_float, @wire_integer] do
      assert {:ok, same} = Monitoring.save_assignment(original.id, 2, %{"limit" => value})
      assert same["revision"] == 2
    end

    assert Repo.aggregate(
             from(c in Configuration, where: c.assignment_id == ^original.id),
             :count
           ) == 2

    assert {:ok, distinct} =
             Monitoring.save_assignment(original.id, 2, %{"limit" => @wire_integer + 1})

    assert distinct["revision"] == 3

    bounded =
      check("bounded", @binary_integer)
      |> put_in(["parameter_schema", "fields", "limit", "maximum"], @binary_integer)

    publish([check("editable", @binary_integer), bounded], 2)
    row = assignment("bounded")

    assert {:error, {:invalid, _}} =
             Monitoring.save_assignment(row.id, 1, %{"limit" => @wire_float})

    assert Repo.get!(Assignment, row.id).revision == 1
  end

  test "expanded numeric parameters remain inside the complete saved JSON budget" do
    fields =
      Map.new(
        for n <- 1..32, do: {"value_#{n}", %{"type" => if(n <= 8, do: "number", else: "string")}}
      )

    proposed =
      Map.new(
        for n <- 1..32,
            do:
              {"value_#{n}",
               if(n <= 8, do: 1.7976931348623157e308, else: String.duplicate("x", 620))}
      )

    schema = %{"fields" => fields}
    assert byte_size(Jason.encode!(proposed)) < 16_384
    assert byte_size(Jason.encode!(Parameters.normalized_json(proposed))) > 16_384
    assert {:error, reason} = Parameters.validate(schema, proposed)
    assert reason =~ "16 KiB"

    initial = Map.new(for n <- 1..32, do: {"value_#{n}", if(n <= 8, do: 1, else: "initial")})

    publish([
      check("bounded-json", 1)
      |> Map.put("parameter_schema", schema)
      |> Map.put("params", initial)
    ])

    row = assignment("bounded-json")
    assert {:error, {:invalid, _}} = Monitoring.save_assignment(row.id, 1, proposed)

    assert {:ok, prepared} =
             Monitoring.prepare_bulk_configuration([%{"id" => row.id, "revision" => 1}])

    assert {:error, {:invalid, _}} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], proposed)

    assert Repo.get!(Assignment, row.id).params == initial

    assert Repo.aggregate(from(c in Configuration, where: c.assignment_id == ^row.id), :count) ==
             1

    smaller =
      Map.new(proposed, fn {key, value} ->
        {key, if(is_binary(value), do: String.duplicate("x", 500), else: value)}
      end)

    assert {:ok, _} = Monitoring.save_assignment(row.id, 1, smaller)
    saved = Repo.get!(Assignment, row.id).params
    assert byte_size(Jason.encode!(saved)) <= 16_384
    assert :ok = Parameters.validate(schema, saved)
  end

  test "bulk review counts exact changes and binds the reviewed decimal values" do
    publish([check("first", @binary_integer), check("second", @wire_integer)])

    selection =
      for key <- ["first", "second"],
          a = assignment(key),
          do: %{"id" => a.id, "revision" => a.revision}

    assert {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection)
    assert prepared["mixed_fields"] == ["limit"]

    assert {:ok, preview} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], %{
               "limit" => @wire_float
             })

    assert preview["changed_count"] == 1
    assert preview["unchanged_count"] == 1
    assert Enum.count(preview["rows"], & &1["changed"]) == 1

    assert {:error, :review_changed} =
             Monitoring.apply_bulk_configuration(preview["review_token"], %{
               "limit" => @binary_integer
             })

    assert {:error, :review_changed} =
             Monitoring.apply_bulk_configuration(preview["review_token"], %{
               "limit" => @wire_integer + 1
             })

    assert {:ok, result} =
             Monitoring.apply_bulk_configuration(preview["review_token"], %{
               "limit" => @wire_integer
             })

    assert result["changed_count"] == 1
    assert assignment("first").params["limit"] === @wire_integer
    assert assignment("second").revision == 1
  end

  test "bulk preview budgets the same expanded numeric control response as save" do
    fields =
      Map.new(
        for n <- 1..32, do: {"value_#{n}", %{"type" => if(n <= 8, do: "number", else: "string")}}
      )

    initial = Map.new(for n <- 1..32, do: {"value_#{n}", if(n <= 8, do: 1, else: "initial")})

    proposed =
      Map.new(
        for n <- 1..32,
            do:
              {"value_#{n}",
               if(n <= 8, do: 1.7976931348623157e308, else: String.duplicate("x", 500))}
      )

    canonical = Parameters.normalized_json(proposed)
    assert :ok = Parameters.validate(%{"fields" => fields}, proposed)

    publish(
      for n <- 1..300,
          do:
            check("control-#{n}", 1)
            |> Map.put("parameter_schema", %{"fields" => fields})
            |> Map.put("params", initial)
    )

    rows =
      Repo.all(from a in Assignment, where: a.source_id == "numeric-parameters", order_by: a.id)

    available = 4_194_304 - control_size(rows)
    delta = byte_size(Jason.encode!(canonical)) - byte_size(Jason.encode!(initial))
    selected = Enum.take(rows, div(available, delta) + 1)
    ids = MapSet.new(selected, & &1.id)

    raw_rows =
      Enum.map(
        rows,
        &if(MapSet.member?(ids, &1.id),
          do: %{&1 | params: proposed, desired_generation: 2},
          else: &1
        )
      )

    saved_rows =
      Enum.map(
        rows,
        &if(MapSet.member?(ids, &1.id),
          do: %{&1 | params: canonical, desired_generation: 2},
          else: &1
        )
      )

    assert control_size(raw_rows) <= 4_194_304
    assert control_size(saved_rows) > 4_194_304
    selection = Enum.map(selected, &%{"id" => &1.id, "revision" => 1})
    assert {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection)

    assert {:error, {:invalid, reason}} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], proposed)

    assert reason =~ "4 MiB"

    assert Enum.all?(
             Repo.all(from a in Assignment, where: a.source_id == "numeric-parameters"),
             &(&1.revision == 1)
           )
  end

  test "schema identity survives real JSONB round trips and inventory equality remains exact" do
    field = %{
      "type" => "number",
      "minimum" => 0.0,
      "maximum" => @wire_float,
      "choices" => [1.0, 0.25, @wire_float]
    }

    source_schema = schema(field)
    persisted_schema = postgres_json(source_schema)
    assert persisted_schema["fields"]["limit"]["maximum"] === @wire_integer

    assert Parameters.normalized_schema(source_schema) ===
             Parameters.normalized_schema(persisted_schema)

    assert Parameters.schema_fingerprint(source_schema) ==
             Parameters.schema_fingerprint(persisted_schema)

    integer_schema = schema(%{"type" => "number", "maximum" => @wire_integer})

    old_hash =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Map.put(integer_schema, "comparisons", []), [:deterministic])
      )
      |> Base.encode16(case: :lower)

    assert Parameters.schema_fingerprint(integer_schema) == old_hash

    refute Parameters.schema_fingerprint(integer_schema) ==
             Parameters.schema_fingerprint(
               put_in(integer_schema, ["fields", "limit", "maximum"], @wire_integer + 1)
             )

    definition =
      check("source", @wire_float)
      |> Map.put("params_owner", "source")
      |> Map.delete("parameter_contract")
      |> Map.put("parameter_schema", source_schema)

    payload = publish([definition])
    assert {:ok, _} = Monitoring.inventory(payload, at())
    assert assignment("source").revision == 1

    assert {:error, :inventory_conflict} =
             Monitoring.inventory(
               put_in(payload, ["checks", Access.at(0), "params", "limit"], 1),
               at()
             )

    # A source-owned value and schema which differ by one exact integer are not
    # swallowed by native float/integer equality during reconciliation.
    changed =
      definition
      |> put_in(["params", "limit"], @wire_integer + 1)
      |> put_in(["parameter_schema", "fields", "limit"], %{
        "type" => "number",
        "maximum" => @wire_integer + 1
      })

    publish([changed], 2)
    assert assignment("source").revision == 2
    assert assignment("source").params["limit"] === @wire_integer + 1
    assert Repo.one!(SourceInventory).revision == 2

    publish([put_in(changed, ["params", "limit"], @binary_integer)], 3)
    publish([put_in(changed, ["params", "limit"], @wire_float)], 4)
    assert assignment("source").revision == 4
    assert assignment("source").params["limit"] === @wire_integer

    integer_defaults =
      check("integer", 1.0) |> put_in(["parameter_schema", "fields", "limit", "type"], "integer")

    assert {:error, {:invalid, _}} =
             Monitoring.inventory(
               Map.merge(payload, %{"inventory_revision" => 5, "checks" => [integer_defaults]}),
               at()
             )

    assert Repo.one!(SourceInventory).revision == 4
  end

  defp postgres_json(value),
    do: Repo.query!("SELECT $1::text::jsonb", [Jason.encode!(value)]).rows |> hd() |> hd()

  defp schema(field), do: %{"fields" => %{"limit" => field}}

  defp control_size(rows) do
    byte_size(
      Jason.encode!(%{
        "version" => 1,
        "assignments_authoritative" => true,
        "assignments" => Enum.map(rows, &Monitoring.wire/1),
        "authorized" => Map.new(rows, &{&1.id, &1.desired_generation})
      })
    )
  end

  defp assignment(key),
    do: Repo.get_by!(Assignment, source_id: "numeric-parameters", source_key: key)

  defp publish(checks, revision \\ 1) do
    payload =
      control()
      |> Map.merge(%{
        "runner_label" => "Numeric parameter test",
        "source_id" => "numeric-parameters",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => revision,
        "complete" => true,
        "checks" => checks
      })

    assert {:ok, _} = Monitoring.inventory(payload, at())
    payload
  end

  defp check(key, value) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => "ui",
      "parameter_contract" => "numeric.v1",
      "parameter_schema" =>
        schema(%{"type" => "number", "minimum" => 0, "maximum" => 2 * @wire_integer}),
      "params" => %{"limit" => value},
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12,
      "outputs" => [
        %{
          "key" => "value",
          "label" => key,
          "target" => %{"key" => key, "kind" => "service", "label" => key}
        }
      ]
    }
  end
end

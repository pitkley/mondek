# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.BulkConfigurationTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Configuration, Runner}

  test "mixed values require a complete proposal and one atomic save preserves no-ops" do
    publish([check("first", 10), check("second", 20)])
    rows = assignments()
    assert {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(rows))
    assert prepared["common_params"] == %{"enabled" => true}
    assert prepared["mixed_fields"] == ["limit"]

    assert {:error, {:invalid, _}} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], %{"limit" => 20})

    params = %{"limit" => 20, "enabled" => true}

    assert {:ok, preview} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)

    assert preview["changed_count"] == 1 and preview["unchanged_count"] == 1
    assert preview["affected_results"] == 1

    # Ordinary progress must not invalidate the values and definitions reviewed.
    connect(%{"prepared" => Map.new(rows, &{&1.id, 1}), "active" => Map.new(rows, &{&1.id, 1})})
    before_count = Repo.aggregate(Configuration, :count)
    assert {:ok, saved} = Monitoring.apply_bulk_configuration(preview["review_token"], params)
    assert saved["changed_count"] == 1 and saved["unchanged_count"] == 1
    assert Repo.aggregate(Configuration, :count) == before_count + 1
    assert Enum.all?(assignments(), &(&1.params == params))

    assert {:error, {:stale, _}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], params)

    assert {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(assignments()))

    assert {:ok, preview} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)

    assert {:ok, %{"changed_count" => 0}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], params)

    assert Repo.aggregate(Configuration, :count) == before_count + 1
  end

  test "review purpose, exact proposed values and expiry bind the confirmation" do
    publish([check("first")])
    params = %{"limit" => 30, "enabled" => true}
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(assignments()))

    assert {:error, :invalid_review} =
             Monitoring.apply_bulk_configuration(prepared["prepare_token"], params)

    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)

    assert {:error, :review_changed} =
             Monitoring.apply_bulk_configuration(
               preview["review_token"],
               Map.put(params, "limit", 40)
             )

    {:ok, data} =
      Phoenix.Token.verify(
        MondekWeb.Endpoint,
        "bulk-configuration/review",
        preview["review_token"],
        max_age: 900
      )

    expired =
      Phoenix.Token.sign(MondekWeb.Endpoint, "bulk-configuration/review", data,
        signed_at: System.system_time(:second) - 901
      )

    assert {:error, :review_expired} = Monitoring.apply_bulk_configuration(expired, params)
    assert hd(assignments()).revision == 1
  end

  test "a stale selection or source contract change rejects the whole proposal" do
    p = publish([check("first"), check("second")])
    rows = assignments()
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(rows))
    params = %{"limit" => 40, "enabled" => true}
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)
    first = hd(rows)

    assert {:ok, _} =
             Monitoring.save_assignment(first.id, first.revision, %{
               "limit" => 35,
               "enabled" => true
             })

    count = Repo.aggregate(Configuration, :count)

    assert {:error, {:stale, [id]}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], params)

    assert id == first.id
    assert Repo.aggregate(Configuration, :count) == count
    assert Enum.find(assignments(), &(&1.id != first.id)).params["limit"] == 80
    assert {:error, {:stale, _}} = Monitoring.prepare_bulk_configuration(selection(rows))

    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(assignments()))

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(0), "parameter_contract"], "other-meaning")

    assert {:ok, _} = Monitoring.inventory(changed, at())

    assert {:error, {:stale, _}} =
             Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)
  end

  test "equal field shapes never imply shared meaning and unknown metadata stays exact" do
    p = publish([check("first"), Map.put(check("second"), "parameter_contract", "other-meaning")])

    assert {:error, {:invalid, _}} =
             Monitoring.prepare_bulk_configuration(selection(assignments()))

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> put_in(["checks", Access.at(1), "parameter_contract"], "thresholds")
      |> put_in(
        ["checks", Access.at(1), "parameter_schema", "fields", "limit", "unit"],
        "seconds"
      )

    assert {:error, {:invalid, _}} = Monitoring.inventory(changed, at())

    changed =
      changed
      |> put_in(
        ["checks", Access.at(1), "parameter_schema", "fields", "limit", "unit"],
        check("second")["parameter_schema"]["fields"]["limit"]["unit"]
      )
      |> put_in(
        ["checks", Access.at(1), "parameter_schema", "fields", "limit", "label"],
        "Different reviewed presentation"
      )

    assert {:ok, _} = Monitoring.inventory(changed, at())

    assert {:error, {:invalid, _}} =
             Monitoring.prepare_bulk_configuration(selection(assignments()))

    for {contract, owner, schema} <- [
          {"bad\n", "ui", check("x")["parameter_schema"]},
          {"thresholds", "source", check("x")["parameter_schema"]},
          {"thresholds", "ui", %{"fields" => %{}}}
        ] do
      candidate =
        check("invalid")
        |> Map.merge(%{
          "parameter_contract" => contract,
          "params_owner" => owner,
          "parameter_schema" => schema
        })

      candidate =
        if schema == %{"fields" => %{}}, do: Map.put(candidate, "params", %{}), else: candidate

      assert {:error, {:invalid, _}} =
               Monitoring.inventory(
                 Map.merge(p, %{"inventory_revision" => 3, "checks" => [candidate]}),
                 at()
               )
    end
  end

  test "overlapping concurrent reviews serialize and one stale batch rolls back entirely" do
    publish([check("first"), check("second"), check("third")])
    [first, second, third] = assignments()
    params = [%{"limit" => 20, "enabled" => true}, %{"limit" => 30, "enabled" => true}]
    batches = [[first, second], [second, third]]

    previews =
      for {rows, proposed} <- Enum.zip(batches, params) do
        {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(rows))

        {:ok, preview} =
          Monitoring.preview_bulk_configuration(prepared["prepare_token"], proposed)

        {preview, proposed}
      end

    before_count = Repo.aggregate(Configuration, :count)

    {:ok, tasks} =
      Repo.transaction(fn ->
        Repo.one!(from r in Runner, where: r.id == ^first.runner_id, lock: "FOR UPDATE")

        tasks =
          for {preview, proposed} <- previews,
              do:
                Task.async(fn ->
                  Monitoring.apply_bulk_configuration(preview["review_token"], proposed)
                end)

        for task <- tasks, do: assert(is_nil(Task.yield(task, 100)))
        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:stale, _}}, &1)) == 1
    assert Repo.aggregate(Configuration, :count) == before_count + 2
    assert Enum.count(assignments(), &(&1.revision == 2)) == 2
    assert Enum.count(assignments(), &(&1.revision == 1)) == 1
  end

  test "one contract spans runners but retirement and another source cannot silently change its scope" do
    publish([check("first")])

    second =
      publish([check("second")], %{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate()
      })

    params = %{"limit" => 70, "enabled" => true}
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(assignments()))
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)

    assert {:ok, %{"changed_count" => 2}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], params)

    assert Enum.all?(assignments(), &(&1.params == params))

    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(assignments()))
    next = Map.put(params, "limit", 60)
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], next)

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(second, %{"inventory_revision" => 2, "checks" => []}),
               at()
             )

    assert {:error, {:stale, _}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], next)

    assert Enum.all?(assignments(), &(&1.params == params))

    publish([check("other")], %{"source_id" => "another-source"})

    active =
      Repo.all(
        from a in Assignment, where: not is_nil(a.parameter_contract) and is_nil(a.retired_at)
      )

    assert {:error, {:invalid, _}} = Monitoring.prepare_bulk_configuration(selection(active))
  end

  test "saved progress follows exact target generations and reports superseded checks" do
    p = publish([check("first"), check("second")])
    rows = assignments()
    params = %{"limit" => 25, "enabled" => true}
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection(rows))
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], params)
    {:ok, saved} = Monitoring.apply_bulk_configuration(preview["review_token"], params)
    {:ok, status} = Monitoring.bulk_configuration_status(saved["receipts"])
    assert status["counts"]["pending"] == 2

    first = Repo.get!(Assignment, hd(rows).id)
    Monitoring.save_assignment(first.id, first.revision, Map.put(params, "limit", 26))
    second = Repo.get!(Assignment, List.last(rows).id)
    Monitoring.change(second, %{observed_generation: second.desired_generation})
    {:ok, status} = Monitoring.bulk_configuration_status(saved["receipts"])
    assert status["counts"]["superseded"] == 1 and status["counts"]["measured"] == 1

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "checks" => []}),
               at()
             )

    {:ok, status} = Monitoring.bulk_configuration_status(saved["receipts"])
    assert status["counts"]["retired"] == 2
  end

  test "five hundred selections and tokens are bounded while select-all uses explicit compatibility" do
    p = publish(for n <- 1..500, do: check("item-#{n}"))
    first = hd(assignments())

    filters = %{
      source_id: "bulk-source",
      parameter_contract: "thresholds",
      schema_fingerprint: first.parameter_schema_fingerprint
    }

    {:ok, selected} = Monitoring.select_bulk_configuration(filters)
    assert selected["eligible_count"] == 500 and length(selected["selection"]) == 500
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selected["selection"], 2)
    assert prepared["total"] == 500 and length(prepared["rows"]) == 25 and prepared["page"] == 2
    params = %{"limit" => 75, "enabled" => true}
    {:ok, preview} = Monitoring.preview_bulk_configuration(prepared["prepare_token"], params, 2)

    assert byte_size(
             Jason.encode!(%{"review_token" => preview["review_token"], "params" => params})
           ) < 262_144

    assert byte_size(
             Jason.encode!(%{
               "selection" => selected["selection"],
               "prepare_token" => prepared["prepare_token"],
               "review_token" => preview["review_token"],
               "draft" => String.duplicate("x", 16_384)
             })
           ) < 262_144

    assert {:ok, %{"changed_count" => 500, "receipts" => receipts}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], params)

    assert length(receipts) == 500
    assert Enum.all?(assignments(), &(&1.desired_generation == 2))

    publish(for(n <- 1..13, do: check("extra-#{n}")), %{
      "installation_id" => Ecto.UUID.generate(),
      "session_id" => Ecto.UUID.generate()
    })

    assert {:error, {:invalid, message}} = Monitoring.select_bulk_configuration(filters)
    assert message =~ "512"

    {:ok, selected} =
      Monitoring.select_bulk_configuration(Map.put(filters, :runner_id, p["installation_id"]))

    assert selected["eligible_count"] == 500
  end

  test "actual HTTP uses review-only tokens, exact receipts and the ordinary request cap" do
    publish([check("first"), check("second")])
    pid = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    url = "http://127.0.0.1:#{port}/api/v1/configuration/bulk/"
    assert {200, selected} = post(url, "select", %{"filters" => %{"source_id" => "bulk-source"}})
    assert {422, _} = post(url, "select", %{"filters" => %{"source_id" => "bulk-source\u0000"}})
    assert {200, prepared} = post(url, "prepare", %{"selection" => selected["selection"]})
    params = %{"limit" => 70, "enabled" => true}

    assert {200, preview} =
             post(url, "preview", %{
               "prepare_token" => prepared["prepare_token"],
               "params" => params
             })

    assert {422, %{"code" => "invalid_review"}} =
             post(url, "apply", %{"review_token" => prepared["prepare_token"], "params" => params})

    assert {409, %{"code" => "review_changed"}} =
             post(url, "apply", %{
               "review_token" => preview["review_token"],
               "params" => Map.put(params, "limit", 71)
             })

    assert {200, %{"changed_count" => 2} = saved} =
             post(url, "apply", %{"review_token" => preview["review_token"], "params" => params})

    assert {200, %{"counts" => %{"pending" => 2}}} =
             post(url, "status", %{"receipts" => saved["receipts"]})

    assert {409, %{"code" => "stale_selection", "stale_ids" => ids}} =
             post(url, "apply", %{"review_token" => preview["review_token"], "params" => params})

    assert length(ids) == 2

    assert {413, _} =
             post(url, "prepare", %{
               "selection" => selected["selection"],
               "padding" => String.duplicate("x", 262_144)
             })
  end

  defp post(url, path, body) do
    {:ok, {{_, code, _}, _, data}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> path), [], ~c"application/json", Jason.encode!(body)},
        [timeout: 5000],
        body_format: :binary
      )

    decoded =
      case Jason.decode(data) do
        {:ok, value} -> value
        _ -> %{"error" => data}
      end

    {code, decoded}
  end

  defp assignments,
    do: Repo.all(from a in Assignment, where: a.source_id == "bulk-source", order_by: a.id)

  defp selection(rows), do: Enum.map(rows, &%{"id" => &1.id, "revision" => &1.revision})

  defp publish(checks, overrides \\ %{}) do
    p =
      control()
      |> Map.merge(%{
        "runner_label" => "Bulk runner",
        "source_id" => "bulk-source",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => checks
      })
      |> Map.merge(overrides)

    assert {:ok, _} = Monitoring.inventory(p, at())
    p
  end

  defp check(key, limit \\ 80) do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "params_owner" => "ui",
      "parameter_contract" => "thresholds",
      "parameter_schema" => %{
        "fields" => %{
          "limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100, "unit" => "items"},
          "enabled" => %{"type" => "boolean"}
        }
      },
      "params" => %{"limit" => limit, "enabled" => true},
      "interval_seconds" => 10,
      "timeout_seconds" => 2,
      "freshness_seconds" => 30,
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

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationImportTest do
  use Mondek.DataCase, async: false
  alias Mondek.{ConfigurationRepository, ConfigurationObjects, ConfigurationRule}

  test "Git creates and updates rules while preserving unchanged rules" do
    [row | _] = publish()
    {:ok, before} = ConfigurationRepository.state()

    files =
      before.files
      |> Map.put("rules/shared.json", ConfigurationObjects.json(rule(row, "shared", 60)))

    assert {:ok, _} = push(before, files)
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 60}
    created = Repo.get_by!(ConfigurationRule, repository_key: "shared")
    {:ok, current} = ConfigurationRepository.state()

    assert {:ok, _} =
             push(
               current,
               Map.put(
                 current.files,
                 "rules/other.json",
                 ConfigurationObjects.json(rule(row, "other", 50, -1))
               )
             )

    assert Repo.get!(ConfigurationRule, created.id).revision == created.revision
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 60}
  end

  test "invalid and malformed documents reject atomically without exceptions or rule loss" do
    [row | _] = publish()
    {:ok, before} = ConfigurationRepository.state()
    valid = rule(row, "shared", 60)

    for bad <- [
          Map.put(valid, "key", %{}),
          Map.put(valid, "parameter_schema", []),
          Map.merge(valid, %{"managed_project" => false, "managed_key" => false}),
          Map.put(valid, "params", %{"limit" => 101})
        ] do
      assert {:error, {:invalid, _}} =
               push(
                 before,
                 Map.put(before.files, "rules/shared.json", ConfigurationObjects.json(bad))
               )

      assert {:ok, ^before} = ConfigurationRepository.state()
    end

    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55})
    {:ok, state} = ConfigurationRepository.state()
    path = "exceptions/#{row.id}.json"
    doc = Jason.decode!(state.files[path])

    for scope <- [[], "invalid", 17, nil] do
      assert {:error, {:invalid, _}} =
               push(
                 state,
                 Map.put(
                   state.files,
                   path,
                   ConfigurationObjects.json(Map.put(doc, "scope", scope))
                 )
               )

      assert {:ok, ^state} = ConfigurationRepository.state()
    end
  end

  test "exception edits preserve scope and reject stale pushes" do
    [row | _] = publish()
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55})
    {:ok, state} = ConfigurationRepository.state()
    path = "exceptions/#{row.id}.json"
    doc = Jason.decode!(state.files[path]) |> Map.put("params", %{"limit" => 45})
    files = Map.put(state.files, path, ConfigurationObjects.json(doc))
    assert {:ok, _} = push(state, files)
    assert Repo.get!(Assignment, row.id).instance_exception == %{"limit" => 45}
    assert {:error, {:invalid, message}} = push(state, state.files)
    assert message =~ "fetch and reconcile"
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 45}
  end

  test "deleting an exception cannot expose conflicting rules" do
    [row | _] = rows = publish()

    for member <- rows,
        do:
          assert(
            {:ok, _} = Monitoring.save_assignment(member.id, member.revision, %{"limit" => 55})
          )

    {:ok, state} = ConfigurationRepository.state()

    files =
      state.files
      |> Map.put("rules/one.json", ConfigurationObjects.json(rule(row, "one", 60)))
      |> Map.put("rules/two.json", ConfigurationObjects.json(rule(row, "two", 50)))

    assert {:ok, _} = push(state, files)
    {:ok, state} = ConfigurationRepository.state()

    assert {:error, {:invalid, _}} =
             push(state, Map.delete(state.files, "exceptions/#{row.id}.json"))

    assert Repo.get!(Assignment, row.id).instance_exception == %{"limit" => 55}
    assert {:ok, ^state} = ConfigurationRepository.state()
  end

  test "whitespace-only push preserves effective generations and rule revisions" do
    [row | _] = publish()
    {:ok, state} = ConfigurationRepository.state()

    assert {:ok, _} =
             push(
               state,
               Map.put(
                 state.files,
                 "rules/shared.json",
                 ConfigurationObjects.json(rule(row, "shared", 60))
               )
             )

    row = Repo.get!(Assignment, row.id)
    rule = Repo.get_by!(ConfigurationRule, repository_key: "shared")
    {:ok, state} = ConfigurationRepository.state()

    files =
      Map.new(state.files, fn {path, body} -> {path, Jason.encode!(Jason.decode!(body))} end)

    assert {:ok, _} = push(state, files)
    assert Repo.get!(Assignment, row.id).desired_generation == row.desired_generation
    assert Repo.get!(ConfigurationRule, rule.id).revision == rule.revision
  end

  test "new installation restores portable rules and explicitly remapped exception identities" do
    [old | _] = publish()
    assert {:ok, _} = Monitoring.save_assignment(old.id, old.revision, %{"limit" => 55})
    {:ok, origin} = ConfigurationRepository.state()
    old_path = "exceptions/#{old.id}.json"
    exception = Jason.decode!(origin.files[old_path])
    portable_rule = rule(old, "portable", 60)

    Repo.query!(
      "TRUNCATE configuration_revisions, configuration_git_objects, configuration_repository, runners, assignments, configuration_rules RESTART IDENTITY CASCADE"
    )

    new = Enum.find(publish(), &(&1.source_key == old.source_key))
    {:ok, fresh} = ConfigurationRepository.state()

    files =
      fresh.files
      |> Map.put("rules/portable.json", ConfigurationObjects.json(portable_rule))
      |> Map.put(old_path, ConfigurationObjects.json(exception))

    assert {:error, {:invalid, reason}} = push(fresh, files)
    assert reason =~ "absent"

    mapped =
      put_in(exception, ["scope", "assignment_id"], new.id)
      |> put_in(["scope", "runner_installation_id"], new.runner_id)
      |> put_in(["scope", "check_key"], new.source_key)

    # The operator explicitly selects the equivalent new instance. The resource
    # key and filename remain stable, independently of the new database UUID.
    mapped =
      Map.put(
        mapped,
        "outputs",
        Enum.map(new.outputs, fn output ->
          %{"key" => output["key"], "target" => Map.take(output["target"], ~w(kind key))}
        end)
      )

    assert {:ok, _} = push(fresh, Map.put(files, old_path, ConfigurationObjects.json(mapped)))
    assert Repo.get!(Assignment, new.id).params == %{"limit" => 55}
    assert Repo.get!(Assignment, new.id).configuration_exception_key == old.id
    assert Repo.get_by!(ConfigurationRule, repository_key: "portable")
    {:ok, restored} = ConfigurationRepository.state()
    assert Map.has_key?(restored.files, old_path)
  end

  test "exception keys cannot collide with another source or reserve another instance's id" do
    [row, other] = publish()
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55})
    {:ok, state} = ConfigurationRepository.state()
    path = "exceptions/#{row.id}.json"
    original = Jason.decode!(state.files[path])
    collision = Map.put(original, "key", other.id)

    files =
      state.files
      |> Map.delete(path)
      |> Map.put("exceptions/#{other.id}.json", ConfigurationObjects.json(collision))

    assert {:error, {:invalid, reason}} = push(state, files)
    assert reason =~ "already belongs"
    assert {:ok, ^state} = ConfigurationRepository.state()

    # A key owner outside the selected source must reject cleanly too.
    Monitoring.change(other, %{
      source_id: "other-source",
      configuration_exception_key: "reserved-exception"
    })

    collision = Map.put(original, "key", "reserved-exception")

    files =
      state.files
      |> Map.delete(path)
      |> Map.put("exceptions/reserved-exception.json", ConfigurationObjects.json(collision))

    assert {:error, {:invalid, reason}} = push(state, files)
    assert reason =~ "already belongs"
  end

  test "unchanged source checks do not consume a small edit's atomic impact budget" do
    [row | _] = publish()
    {:ok, state} = ConfigurationRepository.state()

    assert {:ok, _} =
             push(
               state,
               Map.put(
                 state.files,
                 "rules/shared.json",
                 ConfigurationObjects.json(rule(row, "shared", 60))
               )
             )

    # Model a large existing installation without hundreds of real worker sessions.
    # These declarations already match the accepted rule and remain unchanged.
    current = Repo.get!(Assignment, row.id)

    for i <- 1..513 do
      Repo.insert!(%{
        current
        | id: Ecto.UUID.generate(),
          runner_id: nil,
          source_key: "large-#{i}"
      })
    end

    {:ok, state} = ConfigurationRepository.state()
    assert {:ok, _} = push(state, Map.put(state.files, "mondek.json", "{\"version\":1}"))
    {:ok, state} = ConfigurationRepository.state()

    assert {:error, {:invalid, reason}} =
             push(
               state,
               Map.put(
                 state.files,
                 "rules/shared.json",
                 ConfigurationObjects.json(rule(row, "shared", 50))
               )
             )

    assert reason =~ "more than 512"
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 60}

    current = Repo.get!(Assignment, row.id)
    assert {:ok, _} = Monitoring.save_assignment(row.id, current.revision, %{"limit" => 55})
    {:ok, state} = ConfigurationRepository.state()
    path = "exceptions/#{row.id}.json"
    exception = Jason.decode!(state.files[path]) |> Map.put("params", %{"limit" => 45})

    assert {:ok, _} =
             push(state, Map.put(state.files, path, ConfigurationObjects.json(exception)))

    assert Repo.get!(Assignment, row.id).params == %{"limit" => 45}
  end

  defp push(state, files) do
    {head, objects} =
      ConfigurationObjects.commit(files, state.head, "Test configuration", DateTime.utc_now())

    ConfigurationRepository.accept_push(state.head, %{head: head, objects: objects, files: files})
  end

  defp rule(row, key, limit, priority \\ 0) do
    %{
      "key" => key,
      "name" => key,
      "source_id" => row.source_id,
      "parameter_contract" => row.parameter_contract,
      "environment" => nil,
      "target_kind" => nil,
      "target_key" => nil,
      "priority" => priority,
      "enabled" => true,
      "parameter_schema" => Mondek.Parameters.normalized_schema(row.parameter_schema),
      "params" => %{"limit" => limit},
      "managed_project" => nil,
      "managed_key" => nil
    }
  end

  defp publish do
    checks =
      for key <- ["first", "second"] do
        %{
          "key" => key,
          "label" => key,
          "definition_revision" => String.duplicate("b", 64),
          "params_owner" => "ui",
          "parameter_contract" => "capacity.v1",
          "parameter_schema" => %{
            "fields" => %{"limit" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
          },
          "params" => %{"limit" => 80},
          "interval_seconds" => 10,
          "timeout_seconds" => 2,
          "freshness_seconds" => 30,
          "outputs" => [
            %{
              "key" => "health",
              "label" => key,
              "target" => %{"key" => key, "kind" => "host", "label" => key}
            }
          ]
        }
      end

    payload =
      control()
      |> Map.merge(%{
        "runner_label" => "Journal runner",
        "source_id" => "journal-tests",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => checks
      })

    assert {:ok, _} = Monitoring.inventory(payload, at())
    Repo.all(from a in Assignment, where: a.source_id == "journal-tests", order_by: a.id)
  end
end

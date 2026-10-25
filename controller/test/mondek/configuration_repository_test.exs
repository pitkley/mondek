# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationRepositoryTest do
  use Mondek.DataCase, async: false
  alias Mondek.{ConfigurationRepository, ConfigurationObjects}

  test "source defaults do not create exceptions and repeated fixture setup is a no-op" do
    {:ok, state} = ConfigurationRepository.state()
    assert Map.keys(state.files) == ["mondek.json"]
    refute Enum.any?(ConfigurationRepository.history(), &(&1.channel == "legacy"))
    assert {:ok, _} = Mondek.Fixtures.seed_source_checks()
    assert {:ok, unchanged} = ConfigurationRepository.state()
    assert unchanged.head == state.head
  end

  test "UI save records its complete state and immutable Git objects atomically" do
    {:ok, before} = ConfigurationRepository.state()
    row = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    params = Map.put(row.params, "warn_percent", 75)
    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision, params)
    {:ok, after_save} = ConfigurationRepository.state()
    refute after_save.head == before.head

    assert Jason.decode!(after_save.files["exceptions/10000000-0000-4000-8000-000000000001.json"])[
             "params"
           ] == params

    assert %{channel: "ui", parent: parent} = hd(ConfigurationRepository.history())
    assert parent == before.head

    for {oid, {kind, body}} <- ConfigurationRepository.objects() do
      assert ConfigurationObjects.oid(kind, body) == oid
    end

    assert {:ok, _} = Monitoring.save_assignment(row.id, row.revision + 1, params)
    {:ok, noop} = ConfigurationRepository.state()
    assert noop.head == after_save.head
  end

  test "rollback removes configuration writes and leaves accepted history unchanged" do
    {:ok, before} = ConfigurationRepository.state()
    objects = ConfigurationRepository.objects()
    row = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert {:error, :deliberate_failure} =
             ConfigurationRepository.transaction("ui", fn ->
               Monitoring.change(row, %{params: Map.put(row.params, "warn_percent", 70)})
               Repo.rollback(:deliberate_failure)
             end)

    assert Repo.get!(Assignment, row.id).params == row.params
    assert {:ok, ^before} = ConfigurationRepository.state()
    assert ConfigurationRepository.objects() == objects
  end

  test "bulk exceptions are journaled once and remain individually scoped" do
    rows = publish()
    selection = Enum.map(rows, &%{"id" => &1.id, "revision" => &1.revision})
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection)

    {:ok, preview} =
      Monitoring.preview_bulk_configuration(prepared["prepare_token"], %{"limit" => 60})

    before_count = length(ConfigurationRepository.history())

    assert {:ok, %{"changed_count" => 2}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], %{"limit" => 60})

    assert length(ConfigurationRepository.history()) == before_count + 1
    {:ok, state} = ConfigurationRepository.state()

    for row <- rows do
      document = Jason.decode!(state.files["exceptions/#{row.id}.json"])
      assert document["scope"]["runner_installation_id"] == row.runner_id
      assert document["scope"]["check_key"] == row.source_key
      assert document["params"] == %{"limit" => 60}
      assert document["installation_specific"]
    end
  end

  test "first snapshot imports preexisting exceptions without changing generation" do
    [row | _] = publish()

    row =
      Monitoring.change(row, %{instance_exception: %{"limit" => 55}, params: %{"limit" => 55}})

    Repo.query!(
      "TRUNCATE configuration_revisions, configuration_git_objects, configuration_repository RESTART IDENTITY CASCADE"
    )

    {:ok, state} = ConfigurationRepository.state()
    assert Jason.decode!(state.files["exceptions/#{row.id}.json"])["params"] == %{"limit" => 55}
    assert Repo.get!(Assignment, row.id) == %{row | configuration_exception_key: row.id}
    assert [%{channel: "migration"}] = ConfigurationRepository.history()
  end

  test "process death inside a database transaction cannot leave configuration ahead of history" do
    {:ok, before} = ConfigurationRepository.state()
    objects = ConfigurationRepository.objects()
    row = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        ConfigurationRepository.transaction("ui", fn ->
          Monitoring.change(row, %{params: Map.put(row.params, "warn_percent", 71)})
          send(parent, {:configuration_written, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:configuration_written, ^pid}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert {:ok, ^before} = ConfigurationRepository.state()
    assert Repo.get!(Assignment, row.id).params == row.params
    assert ConfigurationRepository.objects() == objects
  end

  test "process death after acceptance preserves the exact revision and reconstructible Git advertisement" do
    [row | _] = publish()
    {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55})
    {:ok, before} = ConfigurationRepository.state()
    candidate = candidate(before, exception_files(before, row, 41))
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        {:ok, accepted} = ConfigurationRepository.accept_push(before.head, candidate)
        # The HTTP caller has not yet returned a response to its client.
        send(parent, {:durably_accepted, accepted.head})

        receive do
          :return_response -> :ok
        end
      end)

    assert_receive {:durably_accepted, head}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert {:ok, current} = ConfigurationRepository.state()
    assert current.head == head
    assert current.files == candidate.files
    assert Repo.get!(Assignment, row.id).params == %{"limit" => 41}
    count = length(ConfigurationRepository.history())

    assert {:ok, advertisement} =
             Mondek.ConfigurationGit.advertise(
               ConfigurationRepository.objects(),
               head,
               "git-upload-pack"
             )

    assert advertisement =~ head <> " HEAD"
    assert {:error, _} = ConfigurationRepository.accept_push(before.head, candidate)
    assert length(ConfigurationRepository.history()) == count
    assert {:ok, ^current} = ConfigurationRepository.state()
  end

  test "competing UI and Git writers to one instance cannot lose either accepted edit" do
    [row | _] = publish()
    {:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55})
    row = Repo.get!(Assignment, row.id)
    {:ok, before} = ConfigurationRepository.state()
    candidate = candidate(before, exception_files(before, row, 41))
    parent = self()

    spawn_write = fn operation ->
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> operation.()
        end
      end)
    end

    ui =
      spawn_write.(fn -> Monitoring.save_assignment(row.id, row.revision, %{"limit" => 32}) end)

    git = spawn_write.(fn -> ConfigurationRepository.accept_push(before.head, candidate) end)
    assert_receive {:ready, _}, 5_000
    assert_receive {:ready, _}, 5_000
    send(ui.pid, :go)
    send(git.pid, :go)
    ui_result = Task.await(ui, 5_000)
    git_result = Task.await(git, 5_000)
    assert Enum.count([ui_result, git_result], &match?({:ok, _}, &1)) == 1
    expected = if match?({:ok, _}, ui_result), do: 32, else: 41
    assert Repo.get!(Assignment, row.id).params == %{"limit" => expected}
    {:ok, current} = ConfigurationRepository.state()

    assert Jason.decode!(current.files["exceptions/#{row.id}.json"])["params"] == %{
             "limit" => expected
           }

    assert hd(ConfigurationRepository.history()).parent == before.head
    count = length(ConfigurationRepository.history())
    assert {:error, :stale} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 32})
    assert {:error, _} = ConfigurationRepository.accept_push(before.head, candidate)
    assert length(ConfigurationRepository.history()) == count
  end

  test "Git changes invalidate affected bulk previews while independent UI edits preserve both changes" do
    [first, second] = rows = publish()

    for row <- rows,
        do: assert({:ok, _} = Monitoring.save_assignment(row.id, row.revision, %{"limit" => 55}))

    rows = Enum.map(rows, &Repo.get!(Assignment, &1.id))
    selection = Enum.map(rows, &%{"id" => &1.id, "revision" => &1.revision})
    {:ok, prepared} = Monitoring.prepare_bulk_configuration(selection)

    {:ok, preview} =
      Monitoring.preview_bulk_configuration(prepared["prepare_token"], %{"limit" => 60})

    {:ok, before} = ConfigurationRepository.state()

    assert {:ok, _} =
             ConfigurationRepository.accept_push(
               before.head,
               candidate(before, exception_files(before, first, 41))
             )

    assert {:error, {:stale, _}} =
             Monitoring.apply_bulk_configuration(preview["review_token"], %{"limit" => 60})

    old_second = Enum.find(rows, &(&1.id == second.id))
    assert {:ok, _} = Monitoring.save_assignment(second.id, old_second.revision, %{"limit" => 32})
    {:ok, final} = ConfigurationRepository.state()
    assert Jason.decode!(final.files["exceptions/#{first.id}.json"])["params"] == %{"limit" => 41}

    assert Jason.decode!(final.files["exceptions/#{second.id}.json"])["params"] == %{
             "limit" => 32
           }
  end

  test "Git edits to a shared rule invalidate an already reviewed UI proposal" do
    [row | _] = publish()
    {:ok, seed} = Mondek.ConfigurationRules.seed(row.id)

    {:ok, preview} =
      Mondek.ConfigurationRules.preview(Map.put(seed, "name", "Shared capacity"))

    {:ok, saved} =
      Mondek.ConfigurationRules.apply(preview["review_token"], preview["proposal"])

    {:ok, rule} = Mondek.ConfigurationRules.get(saved["rule"]["id"])

    {:ok, pending} =
      Mondek.ConfigurationRules.preview(Map.put(rule, "params", %{"limit" => 32}))

    {:ok, before} = ConfigurationRepository.state()
    path = Enum.find(Map.keys(before.files), &String.starts_with?(&1, "rules/"))
    document = Jason.decode!(before.files[path]) |> Map.put("params", %{"limit" => 41})

    assert {:ok, _} =
             ConfigurationRepository.accept_push(
               before.head,
               candidate(before, Map.put(before.files, path, ConfigurationObjects.json(document)))
             )

    assert {:error, :stale} =
             Mondek.ConfigurationRules.apply(pending["review_token"], pending["proposal"])

    assert Repo.get!(Assignment, row.id).params == %{"limit" => 41}
  end

  defp exception_files(state, row, limit) do
    path = "exceptions/#{row.id}.json"
    document = Jason.decode!(state.files[path]) |> Map.put("params", %{"limit" => limit})
    Map.put(state.files, path, ConfigurationObjects.json(document))
  end

  defp candidate(state, files) do
    {head, objects} =
      ConfigurationObjects.commit(files, state.head, "Concurrent Git edit", DateTime.utc_now())

    %{head: head, objects: objects, files: files}
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

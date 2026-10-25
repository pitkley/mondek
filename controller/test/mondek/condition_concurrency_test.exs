# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionRaceWebhook do
  import Plug.Conn
  import Ecto.Query

  def init(options), do: options

  def call(conn, options) do
    {:ok, body, conn} = read_body(conn)
    payload = Jason.decode!(body)

    committed =
      Mondek.Repo.exists?(
        from a in Mondek.Attempt,
          where: a.occurrence_id == ^payload["occurrence_id"] and a.status == "started"
      )

    pause = Agent.get(options[:state], & &1)
    send(options[:owner], {:race_webhook, self(), payload, committed})

    if pause do
      receive do
        :release -> :ok
      after
        2500 -> raise "Test did not release the in-flight receipt"
      end
    end

    send_resp(conn, 204, "")
  end
end

defmodule Mondek.ConditionConcurrencyTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    ConditionIncident,
    ConditionFact,
    Conditions,
    Control,
    Maintenance,
    NotificationWorker,
    OccurrenceEvidence
  }

  @condition %{
    "namespace" => "shared-storage",
    "key" => "orders-pressure",
    "label" => "Orders storage pressure"
  }
  @impact %{"key" => "writes-blocked", "label" => "Writes blocked"}

  test "an acknowledgement committed first is ended by the concurrent maintained impact" do
    acknowledgement_race(:acknowledgement)
  end

  test "a maintained impact committed first makes the concurrently submitted old review stale" do
    acknowledgement_race(:impact)
  end

  test "installed source withdrawals preserve an in-flight receipt and produce one truthful terminal notice" do
    receiver = receiver()
    original = install("linux")
    peer = install("elasticsearch")
    first_report = sample(original, "CRIT", 1)
    assert disposition(send_report(original, first_report, 1)) == "current"
    group = Repo.one!(ConditionIncident)
    critical = occurrence(group.id, "severity", "CRIT")
    original_job = job(critical.id)
    original_facts = fact_ids(group.id)
    original_evidence = Repo.one!(OccurrenceEvidence)
    assert original_evidence.observation_id == first_report["id"]
    assert disposition(send_report(peer, sample(peer, "CRIT", 1), 1)) == "current"
    assert Repo.aggregate(Occurrence, :count) == 1

    delivery = Task.async(fn -> NotificationWorker.perform(original_job) end)
    assert_receive {:race_webhook, server, payload, true}, 1000
    assert payload == critical.payload

    try do
      # The HTTP server has received the body and the durable attempt, but has
      # not returned its accepted receipt. Membership changes must still commit.
      assert {:ok, _} = withdraw(original, 2)
      still_open = Repo.get!(ConditionIncident, group.id)
      assert still_open.status == "open"
      assert fact_ids(group.id) == original_facts
      assert Repo.get!(Occurrence, critical.id).status == "delivering"
      assert Repo.get!(Occurrence, critical.id).payload == payload
      assert job_budget(job(critical.id)) == job_budget(original_job)
      assert Repo.get!(Incident, original_evidence.incident_id).closure_reason == "source_removed"

      assert {:ok, _} = withdraw(peer, 3)
      closed = Repo.get!(ConditionIncident, group.id)
      assert closed.status == "closed"
      assert closed.closure_reason == "source_removed"
      assert closed.closure_reasons == ["source_removed"]
      assert is_nil(closed.closing_observation_id)
      assert Repo.get!(Occurrence, critical.id).status == "superseded"
      assert Repo.get!(Occurrence, critical.id).payload == payload
      assert Repo.get!(Observation, first_report["id"]).payload == first_report
      assert Repo.one!(OccurrenceEvidence) == original_evidence
      assert fact_ids(group.id) == original_facts
      assert Enum.all?(Repo.all(ConditionFact), &(&1.end_reason == "condition_ended"))

      resolution =
        Repo.one!(
          from o in Occurrence,
            where: o.condition_incident_id == ^group.id and o.kind == "resolved"
        )

      assert resolution.payload["closure_reason"] == "source_removed"
      assert resolution.payload["closure_reasons"] == ["source_removed"]
      assert is_nil(resolution.payload["observation_id"])
      assert is_nil(resolution.payload["contribution_id"])
      assert is_nil(resolution.payload["source_at"])
      assert Repo.aggregate(Occurrence, :count) == 2
      assert Repo.aggregate(Oban.Job, :count) == 2
      assert job_budget(job(critical.id)) == job_budget(original_job)

      Agent.update(receiver, fn _ -> false end)
      send(server, :release)
      assert :ok = Task.await(delivery, 5000)
      assert Repo.one!(Attempt).status == "accepted"
      assert Repo.get!(Occurrence, critical.id).status == "superseded"
      assert Repo.get!(Occurrence, critical.id).payload == payload
      assert job_budget(job(critical.id)) == job_budget(original_job)

      assert Repo.get!(ConditionFact, critical.covered_warn_fact_id).covered_by_occurrence_id ==
               critical.id

      # Accepting the old firing receipt neither recreates a fact/budget nor
      # replaces the withdrawal with invented measured-recovery evidence.
      assert Repo.get!(Occurrence, resolution.id).payload == resolution.payload
      assert Repo.aggregate(Occurrence, :count) == 2
      assert Repo.aggregate(Oban.Job, :count) == 2
      assert :ok = NotificationWorker.perform(original_job)
      assert Repo.aggregate(Attempt, :count) == 1
      assert :ok = NotificationWorker.perform(job(resolution.id))
      assert_receive {:race_webhook, _, resolution_payload, true}, 1000
      assert resolution_payload == resolution.payload
      assert Repo.get!(Occurrence, resolution.id).status == "delivered"
      assert Repo.aggregate(Attempt, :count) == 2
      assert Repo.get!(ConditionIncident, group.id).closing_observation_id == nil
    after
      send(server, :release)
      Task.shutdown(delivery, :brutal_kill)
    end
  end

  defp acknowledgement_race(first_kind) do
    original = install("linux")
    maintained = install("elasticsearch")
    assert disposition(send_report(original, sample(original, "CRIT", 1), 1)) == "current"
    assert disposition(send_report(maintained, sample(maintained, "CRIT", 1), 1)) == "current"

    assert {:ok, _} =
             reviewed_maintenance_fixture(maintained.assignment.id, 3600, "Storage work", at())

    group = Repo.one!(ConditionIncident)
    critical = occurrence(group.id, "severity", "CRIT")
    original_job = job(critical.id)
    [stripe] = Conditions.lock_stripes([group])

    reviewed = %{
      "mode" => "until_incident_ends",
      "revision" => group.acknowledgement_revision,
      "attention_revision" => group.attention_revision
    }

    report = sample(maintained, "CRIT", 2, [@impact])

    operations = %{
      acknowledgement: fn ->
        reviewed_acknowledgement_fixture(
          group.id,
          reviewed,
          "Investigating known severity",
          tick(2)
        )
      end,
      impact: fn -> send_report(maintained, report, 2) end
    }

    second_kind = if first_kind == :acknowledgement, do: :impact, else: :acknowledgement
    owner = self()

    first =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = Map.fetch!(operations, first_kind).()
          send(owner, {:first_operation_held, backend_pid(), result})

          receive do
            :commit -> result
          after
            5000 -> raise "First operation was not released"
          end
        end)
      end)

    assert_receive {:first_operation_held, first_backend, {:ok, _}}, 1000

    second =
      Task.async(fn ->
        # Checkout pins the backend for lock inspection without adding an outer
        # transaction: a rejected stale ACK must preserve its normal return value.
        Repo.checkout(fn ->
          send(owner, {:second_operation_started, backend_pid()})
          Map.fetch!(operations, second_kind).()
        end)
      end)

    try do
      assert_receive {:second_operation_started, second_backend}, 1000

      await_condition_wait(
        second_backend,
        first_backend,
        stripe,
        System.monotonic_time(:millisecond) + 2000
      )

      send(first.pid, :commit)
      assert {:ok, {:ok, _}} = Task.await(first, 5000)
      second_result = Task.await(second, 5000)

      case first_kind do
        :acknowledgement ->
          assert disposition(second_result) == "current"

          assert Repo.exists?(
                   from c in Control,
                     where:
                       c.condition_incident_id == ^group.id and
                         c.kind == "acknowledgement_ended" and c.actor == "Mondek"
                 )

        :impact ->
          assert second_result == {:error, :stale}

          refute Repo.exists?(
                   from c in Control,
                     where: c.condition_incident_id == ^group.id and c.kind == "acknowledgement"
                 )
      end

      current = Repo.get!(ConditionIncident, group.id)
      refute Monitoring.acknowledgement_active?(current, tick(2))
      assert current.health == "CRIT"
      assert current.impacts == [@impact]
      assert current.attention_revision == group.attention_revision + 1
      assert Repo.get!(Observation, report["id"]).payload == report
      assert Repo.get!(Occurrence, critical.id).payload == critical.payload
      assert job_budget(job(critical.id)) == job_budget(original_job)

      # The maintained new impact invalidates the old shared scope, but only
      # the original uncovered severity is eligible for immediate delivery.
      assert Conditions.delivery_eligibility(critical, current, tick(2)) == :eligible
      impact_notice = occurrence(group.id, "impact", @impact["key"])

      assert {:gated, ["maintenance"], _} =
               Conditions.delivery_eligibility(impact_notice, current, tick(2))

      member =
        Repo.get_by!(Incident,
          condition_incident_id: group.id,
          assignment_id: maintained.assignment.id
        )

      assert Maintenance.active_for(member, maintained.assignment, tick(2)) != []
      assert Repo.aggregate(Occurrence, :count) == 2
      assert Repo.aggregate(Oban.Job, :count) == 2
    after
      send(first.pid, :commit)
      Task.shutdown(second, :brutal_kill)
      Task.shutdown(first, :brutal_kill)
    end
  end

  defp await_condition_wait(waiter, blocker, stripe, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT $1=ANY(pg_blocking_pids($2)) AND EXISTS (
          SELECT 1 FROM pg_locks WHERE pid=$2 AND locktype='advisory'
            AND classid=931741 AND objid=$3 AND objsubid=2 AND NOT granted)
        """,
        [blocker, waiter, stripe]
      )

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "The concurrent operation must reach the condition lock held by the first"

      await_condition_wait(waiter, blocker, stripe, deadline)
    end
  end

  defp install(key) do
    connection =
      control(%{
        "installation_id" => Ecto.UUID.generate(),
        "session_id" => Ecto.UUID.generate(),
        "prepared" => %{}
      })

    input =
      Map.merge(connection, %{
        "runner_label" => key,
        "source_id" => key <> "-source",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => [
          %{
            "key" => key,
            "label" => key,
            "definition_revision" => String.duplicate("b", 64),
            "environment" => "production",
            "params_owner" => "source",
            "parameter_schema" => %{"fields" => %{}},
            "params" => %{},
            "interval_seconds" => 3,
            "timeout_seconds" => 2,
            "freshness_seconds" => 12,
            "outputs" => [
              %{
                "key" => "pressure",
                "label" => key,
                "target" => %{"kind" => "volume", "key" => key, "label" => key},
                "condition" => @condition
              }
            ]
          }
        ]
      })

    assert {:ok, _} = Monitoring.inventory(input, at())
    assignment = Repo.get_by!(Assignment, source_id: input["source_id"])

    assert {:ok, _} =
             Monitoring.control(Map.put(connection, "prepared", %{assignment.id => 1}), at())

    %{input: input, connection: connection, assignment: assignment}
  end

  defp sample(member, health, sequence, impacts \\ []) do
    measurement(health, sequence, %{
      "assignment_id" => member.assignment.id,
      "generation" => member.assignment.desired_generation,
      "installation_id" => member.connection["installation_id"],
      "session_id" => member.connection["session_id"],
      "started_at" => Monitoring.iso(tick(sequence)),
      "evaluated_at" => Monitoring.iso(tick(sequence)),
      "results" => [
        %{
          "key" => "pressure",
          "health" => health,
          "summary" => "Observed storage pressure",
          "source_at" => Monitoring.iso(tick(sequence)),
          "impacts" => impacts
        }
      ]
    })
  end

  defp send_report(member, report, sequence),
    do:
      Monitoring.ingest(
        envelope([report], Map.take(member.connection, ~w(installation_id session_id))),
        tick(sequence)
      )

  defp withdraw(member, sequence),
    do:
      Monitoring.inventory(
        %{member.input | "inventory_revision" => 2, "checks" => []},
        tick(sequence)
      )

  defp occurrence(group_id, kind, key) do
    Repo.one!(
      from o in Occurrence,
        join: f in ConditionFact,
        on: f.id == o.condition_fact_id,
        where: o.condition_incident_id == ^group_id and f.kind == ^kind and f.key == ^key
    )
  end

  defp fact_ids(group_id),
    do:
      Repo.all(
        from f in ConditionFact,
          where: f.condition_incident_id == ^group_id,
          order_by: f.id,
          select: f.id
      )

  defp job(occurrence_id),
    do:
      Repo.one!(
        from j in Oban.Job, where: fragment("?->>'occurrence_id'", j.args) == ^occurrence_id
      )

  defp job_budget(job), do: {job.id, job.attempt, job.max_attempts, job.args["occurrence_id"]}
  defp tick(seconds), do: DateTime.add(at(), seconds)

  defp backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp receiver do
    state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Mondek.ConditionRaceWebhook, owner: self(), state: state},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
    state
  end
end

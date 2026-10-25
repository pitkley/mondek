# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionDeliveryWebhook do
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

    settings = Agent.get(options[:state], & &1)
    send(options[:owner], {:condition_webhook, self(), payload, committed})

    if settings.pause do
      receive do
        :release -> :ok
      after
        2500 -> raise "Test did not release the paused webhook"
      end
    end

    send_resp(conn, settings.status, "recorded")
  end
end

defmodule Mondek.ConditionDeliveryTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint

  alias Mondek.{
    Conditions,
    ConditionIncident,
    ConditionFact,
    OccurrenceEvidence,
    NotificationWorker,
    Sweeper,
    Control
  }

  test "the API lists one operator incident and applies reviewed shared acknowledgement to every contribution" do
    {_checks, group} = fire_pair()
    listed = build_conn() |> get("/api/v1/incidents") |> json_response(200)
    assert listed["total"] == 1
    assert [%{"id" => id, "incident_kind" => "condition"}] = listed["items"]
    assert id == group.id

    filtered = build_conn() |> get("/api/v1/incidents?search=search") |> json_response(200)
    assert hd(filtered["items"])["health"] == "CRIT"
    assert hd(filtered["items"])["matching_result_count"] == 1

    path = "/api/v1/incidents/#{id}"
    detail = build_conn() |> get(path) |> json_response(200)
    assert detail["counts"]["open"] == 2
    assert detail["counts"]["uncovered"] == 2

    request = ack(group) |> Map.put("note", "Investigating both observers")

    saved =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path <> "/acknowledge", Jason.encode!(request))
      |> json_response(200)

    assert saved["id"] == id
    assert saved["acknowledgement_mode"] == "until_incident_ends"
    detail = build_conn() |> get(path) |> json_response(200)
    assert detail["counts"]["shared_acknowledged"] == 2
    assert detail["counts"]["uncovered"] == 0
    assert Enum.all?(detail["contributions"], & &1["coverage"]["shared_acknowledgement"])
    assert Enum.all?(detail["contributions"], &is_nil(&1["incident"]["acknowledgement_mode"]))

    assert (build_conn()
            |> put_req_header("content-type", "application/json")
            |> post(path <> "/acknowledge", Jason.encode!(request))
            |> json_response(409))["error"]

    empty =
      build_conn()
      |> get(path <> "?state=history&notification_status=delivered")
      |> json_response(200)

    assert empty["contributions"] == []
    assert empty["contribution_page"]["state"] == "history"
    assert empty["counts"]["open"] == 2
    assert empty["notification_page"]["status"] == "delivered"
  end

  test "operator incident queries count each group once and retain whole-group severity under filters" do
    {_checks, group} = fire_pair()
    page = Monitoring.list_incidents(%{}, at())
    assert page.total == 1
    assert [%{"id" => id, "incident_kind" => "condition", "health" => "CRIT"} = item] = page.items
    assert id == group.id
    assert item["open_contribution_count"] == 2
    assert item["result_count"] == 2
    assert item["observer_count"] == 1
    assert Monitoring.overview(at())["open_incident_count"] == 1

    filtered = Monitoring.list_incidents(%{"search" => "search"}, at())
    assert filtered.total == 1
    assert [match] = filtered.items
    assert match["id"] == group.id
    assert match["health"] == "CRIT"
    assert match["matching_result_count"] == 1
    assert match["open_contribution_count"] == 2
    assert match["scope_filtered"]
    assert Monitoring.list_incidents(%{"search" => "search", "health" => "WARN"}, at()).total == 0
    assert Monitoring.list_incidents(%{"runner_id" => Ecto.UUID.generate()}, at()).total == 0
  end

  test "one multi-output report is atomic while ordered buffered reports preserve recurrence" do
    spec = hd(check_specs())
    output = hd(spec["outputs"])
    outputs = for key <- ["local", "service"], do: Map.put(output, "key", key)
    [a] = install([Map.put(spec, "outputs", outputs)])
    first = multi_sample(a, [{"local", "CRIT"}, {"service", "OK"}], 1)
    assert disposition(ingest(first)) == "current"
    original = Repo.one!(ConditionIncident)

    assert {:ok, _} =
             Conditions.acknowledge(original.id, ack(original), "Known storage issue", at())

    handover = multi_sample(a, [{"local", "OK"}, {"service", "CRIT"}], 2)
    assert disposition(ingest(handover)) == "current"
    assert Repo.aggregate(ConditionIncident, :count) == 1
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.aggregate(Observation, :count) == 2
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, original.id), at())

    recovery = multi_sample(a, [{"local", "OK"}, {"service", "OK"}], 3)
    recurrence = multi_sample(a, [{"local", "CRIT"}, {"service", "OK"}], 4)

    assert {:ok, %{"dispositions" => dispositions}} =
             Monitoring.ingest(envelope([recovery, recurrence]), at())

    assert Enum.map(dispositions, & &1["disposition"]) == ["current", "current"]
    assert Repo.get!(ConditionIncident, original.id).closing_observation_id == recovery["id"]
    current = Repo.one!(from g in ConditionIncident, where: g.status == "open")
    refute current.id == original.id
    refute Monitoring.acknowledgement_active?(current, at())
    assert Repo.aggregate(Occurrence, :count) == 2
    assert Repo.aggregate(Observation, :count) == 4
  end

  test "a transport batch preserves the final recovery report even with tied receipt times" do
    {checks, group} = fire_pair()
    contributions = Repo.all(from i in Incident, order_by: [desc: i.id])

    [first, last] =
      Enum.map(contributions, fn i -> Enum.find(checks, &(&1.id == i.assignment_id)) end)

    recovery_a = multi_sample(first, [{"pressure", "OK"}], 2)
    recovery_b = multi_sample(last, [{"pressure", "OK"}], 2)

    assert {:ok, %{"dispositions" => dispositions}} =
             Monitoring.ingest(envelope([recovery_a, recovery_b]), at())

    assert Enum.all?(dispositions, &(&1["disposition"] == "current"))
    closed = Repo.get!(ConditionIncident, group.id)
    assert closed.status == "closed"
    assert closed.closing_observation_id == recovery_b["id"]
  end

  test "rejected group delivery, explicit retry and shared hold preserve payload and fact budget" do
    receiver = receiver(503)
    {_checks, group} = fire_pair()
    critical = occurrence("CRIT")
    warning = occurrence("WARN")
    original_job = job(critical)
    assert {:ok, {:gated, 30}} = NotificationWorker.begin_attempt(warning.id, at())

    assert {:error, _} =
             NotificationWorker.perform(%{original_job | attempt: original_job.max_attempts})

    assert_receive {:condition_webhook, _, payload, true}
    assert payload == critical.payload
    assert Repo.get!(Occurrence, critical.id).status == "exhausted"
    Monitoring.change(original_job, %{state: "discarded"})

    assert Conditions.delivery_eligibility(warning, Repo.get!(ConditionIncident, group.id), at()) ==
             :eligible

    assert {:ok, _} = Conditions.acknowledge(group.id, ack(group), "Investigating storage", at())
    assert {:ok, retried} = Monitoring.retry_notification(critical.id, "Receiver repaired", at())
    assert retried["payload"] == payload
    replacement = job(critical)
    refute replacement.id == original_job.id

    assert {:ok, {:gated, 86_400}} =
             NotificationWorker.begin_attempt(critical.id, at(), replacement)

    assert Repo.aggregate(Attempt, :count) == 1

    assert {:error, :not_exhausted} =
             Monitoring.retry_notification(critical.id, "Duplicate retry", at())

    Monitoring.change(replacement, %{state: "scheduled", scheduled_at: DateTime.add(at(), 86_400)})

    group = Repo.get!(ConditionIncident, group.id)
    assert {:ok, _} = Conditions.acknowledge(group.id, ack(group, "end"), "Resume delivery", at())
    assert {:ok, {count, _}} = Sweeper.wake_held_notifications(at())
    assert count >= 1
    resumed = Repo.get!(Oban.Job, replacement.id)
    assert resumed.state == "available"
    assert resumed.attempt == replacement.attempt
    assert resumed.max_attempts == replacement.max_attempts
    Agent.update(receiver, &%{&1 | status: 204})
    assert :ok = NotificationWorker.perform(resumed)
    assert_receive {:condition_webhook, _, ^payload, true}
    assert Repo.get!(Occurrence, critical.id).status == "delivered"
    assert Repo.get!(Occurrence, warning.id).status == "superseded"

    assert Repo.get!(ConditionFact, critical.covered_warn_fact_id).covered_by_occurrence_id ==
             critical.id

    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(OccurrenceEvidence, :count) == 2

    assert Repo.exists?(
             from c in Control,
               where: c.condition_incident_id == ^group.id and c.kind == "notification_retry"
           )

    assert MapSet.new(
             Enum.map(Monitoring.inspect_occurrences([critical, warning], at()), & &1["id"])
           ) == MapSet.new([critical.id, warning.id])
  end

  test "late accepted critical receipt covers only its original warning lifetime" do
    receiver(204, true)
    {checks, old_group} = fire_pair()
    critical = occurrence("CRIT")
    task = Task.async(fn -> NotificationWorker.perform(job(critical)) end)
    assert_receive {:condition_webhook, server, _, true}, 1000
    for a <- checks, do: send_sample(a, "OK", 2, DateTime.add(at(), 1))
    assert Repo.get!(ConditionIncident, old_group.id).status == "closed"
    send_sample(hd(checks), "WARN", 3, DateTime.add(at(), 2))
    new_group = Repo.one!(from g in ConditionIncident, where: g.status == "open")
    refute new_group.id == old_group.id
    new_warning = occurrence("WARN", new_group.id)
    send(server, :release)
    assert :ok = Task.await(task, 5000)
    assert Repo.get!(Occurrence, critical.id).status == "superseded"

    assert Repo.get!(ConditionFact, critical.covered_warn_fact_id).covered_by_occurrence_id ==
             critical.id

    assert is_nil(
             Repo.get!(ConditionFact, new_warning.condition_fact_id).covered_by_occurrence_id
           )

    assert {:ok, {%Occurrence{id: delivered_id}, %Attempt{occurrence_id: attempted_id}}} =
             NotificationWorker.begin_attempt(new_warning.id, DateTime.add(at(), 2))

    assert delivered_id == new_warning.id
    assert attempted_id == new_warning.id
  end

  test "terminal group pruning removes its reference cycle but unfinished work retains all evidence" do
    receiver(204)
    {checks, group} = fire_pair()
    critical = occurrence("CRIT")
    assert :ok = NotificationWorker.perform(job(critical))
    assert_receive {:condition_webhook, _, _, true}
    for a <- checks, do: send_sample(a, "OK", 2, DateTime.add(at(), 1))

    resolution =
      Repo.one!(
        from o in Occurrence, where: o.condition_incident_id == ^group.id and o.kind == "resolved"
      )

    Repo.update_all(Oban.Job, set: [state: "completed", completed_at: at()])
    future = DateTime.add(at(), 40 * 86_400)
    evidence = Repo.all(Observation) |> Enum.map(& &1.id) |> Enum.sort()
    assert {:ok, _} = Sweeper.sweep(future)
    assert Repo.get!(ConditionIncident, group.id).status == "closed"
    assert Enum.sort(Enum.map(Repo.all(Observation), & &1.id)) == evidence
    assert Repo.aggregate(OccurrenceEvidence, :count) == 3
    assert :ok = NotificationWorker.perform(job(resolution))
    assert_receive {:condition_webhook, _, _, true}
    assert {:ok, _} = Sweeper.sweep(future)
    assert Repo.aggregate(ConditionIncident, :count) == 0
    assert Repo.aggregate(ConditionFact, :count) == 0
    assert Repo.aggregate(Incident, :count) == 0
    assert Repo.aggregate(Occurrence, :count) == 0
    assert Repo.aggregate(OccurrenceEvidence, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(Observation, :count) == 2
  end

  test "partial maintenance cancellation wakes the same group job with its original budget" do
    {checks, group} = fire_pair()
    critical = occurrence("CRIT")
    warning = occurrence("WARN")
    original_job = job(critical)
    critical_check = Enum.at(checks, 1)

    assert {:ok, _} =
             reviewed_maintenance_fixture(critical_check.id, 3600, "Volume maintenance", at())

    assert {:ok, {:gated, 3600}} =
             NotificationWorker.begin_attempt(critical.id, at(), original_job)

    assert Conditions.delivery_eligibility(warning, group, at()) == :eligible
    Monitoring.change(original_job, %{state: "scheduled", scheduled_at: DateTime.add(at(), 3600)})

    assert {:ok, _} =
             reviewed_maintenance_fixture(critical_check.id, 0, "Volume work complete", at())

    assert {:ok, {1, _}} = Sweeper.wake_held_notifications(at())
    resumed = Repo.get!(Oban.Job, original_job.id)
    assert resumed.state == "available"
    assert resumed.attempt == original_job.attempt
    assert resumed.max_attempts == original_job.max_attempts
    assert Repo.get!(Occurrence, critical.id).payload == critical.payload
    assert Repo.aggregate(Attempt, :count) == 0

    assert Conditions.delivery_eligibility(critical, Repo.get!(ConditionIncident, group.id), at()) ==
             :eligible
  end

  test "maintenance cancellation serializes with an in-flight grouped receipt" do
    receiver(204, true)
    {checks, group} = fire_pair()
    critical = occurrence("CRIT")
    task = Task.async(fn -> NotificationWorker.perform(job(critical)) end)
    assert_receive {:condition_webhook, server, _, true}, 1000
    a = hd(checks)
    assert {:ok, _} = reviewed_maintenance_fixture(a.id, 3600, "Node maintenance", at())
    # Hold the condition lock while cancellation reaches the same boundary.
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Conditions.lock!(group.id)
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(owner, {:condition_locked, backend_pid})

          receive do
            :unlock -> :ok
          after
            3000 -> raise "Test lock was not released"
          end
        end)
      end)

    assert_receive {:condition_locked, blocker_backend}, 1000

    cancellation =
      Task.async(fn -> reviewed_maintenance_fixture(a.id, 0, "Maintenance ended", at()) end)

    send(server, :release)
    await_lock_waiters(blocker_backend, System.monotonic_time(:millisecond) + 1500)
    send(blocker.pid, :unlock)
    assert {:ok, :ok} = Task.await(blocker, 5000)
    assert {:ok, _} = Task.await(cancellation, 5000)
    assert :ok = Task.await(task, 5000)
    assert Repo.get!(Occurrence, critical.id).status == "delivered"
    assert Repo.aggregate(Attempt, :count) == 1
  end

  defp receiver(status, pause \\ false) do
    state = start_supervised!({Agent, fn -> %{status: status, pause: pause} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Mondek.ConditionDeliveryWebhook, owner: self(), state: state},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
    state
  end

  defp await_lock_waiters(blocker_backend, deadline) do
    %{rows: [[waiting]]} =
      Repo.query!(
        """
        SELECT count(*) FROM pg_stat_activity
        WHERE datname=current_database() AND wait_event_type='Lock' AND wait_event='advisory'
          AND $1=ANY(pg_blocking_pids(pid))
        """,
        [blocker_backend]
      )

    if waiting < 2 do
      assert System.monotonic_time(:millisecond) < deadline,
             "Both maintenance cancellation and receipt completion must reach the condition lock"

      Process.sleep(10)
      await_lock_waiters(blocker_backend, deadline)
    end
  end

  defp fire_pair do
    rows = install(check_specs())
    [warning, critical] = rows
    send_sample(warning, "WARN", 1, at())
    send_sample(critical, "CRIT", 1, at())
    {rows, Repo.one!(ConditionIncident)}
  end

  defp check_specs do
    declaration = %{"namespace" => "delivery", "key" => "storage", "label" => "Storage pressure"}

    for {key, kind} <- [{"volume", "volume"}, {"search", "service"}] do
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
            "target" => %{"kind" => kind, "key" => key, "label" => key},
            "condition" => declaration
          }
        ]
      }
    end
  end

  defp install(checks) do
    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(control(), %{
                 "runner_label" => "Delivery observer",
                 "source_id" => "delivery-tests",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               at()
             )

    rows =
      Repo.all(
        from a in Assignment, where: a.source_id == "delivery-tests", order_by: a.source_key
      )

    assert {:ok, _} = connect(%{"prepared" => Map.new(rows, &{&1.id, 1})})
    rows
  end

  defp multi_sample(a, healths, sequence),
    do:
      measurement("OK", sequence, %{
        "assignment_id" => a.id,
        "generation" => 1,
        "started_at" => Monitoring.iso(at()),
        "evaluated_at" => Monitoring.iso(at()),
        "results" =>
          Enum.map(healths, fn {key, health} ->
            %{
              "key" => key,
              "health" => health,
              "summary" => "Observed storage",
              "source_at" => Monitoring.iso(at())
            }
          end)
      })

  defp send_sample(a, health, sequence, time) do
    sample =
      measurement(health, sequence, %{
        "assignment_id" => a.id,
        "generation" => 1,
        "started_at" => Monitoring.iso(time),
        "evaluated_at" => Monitoring.iso(time),
        "results" => [
          %{
            "key" => "pressure",
            "health" => health,
            "summary" => "Observed storage",
            "source_at" => Monitoring.iso(time)
          }
        ]
      })

    assert disposition(ingest(sample, time)) == "current"
  end

  defp occurrence(severity, group_id \\ nil) do
    query =
      from o in Occurrence,
        join: f in ConditionFact,
        on: f.id == o.condition_fact_id,
        where: f.kind == "severity" and f.key == ^severity

    query =
      if group_id, do: from(o in query, where: o.condition_incident_id == ^group_id), else: query

    Repo.one!(query)
  end

  defp job(occurrence),
    do:
      Repo.one!(
        from j in Oban.Job,
          where: fragment("?->>'occurrence_id'", j.args) == ^occurrence.id,
          order_by: [desc: j.id],
          limit: 1
      )

  defp ack(group, mode \\ "until_incident_ends"),
    do: %{
      "mode" => mode,
      "revision" => group.acknowledgement_revision,
      "attention_revision" => group.attention_revision
    }
end

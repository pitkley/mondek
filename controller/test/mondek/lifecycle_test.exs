# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.LifecycleTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Configuration, Control, NotificationWorker}

  defp params, do: %{"path" => "/tmp", "warn_percent" => 80, "crit_percent" => 90}

  defp exhausted do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    Monitoring.change(Repo.one!(Oban.Job), %{state: "discarded"})
    Mondek.Sweeper.sweep(at())
    Repo.get!(Occurrence, occurrence.id)
  end

  test "same-type checks have independent stable identities, targets and measurement state" do
    assert {:ok, first} =
             create_source_fixture(
               "filesystem",
               "Temporary storage",
               params()
             )

    assert {:ok, second} =
             create_source_fixture(
               "filesystem",
               "Working directory",
               Map.put(params(), "path", "/work")
             )

    assert {:ok, _} = Ecto.UUID.cast(first["id"])
    assert first["id"] != second["id"]
    assert first["label"] == "Temporary storage"
    assert first["retired"] == false
    assert Repo.get_by!(Configuration, assignment_id: first["id"]).params == params()

    prepared = %{first["id"] => 1, second["id"] => 1}
    assert {:ok, response} = connect(%{"prepared" => prepared})
    assert response["assignments_authoritative"]
    assert length(response["assignments"]) == 5

    assert disposition(ingest(measurement("CRIT", 1, %{"assignment_id" => first["id"]}))) ==
             "current"

    assert disposition(ingest(measurement("OK", 1, %{"assignment_id" => second["id"]}))) ==
             "current"

    assert Repo.get!(Assignment, first["id"]).current["health"] == "CRIT"
    assert Repo.get!(Assignment, second["id"]).current["health"] == "OK"
    assert Repo.one!(Incident).assignment_id == first["id"]

    assert {:error, {:invalid, _}} =
             Monitoring.save_assignment(first["id"], 1, Map.put(params(), "path", "/elsewhere"))

    assert {:ok, saved} =
             Monitoring.save_assignment(first["id"], 1, Map.put(params(), "warn_percent", 70))

    assert saved["desired_generation"] == 2
    assert Repo.get!(Assignment, second["id"]).desired_generation == 1
  end

  @tag empty_source_fixture: true
  test "complete inventory validates names, parameter schemas and values atomically" do
    alias Mondek.CoverageFixtures, as: F

    good =
      F.check("disk")
      |> Map.merge(%{
        "params_owner" => "ui",
        "params" => %{"warn" => 80, "crit" => 90},
        "parameter_schema" => %{
          "fields" => %{
            "warn" => %{"type" => "number", "minimum" => 0, "maximum" => 100},
            "crit" => %{"type" => "number", "minimum" => 0, "maximum" => 100}
          },
          "comparisons" => [%{"left" => "warn", "op" => "lt", "right" => "crit"}]
        }
      })

    p = F.publication([]) |> Map.delete("coverage") |> Map.put("checks", [good])
    assert {:ok, _} = Monitoring.inventory(p, at())
    [original] = F.assignments(p)

    for invalid <- [
          Map.put(good, "label", "Bad\nname"),
          Map.put(good, "params", %{}),
          put_in(good, ["params", "crit"], 70),
          Map.put(good, "params_owner", "invalid")
        ] do
      assert {:error, {:invalid, _}} =
               Monitoring.inventory(
                 Map.merge(p, %{
                   "inventory_revision" => 2,
                   "checks" => [good, Map.put(invalid, "key", "bad")]
                 }),
                 at()
               )

      assert F.assignments(p) == [original]
    end
  end

  @tag empty_source_fixture: true
  test "an empty controller never seeds checks and a source withdrawal releases runner capacity" do
    alias Mondek.CoverageFixtures, as: F
    assert {:ok, %{"assignments" => []}} = Monitoring.control(control(), at())
    assert Repo.aggregate(Assignment, :count) == 0

    p =
      F.publication([])
      |> Map.delete("coverage")
      |> Map.merge(Map.take(control(), ~w(installation_id session_id boot)))

    p = Map.put(p, "checks", for(n <- 1..512, do: F.check("check-#{n}")))
    assert {:ok, %{"accepted_checks" => 512}} = Monitoring.inventory(p, at())
    overflow = Map.put(p, "source_id", "another-source") |> Map.put("checks", [F.check("extra")])
    assert {:error, {:invalid, _}} = Monitoring.inventory(overflow, at())

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(p, %{"inventory_revision" => 2, "checks" => tl(p["checks"])}),
               at()
             )

    assert {:ok, _} = Monitoring.inventory(overflow, at())
    assert {:ok, response} = Monitoring.control(control(), at())
    assert length(response["assignments"]) == 512
    assert Repo.aggregate(from(a in Assignment, where: not is_nil(a.retired_at)), :count) == 1
  end

  test "retirement closes administratively, fences buffered evidence and preserves identity and history" do
    occurrence = exhausted()
    original = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")
    incident = Repo.one!(Incident)

    assert {:ok, retired} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Replaced this check",
               at()
             )

    assert retired["retired"]
    assert retired["revision"] == 2
    assert retired["retirement_reason"] == "Replaced this check"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current ==
             original.current

    assert Repo.get!(Occurrence, occurrence.id).status == "superseded"
    incident = Repo.get!(Incident, incident.id)
    assert incident.status == "closed"
    assert incident.closure_reason == "source_removed"
    assert is_nil(incident.closing_observation_id)
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.one!(Control).kind == "source_removed"

    late = measurement("OK", 2)

    assert {:ok,
            %{"dispositions" => [%{"disposition" => "historical", "reason" => "check_retired"}]}} =
             ingest(late)

    assert disposition(ingest(late)) == "duplicate"

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").current ==
             original.current

    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 1
    assert {:ok, response} = connect()

    refute Enum.any?(
             response["assignments"],
             &(&1["id"] == "10000000-0000-4000-8000-000000000001")
           )

    refute Map.has_key?(response["authorized"], "10000000-0000-4000-8000-000000000001")

    assert Monitoring.assignment_detail("10000000-0000-4000-8000-000000000001", at())["current"][
             "knowledge"
           ] == "retired"

    assert Monitoring.incident_detail(incident.id, at())["incident"]["closure_reason"] ==
             "source_removed"

    assert {:error, :retired} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000001",
               2,
               original.params
             )

    assert {:error, :retired} =
             reviewed_maintenance_fixture(
               "10000000-0000-4000-8000-000000000001",
               60,
               "Not active",
               at()
             )

    assert {:error, :superseded} =
             Monitoring.retry_notification(occurrence.id, "No longer relevant", at())
  end

  test "concurrent parameter save and source withdrawal leave a retired fenced assignment" do
    id = "10000000-0000-4000-8000-000000000001"

    operations = [
      fn ->
        Monitoring.save_assignment(id, 1, %{
          "path" => "/",
          "warn_percent" => 70,
          "crit_percent" => 90
        })
      end,
      fn -> withdraw_source_fixture(id, "Source withdrawn", at()) end
    ]

    results = operations |> Enum.map(&Task.async/1) |> Enum.map(&Task.await/1)
    assert Enum.any?(results, &match?({:ok, %{"retired" => true}}, &1))

    assert Enum.all?(
             results,
             &(match?({:ok, _}, &1) or
                 match?({:error, reason} when reason in [:stale, :retired], &1))
           )

    assert Repo.get!(Assignment, id).retired_at == at()
    assert {:ok, response} = connect()
    refute Enum.any?(response["assignments"], &(&1["id"] == id))
  end

  test "retired overview is bounded while direct inspection retains the older check's audit" do
    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Oldest retired check",
               at()
             )

    rows =
      for n <- 1..105,
          do: %{
            id: Ecto.UUID.generate(),
            kind: "10000000-0000-4000-8000-000000000002",
            label: "Retired #{n}",
            params: %{"url" => "http://target/ready"},
            expected_keys: ["readiness"],
            retired_at: DateTime.add(at(), n),
            retirement_reason: "No longer needed"
          }

    Repo.insert_all(Assignment, rows)
    snapshot = Monitoring.snapshot(at())
    assert snapshot["assignment_limits"]["retired_total"] == 106
    assert snapshot["assignment_limits"]["retired_returned"] == 100

    refute Enum.any?(
             snapshot["assignments"],
             &(&1["id"] == "10000000-0000-4000-8000-000000000001")
           )

    detail = Monitoring.assignment_inspection("10000000-0000-4000-8000-000000000001", at())
    assert detail["assignment"]["retirement_reason"] == "Oldest retired check"

    assert [%{"kind" => "source_removed", "reason" => "Oldest retired check"}] =
             detail["controls"]

    assert detail["limits"]["controls"]["total"] == 1
    assert Monitoring.assignment_inspection("unknown") == nil
  end

  test "database retirement constraint requires a nonempty reason" do
    for reason <- [nil, "", " "] do
      assert_raise Ecto.ConstraintError, fn ->
        Monitoring.change(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001"), %{
          retired_at: at(),
          retirement_reason: reason
        })
      end
    end

    assert is_nil(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").retired_at)
  end

  test "retired raw evidence expires after the history window without losing compact check identity" do
    connect()
    sample = measurement("OK")
    ingest(sample)

    withdraw_source_fixture(
      "10000000-0000-4000-8000-000000000001",
      "Finished local trial",
      at()
    )

    Mondek.Sweeper.sweep(DateTime.add(at(), 29 * 86_400))
    assert Repo.get(Observation, sample["id"])
    Mondek.Sweeper.sweep(DateTime.add(at(), 31 * 86_400))
    refute Repo.get(Observation, sample["id"])

    detail =
      Monitoring.assignment_inspection(
        "10000000-0000-4000-8000-000000000001",
        DateTime.add(at(), 31 * 86_400)
      )

    assert detail["assignment"]["retirement_reason"] == "Finished local trial"
    assert detail["assignment"]["current"]["health"] == "OK"
    assert detail["assignment"]["current"]["knowledge"] == "retired"
    assert detail["limits"]["evidence"]["missing"] == 1

    assert Repo.get_by(Configuration,
             assignment_id: "10000000-0000-4000-8000-000000000001",
             generation: 1
           )
  end

  test "mixed ingestion batches lock check membership in deterministic order" do
    connect()
    owner = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Monitoring.lock_assignment("10000000-0000-4000-8000-000000000001")
          send(owner, :first_check_locked)

          receive do
            :release -> :ok
          after
            5000 -> raise "test did not release first check"
          end
        end)
      end)

    assert_receive :first_check_locked

    second =
      measurement("OK", 1, %{"assignment_id" => "10000000-0000-4000-8000-000000000002"})
      |> put_in(["results", Access.at(0), "key"], "readiness")

    batch = Task.async(fn -> Monitoring.ingest(envelope([second, measurement("OK")]), at()) end)

    try do
      wait_for_assignment_lock()

      assert {:ok, _} =
               Repo.transaction(fn ->
                 Repo.query!("SET LOCAL lock_timeout='200ms'")
                 Monitoring.lock_assignment("10000000-0000-4000-8000-000000000002")
               end)
    after
      send(blocker.pid, :release)
    end

    assert {:ok, :ok} = Task.await(blocker)
    assert {:ok, %{"dispositions" => [%{"id" => id}, _]}} = Task.await(batch)
    assert id == second["id"]
  end

  defp wait_for_assignment_lock(remaining \\ 100)

  defp wait_for_assignment_lock(0),
    do: flunk("ingestion did not reach its blocked assignment lock")

  defp wait_for_assignment_lock(remaining) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%assignments%' AND pid<>pg_backend_pid()"
      )

    if count == 0 do
      Process.sleep(10)
      wait_for_assignment_lock(remaining - 1)
    end
  end

  test "retry is concurrent-safe, audited and unaffected by the old discarded job" do
    occurrence = exhausted()
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"

    assert Enum.find(Monitoring.snapshot(at())["occurrences"], &(&1["id"] == occurrence.id))[
             "can_retry"
           ]

    previous = Application.get_env(:mondek, :notification_max_attempts, 100)
    Application.put_env(:mondek, :notification_max_attempts, 3)
    on_exit(fn -> Application.put_env(:mondek, :notification_max_attempts, previous) end)

    results =
      1..8
      |> Task.async_stream(fn _ ->
        Monitoring.retry_notification(occurrence.id, "Receiver repaired", at())
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_exhausted}, &1)) == 7
    current = Repo.get!(Occurrence, occurrence.id)
    assert current.status == "pending"
    assert current.payload == occurrence.payload
    assert current.destination == occurrence.destination
    assert Repo.aggregate(Occurrence, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 2
    assert Repo.one!(from j in Oban.Job, where: j.state == "available").max_attempts == 3
    audit = Repo.one!(Control)
    assert audit.kind == "notification_retry"
    assert audit.occurrence_id == occurrence.id
    assert audit.actor == "Local operator"
    assert audit.reason == "Receiver repaired"
    assert {:ok, _} = Mondek.Sweeper.sweep(at())
    assert Repo.get!(Occurrence, occurrence.id).status == "pending"
    latest = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    Monitoring.change(latest, %{state: "discarded"})
    Mondek.Sweeper.sweep(at())
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
  end

  test "retry respects acknowledgement and maintenance and only eligible exhaustion can restart" do
    occurrence = exhausted()
    incident = Repo.one!(Incident)
    reviewed_acknowledgement_fixture(incident.id, 30, "Investigating", at())
    reviewed_maintenance_fixture("10000000-0000-4000-8000-000000000001", 60, "Maintenance", at())
    assert {:ok, _} = Monitoring.retry_notification(occurrence.id, "Receiver restored", at())

    assert {:ok, {:gated, _}} =
             NotificationWorker.begin_attempt(occurrence.id, DateTime.add(at(), 31))

    assert Repo.aggregate(Attempt, :count) == 0
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(occurrence.id, DateTime.add(at(), 61))

    assert {:error, :not_exhausted} =
             Monitoring.retry_notification(occurrence.id, "Already running", at())

    Monitoring.change(Repo.get!(Occurrence, occurrence.id), %{status: "exhausted"})

    assert {:error, :delivery_in_progress} =
             Monitoring.retry_notification(occurrence.id, "Job not finished yet", at())

    refute Enum.find(Monitoring.snapshot(at())["occurrences"], &(&1["id"] == occurrence.id))[
             "can_retry"
           ]

    ingest(measurement("OK", 2))
    assert {:error, :superseded} = Monitoring.retry_notification(occurrence.id, "Too late", at())
    assert {:error, {:invalid, _}} = Monitoring.retry_notification("not-a-uuid", "Invalid", at())
    assert {:error, {:invalid, _}} = Monitoring.retry_notification(occurrence.id, " ", at())
  end

  test "retirement permits an in-flight webhook to finish but never starts another attempt" do
    owner = self()

    server =
      start_supervised!(
        {Bandit, plug: {Mondek.LifecycleWebhook, owner: owner}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    job = Repo.one!(Oban.Job)
    task = Task.async(fn -> NotificationWorker.perform(job) end)
    assert_receive {:delivery_started, request_pid, _payload}, 2000

    assert {:ok, _} =
             withdraw_source_fixture(
               "10000000-0000-4000-8000-000000000001",
               "Target removed",
               at()
             )

    send(request_pid, {:respond, 204})
    assert :ok = Task.await(task)
    assert Repo.one!(Attempt).status == "accepted"
    assert Repo.get!(Occurrence, occurrence.id).status == "superseded"
    assert {:ok, :superseded} = NotificationWorker.begin_attempt(occurrence.id, at())
    assert Repo.aggregate(Attempt, :count) == 1
  end

  test "an operator retry delivers the identical exhausted occurrence over real HTTP" do
    server =
      start_supervised!(
        {Bandit, plug: {Mondek.LifecycleWebhook, owner: self()}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env!(:mondek, :webhook_url)
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    on_exit(fn -> Application.put_env(:mondek, :webhook_url, previous) end)
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    job = Repo.one!(Oban.Job)
    first = Task.async(fn -> NotificationWorker.perform(%{job | attempt: job.max_attempts}) end)
    assert_receive {:delivery_started, request_pid, payload}, 2000
    assert payload == occurrence.payload
    send(request_pid, {:respond, 503})
    assert {:error, _} = Task.await(first)
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    Monitoring.change(job, %{state: "discarded"})

    assert {:ok, _} = Monitoring.retry_notification(occurrence.id, "Receiver restored", at())
    new_job = Repo.one!(from j in Oban.Job, order_by: [desc: j.id], limit: 1)
    second = Task.async(fn -> NotificationWorker.perform(new_job) end)
    assert_receive {:delivery_started, request_pid, ^payload}, 2000
    send(request_pid, {:respond, 202})
    assert :ok = Task.await(second)
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    assert Repo.aggregate(Attempt, :count) == 2
    assert Repo.aggregate(Occurrence, :count) == 1

    assert {:error, :superseded} =
             Monitoring.retry_notification(occurrence.id, "Already delivered", at())
  end
end

defmodule Mondek.LifecycleWebhook do
  def init(options), do: options

  def call(conn, options) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(options[:owner], {:delivery_started, self(), Jason.decode!(body)})

    receive do
      {:respond, status} -> Plug.Conn.send_resp(conn, status, "")
    after
      2500 -> Plug.Conn.send_resp(conn, 503, "No test response")
    end
  end
end

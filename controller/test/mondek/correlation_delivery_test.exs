# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationReceiptServer do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    send(opts[:owner], {:receipt, Jason.decode!(body)})
    send_resp(conn, 204, "")
  end
end

defmodule Mondek.CorrelationDeliveryTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    Correlations,
    CaseControls,
    CorrelationDelivery,
    CorrelationBatch,
    CorrelationCredit,
    CorrelationReservation,
    NotificationWorker
  }

  defp incident(label) do
    {:ok, a} =
      create_source_fixture("python", label, %{
        "path" => "/",
        "warn_percent" => 80,
        "crit_percent" => 90
      })

    connect(%{"prepared" => %{a["id"] => 1}})
    assert disposition(ingest(measurement("CRIT", 1, %{"assignment_id" => a["id"]}))) == "current"
    Repo.get_by!(Incident, assignment_id: a["id"])
  end

  defp create_case(episodes) do
    p = %{
      "action" => "create",
      "request_id" => Ecto.UUID.generate(),
      "title" => "Cluster",
      "reason" => "Related",
      "episodes" => Enum.map(episodes, &%{"type" => "individual", "id" => &1.id})
    }

    {:ok, review} = Correlations.preview(p, at())
    {:ok, r} = Correlations.apply(review["review_token"], at())
    r["case_id"]
  end

  defp control(id, action, extra \\ %{}) do
    {:ok, r} =
      CaseControls.preview(
        id,
        Map.merge(
          %{"action" => action, "note" => "Reviewed", "request_id" => Ecto.UUID.generate()},
          extra
        ),
        at()
      )

    assert {:ok, _} = CaseControls.apply(r["review_token"], at())
  end

  defp occurrence(i), do: Repo.get_by!(Occurrence, incident_id: i.id, kind: "firing")

  test "off prevents batch reservation and lets frozen handover expire without spending credit" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    x = occurrence(a)
    y = occurrence(b)
    set_notification_adapter(:off)

    assert {:ok, :delivery_disabled} = NotificationWorker.begin_attempt(x.id, at())
    refute Repo.exists?(CorrelationBatch)

    Application.put_env(:mondek, :notification_adapter, :webhook)
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(x.id, at())
    batch = Repo.one!(CorrelationBatch)
    Application.put_env(:mondek, :notification_adapter, :off)

    assert {:ok, :delivery_disabled} = CorrelationDelivery.begin_attempt(batch.id, at())
    assert Repo.get!(CorrelationBatch, batch.id).deadline == batch.deadline
    assert {:ok, :wait} = CorrelationDelivery.begin_attempt(batch.id, batch.deadline)
    assert Repo.get!(CorrelationBatch, batch.id).status == "released"
    refute Repo.exists?(Mondek.CorrelationAttempt)

    for original <- [x, y] do
      assert Repo.get!(CorrelationCredit, original.id).spent == 0
      assert Repo.get!(Occurrence, original.id).payload == original.payload
    end

    Application.put_env(:mondek, :notification_adapter, :webhook)

    assert {:ok, {%Occurrence{id: id}, _}} =
             NotificationWorker.begin_attempt(x.id, batch.deadline)

    assert id == x.id
  end

  test "off preserves admitted completion and pauses case terminal delivery and retry" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)
    assert {:ok, {:send, _, attempt, _}} = CorrelationDelivery.begin_attempt(batch.id, at())
    set_notification_adapter(:off)

    assert {:ok, _} = CorrelationDelivery.finish(batch.id, attempt.id, {:ok, :smtp}, at())
    sample(a, "OK", 2)
    sample(b, "OK", 2)

    assert {:ok, :delivery_disabled} = CorrelationDelivery.begin_attempt(batch.id, at())

    assert Mondek.CorrelationDeliveryWorker.perform(%Oban.Job{args: %{"batch_id" => batch.id}}) ==
             {:snooze, 30}

    held = Repo.get!(CorrelationBatch, batch.id)
    assert held.status == "accepted"
    assert held.terminal_status == "waiting"
    assert held.terminal_attempts == 0
    assert Repo.aggregate(Mondek.CorrelationAttempt, :count) == 1

    Application.put_env(:mondek, :notification_adapter, :webhook)

    assert {:ok, {:send, _, terminal, payload}} =
             CorrelationDelivery.begin_attempt(batch.id, at())

    assert {:ok, _} = CorrelationDelivery.finish(batch.id, terminal.id, {:error, :timeout}, at())
    Application.put_env(:mondek, :notification_adapter, :off)

    assert {:ok, :delivery_disabled} = CorrelationDelivery.begin_attempt(batch.id, at())
    assert Repo.get!(CorrelationBatch, batch.id).terminal_attempts == 1
    assert Repo.aggregate(Mondek.CorrelationAttempt, :count) == 2

    Application.put_env(:mondek, :notification_adapter, :webhook)
    assert {:ok, {:send, _, retry, ^payload}} = CorrelationDelivery.begin_attempt(batch.id, at())
    assert {:ok, _} = CorrelationDelivery.finish(batch.id, retry.id, {:ok, :smtp}, at())
    assert Repo.get!(CorrelationBatch, batch.id).terminal_status == "accepted"
  end

  test "exact batching preserves evidence and separate accepted coverage" do
    a = incident("Network")
    b = incident("App")
    id = create_case([a, b])
    control(id, "enable")
    x = occurrence(a)
    y = occurrence(b)
    assert {:ok, {:gated, 1}} = NotificationWorker.begin_attempt(x.id, at())
    batch = Repo.one!(CorrelationBatch)
    assert length(batch.payload["members"]) == 2
    assert batch.status == "pending"
    assert {:ok, {:send, _, attempt, payload}} = CorrelationDelivery.begin_attempt(batch.id, at())
    assert Repo.get!(CorrelationCredit, x.id).spent == 1
    refute Repo.exists?(from t in Attempt, where: t.occurrence_id == ^x.id)
    assert payload["members"] == batch.payload["members"]

    CorrelationDelivery.finish(
      batch.id,
      attempt.id,
      {:ok, {{~c"HTTP/1.1", 204, ~c""}, [], ""}},
      at()
    )

    assert Repo.get!(Occurrence, x.id).status == "superseded"
    assert Repo.get!(Occurrence, x.id).payload == x.payload
    assert Repo.aggregate(CorrelationReservation, :count) == 2
    assert {:ok, :superseded} = NotificationWorker.begin_attempt(y.id, at())
  end

  test "failed batch releases originals with spent credit and no renewal" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    x = occurrence(a)
    NotificationWorker.begin_attempt(x.id, at())
    batch = Repo.one!(CorrelationBatch)
    {:ok, {:send, _, attempt, _}} = CorrelationDelivery.begin_attempt(batch.id, at())
    CorrelationDelivery.finish(batch.id, attempt.id, {:error, :receiver}, at())
    assert {:ok, {_, _}} = NotificationWorker.begin_attempt(x.id, at())
    assert Repo.get!(CorrelationCredit, x.id).spent == 2
    assert Repo.aggregate(CorrelationBatch, :count) == 1
  end

  test "ack witnesses preserve transient escalation and fallback" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "acknowledge")
    assert CaseControls.data(id, at()).active
    assert {:ok, {:gated, _}} = NotificationWorker.begin_attempt(occurrence(a).id, at())

    assert disposition(
             ingest(
               measurement("CRIT", 2, %{
                 "assignment_id" => a.assignment_id,
                 "results" => [
                   %{
                     "key" => "capacity",
                     "health" => "CRIT",
                     "summary" => "Failure",
                     "source_at" => "2009-09-15T08:00:00.010000Z",
                     "impacts" => [%{"key" => "writes", "label" => "Writes"}]
                   }
                 ]
               }),
               at()
             )
           ) == "current"

    ingest(measurement("CRIT", 3, %{"assignment_id" => a.assignment_id}), at())
    refute CaseControls.data(id, at()).active
    assert {:ok, _} = CorrelationDelivery.reconcile(id)
    assert CaseControls.latest(id).ended_at
  end

  test "topology detachment ends ack and pending reservations" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())

    p = %{
      "action" => "detach",
      "case_id" => id,
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Independent",
      "episodes" => [%{"type" => "individual", "id" => b.id}]
    }

    {:ok, r} = Correlations.preview(p, at())
    {:ok, _} = Correlations.apply(r["review_token"], at())
    assert Repo.one!(CorrelationBatch).status == "released"
  end

  test "recovered parent preserves acknowledgement; all ended closes it" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "acknowledge")
    ingest(measurement("OK", 2, %{"assignment_id" => a.assignment_id}), at())
    assert CaseControls.data(id, at()).active
    ingest(measurement("OK", 2, %{"assignment_id" => b.assignment_id}), at())
    refute CaseControls.data(id, at()).active
  end

  test "batch timeout fallback does not lose late acceptance" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)
    {:ok, {:send, _, attempt, _}} = CorrelationDelivery.begin_attempt(batch.id, at())

    assert {:ok, :wait} =
             CorrelationDelivery.begin_attempt(batch.id, DateTime.add(at(), 61, :second))

    assert Repo.get!(CorrelationBatch, batch.id).status == "released"

    assert {:ok, _} =
             CorrelationDelivery.finish(
               batch.id,
               attempt.id,
               {:ok, :smtp},
               DateTime.add(at(), 62, :second)
             )

    assert Repo.get!(CorrelationBatch, batch.id).status == "accepted"

    refute Repo.exists?(
             from r in CorrelationReservation,
               where: r.batch_id == ^batch.id and r.status == "reserved"
           )
  end

  test "toggle batching preserves acknowledgement and native budget exhaustion commits" do
    a = incident("A")
    id = create_case([a])
    control(id, "acknowledge")
    control(id, "enable")
    control(id, "disable")
    assert CaseControls.data(id, at()).active
    control(id, "end")
    x = occurrence(a)
    credit = Repo.get!(CorrelationCredit, x.id)

    Repo.update_all(from(c in CorrelationCredit, where: c.occurrence_id == ^x.id),
      set: [spent: credit.limit]
    )

    assert {:ok, :exhausted} = NotificationWorker.begin_attempt(x.id, at())
    assert Repo.get!(Occurrence, x.id).status == "exhausted"
  end

  defp sample(i, health, n) do
    at = DateTime.add(at(), n, :second)
    t = Mondek.Monitoring.iso(at)

    assert disposition(
             ingest(
               measurement(health, n, %{
                 "assignment_id" => i.assignment_id,
                 "started_at" => t,
                 "evaluated_at" => t,
                 "results" => [
                   %{
                     "key" => "capacity",
                     "health" => health,
                     "summary" => "Sample",
                     "source_at" => t
                   }
                 ]
               }),
               at
             )
           ) == "current"
  end

  test "abandoned batch fallback still respects case acknowledgement" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    o = occurrence(a)
    NotificationWorker.begin_attempt(o.id, at())
    batch = Repo.one!(CorrelationBatch)
    CorrelationDelivery.begin_attempt(batch.id, at())
    control(id, "acknowledge")

    assert {:ok, {:gated, _}} =
             NotificationWorker.begin_attempt(o.id, DateTime.add(at(), 61, :second))

    assert CaseControls.data(id, at()).active
  end

  test "terminal obligation retains exact episodes through detach" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)
    {:ok, {:send, _, t, _}} = CorrelationDelivery.begin_attempt(batch.id, at())
    CorrelationDelivery.finish(batch.id, t.id, {:ok, :smtp}, at())

    p = %{
      "action" => "detach",
      "case_id" => id,
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Move",
      "episodes" => [%{"type" => "individual", "id" => b.id}]
    }

    {:ok, r} = Correlations.preview(p, at())
    Correlations.apply(r["review_token"], at())
    sample(a, "OK", 2)

    assert {:ok, :wait} =
             CorrelationDelivery.begin_attempt(batch.id, DateTime.add(at(), 3, :second))

    sample(b, "OK", 2)

    assert {:ok, {:send, _, attempt, payload}} =
             CorrelationDelivery.begin_attempt(batch.id, DateTime.add(at(), 4, :second))

    assert payload["scope"] == "All episodes in this notification batch ended"
    assert length(payload["members"]) == 2
    assert payload["kind"] == "resolved"
    CorrelationDelivery.finish(batch.id, attempt.id, {:ok, :smtp}, at())
    assert Repo.get!(CorrelationBatch, batch.id).terminal_status == "accepted"
  end

  test "real receiver gets committed exact batch and immutable terminal" do
    old = Application.fetch_env!(:mondek, :webhook_url)

    start_supervised!(
      {Bandit,
       plug: {Mondek.CorrelationReceiptServer, [owner: self()]}, ip: {127, 0, 0, 1}, port: 58991}
    )

    on_exit(fn -> Application.put_env(:mondek, :webhook_url, old) end)
    port = 58991
    Application.put_env(:mondek, :webhook_url, "http://127.0.0.1:#{port}/webhook")
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)

    Repo.update_all(CorrelationBatch,
      set: [deadline: DateTime.add(Monitoring.now(), 30, :second)]
    )

    assert {:snooze, 2} =
             Mondek.CorrelationDeliveryWorker.perform(%Oban.Job{args: %{"batch_id" => batch.id}})

    assert_receive {:receipt, payload}
    assert length(payload["members"]) == 2
    assert Repo.one!(Mondek.CorrelationAttempt).status == "accepted"
    sample(a, "OK", 2)
    sample(b, "OK", 2)

    assert {:snooze, 2} =
             Mondek.CorrelationDeliveryWorker.perform(%Oban.Job{args: %{"batch_id" => batch.id}})

    assert_receive {:receipt, terminal}, 1000
    assert terminal["kind"] == "resolved"
    assert terminal["failure_batch_id"] == batch.id
    assert length(terminal["members"]) == 2
  end

  test "concurrent batch completions and detach retain exact accepted coverage" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)
    {:ok, {:send, _, attempt, _}} = CorrelationDelivery.begin_attempt(batch.id, at())

    p = %{
      "action" => "detach",
      "case_id" => id,
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Move",
      "episodes" => [%{"type" => "individual", "id" => b.id}]
    }

    {:ok, r} = Correlations.preview(p, at())

    one =
      Task.async(fn -> CorrelationDelivery.finish(batch.id, attempt.id, {:ok, :smtp}, at()) end)

    two = Task.async(fn -> Correlations.apply(r["review_token"], at()) end)
    assert {:ok, _} = Task.await(one, 5000)
    assert {:ok, _} = Task.await(two, 5000)
    assert Repo.get!(CorrelationBatch, batch.id).status == "accepted"
    assert Repo.aggregate(CorrelationReservation, :count) == 2
    assert {:ok, :superseded} = NotificationWorker.begin_attempt(occurrence(a).id, at())
  end

  test "native witness transition blocked behind case lock invalidates later review" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "acknowledge")

    proposal = %{
      "action" => "acknowledge",
      "note" => "New review",
      "request_id" => Ecto.UUID.generate()
    }

    {:ok, r} = CaseControls.preview(id, proposal, at())
    parent = self()

    task =
      Repo.transaction(fn ->
        Mondek.Correlations.lock!()

        CaseControls.lock_owners!([
          %{"type" => "individual", "id" => a.id},
          %{"type" => "individual", "id" => b.id}
        ])

        task =
          Task.async(fn ->
            send(parent, :started)
            CaseControls.apply(r["review_token"], at())
          end)

        assert_receive :started
        assert Task.yield(task, 30) == nil

        Monitoring.change(Repo.get!(Incident, a.id), %{
          impacts: [%{"key" => "new", "label" => "New"}],
          attention_revision: a.attention_revision + 1
        })

        task
      end)

    {:ok, t} = task
    assert {:error, :review_changed} = Task.await(t, 5000)
    refute CaseControls.data(id, at()).active
  end

  test "repair selects orphan after more than 25 already active batches" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)

    for _ <- 1..26 do
      copy =
        Repo.insert!(%{
          batch
          | id: Ecto.UUID.generate(),
            inserted_at: DateTime.add(batch.inserted_at, -1, :second)
        })

      CorrelationDelivery.enqueue!(%{"batch_id" => copy.id})
    end

    Repo.update_all(from(j in Oban.Job, where: fragment("?->>'batch_id'", j.args) == ^batch.id),
      set: [state: "discarded"]
    )

    Repo.transaction(fn -> CorrelationDelivery.repair!() end)

    assert Repo.exists?(
             from j in Oban.Job,
               where: fragment("?->>'batch_id'", j.args) == ^batch.id and j.state == "available"
           )
  end

  test "retention protects unfinished and recent batch terminal work" do
    a = incident("A")
    b = incident("B")
    id = create_case([a, b])
    control(id, "enable")
    NotificationWorker.begin_attempt(occurrence(a).id, at())
    batch = Repo.one!(CorrelationBatch)
    {:ok, {:send, _, attempt, _}} = CorrelationDelivery.begin_attempt(batch.id, at())
    CorrelationDelivery.finish(batch.id, attempt.id, {:ok, :smtp}, at())
    sample(a, "OK", 2)
    sample(b, "OK", 2)
    Repo.update_all(Oban.Job, set: [state: "completed"])
    assert {:ok, _} = Mondek.Sweeper.sweep(Monitoring.now())
    assert Repo.get(CorrelationBatch, batch.id)

    {:ok, {:send, _, terminal, _}} =
      CorrelationDelivery.begin_attempt(batch.id, DateTime.add(at(), 4, :second))

    CorrelationDelivery.finish(batch.id, terminal.id, {:ok, :smtp}, Monitoring.now())
    assert {:ok, _} = Mondek.Sweeper.sweep(Monitoring.now())
    assert Repo.get(CorrelationBatch, batch.id)
    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(Monitoring.now(), 8_640_000, :second))
    refute Repo.get(CorrelationBatch, batch.id)
  end
end

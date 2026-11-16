# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationsTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Correlations, CorrelationCase, CorrelationMembership}

  def incident(label) do
    {:ok, a} =
      create_source_fixture("python", label, %{
        "path" => "/",
        "warn_percent" => 80,
        "crit_percent" => 90
      })

    connect(%{"prepared" => %{a["id"] => 1}})
    ingest(measurement("CRIT", 1, %{"assignment_id" => a["id"]}))
    Repo.get_by!(Incident, assignment_id: a["id"])
  end

  def ref(i), do: %{"type" => "individual", "id" => i.id}

  def proposal(action, episodes, extra \\ %{}) do
    Map.merge(
      %{
        "action" => action,
        "request_id" => Ecto.UUID.generate(),
        "reason" => "Investigating related failures",
        "episodes" => Enum.map(episodes, &ref/1)
      },
      extra
    )
    |> then(fn p ->
      allowed =
        case action do
          "create" -> ~w(action request_id reason episodes title anchor)
          "split" -> ~w(action request_id reason episodes title anchor case_id)
          "anchor" -> ~w(action request_id reason anchor case_id)
          "merge" -> ~w(action request_id reason case_id other_case_id)
          _ -> ~w(action request_id reason episodes case_id)
        end

      Map.take(Map.put_new(p, "title", "Cluster outage"), allowed)
    end)
  end

  def apply!(p) do
    assert {:ok, review} = Correlations.preview(p)
    assert {:ok, receipt} = Correlations.apply(review["review_token"])
    receipt["case_id"]
  end

  test "native ingestion, controls and delivery work survive grouping" do
    a = incident("Network")
    b = incident("App")
    occurrences = Repo.all(Occurrence)
    id = apply!(proposal("create", [a, b], %{"anchor" => ref(a)}))
    assert Correlations.detail(id)["case"]["open_count"] == 2
    assert Repo.all(Occurrence) == occurrences
    assert Repo.aggregate(Mondek.Control, :count) == 0
    assert {:ok, _} = reviewed_acknowledgement_fixture(b.id, 60, "Keep this control")
    apply!(proposal("detach", [b], %{"case_id" => id}))
    assert Repo.get!(Incident, b.id).acknowledgement_mode == "until"
    assert Correlations.detail(id)["case"]["member_count"] == 1
    assert Enum.any?(Correlations.detail(id)["members"]["items"], &(&1["end_reason"] == "detach"))
  end

  test "review freshness and idempotency" do
    a = incident("A")
    b = incident("B")
    c = incident("C")
    p = proposal("create", [a, b])
    {:ok, review} = Correlations.preview(p)
    {:ok, receipt} = Correlations.apply(review["review_token"])
    assert {:ok, %{"replayed" => true}} = Correlations.apply(review["review_token"])
    id = receipt["case_id"]
    {:ok, stale} = Correlations.preview(proposal("attach", [c], %{"case_id" => id}))
    apply!(proposal("anchor", [], %{"case_id" => id, "anchor" => ref(a)}))
    assert {:error, :review_changed} = Correlations.apply(stale["review_token"])
  end

  test "recovered anchor does not close case, but resolved cases never reopen" do
    a = incident("A")
    b = incident("B")
    c = incident("C")
    id = apply!(proposal("create", [a, b], %{"anchor" => ref(a)}))
    ingest(measurement("OK", 2, %{"assignment_id" => a.assignment_id}))
    assert Correlations.detail(id)["case"]["status"] == "open"
    {:ok, review} = Correlations.preview(proposal("attach", [c], %{"case_id" => id}))
    ingest(measurement("OK", 2, %{"assignment_id" => b.assignment_id}))
    assert Correlations.detail(id)["case"]["status"] == "closed"
    assert {:error, :case_closed} = Correlations.apply(review["review_token"])
  end

  test "split and merge preserve intervals and cannot copy anchors" do
    a = incident("A")
    b = incident("B")
    id = apply!(proposal("create", [a, b], %{"anchor" => ref(a)}))

    new =
      apply!(
        proposal("split", [b], %{"case_id" => id, "title" => "App impact", "anchor" => ref(b)})
      )

    assert Correlations.detail(new)["case"]["anchor"] == ref(b)
    assert Correlations.detail(id)["case"]["anchor"] == ref(a)
    apply!(proposal("merge", [], %{"case_id" => id, "other_case_id" => new}))
    assert Correlations.detail(new)["case"]["status"] == "closed"
    assert Correlations.detail(id)["case"]["member_count"] == 2
  end

  test "opposite concurrent grouping has one winner" do
    a = incident("A")
    b = incident("B")
    {:ok, x} = Correlations.preview(proposal("create", [a, b]))
    {:ok, y} = Correlations.preview(proposal("create", [b, a]))

    tasks =
      for token <- [x["review_token"], y["review_token"]],
          do: Task.async(fn -> Correlations.apply(token) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Repo.aggregate(CorrelationCase, :count) == 1

    assert Repo.aggregate(from(m in CorrelationMembership, where: is_nil(m.ended_at)), :count) ==
             2
  end

  test "periodic failure evidence does not invalidate grouping review" do
    a = incident("A")
    {:ok, review} = Correlations.preview(proposal("create", [a]))
    ingest(measurement("CRIT", 2, %{"assignment_id" => a.assignment_id}))
    assert {:ok, _} = Correlations.apply(review["review_token"])
  end

  test "detaching last failure closes at edit time, not recovered anchor time" do
    a = incident("A")
    b = incident("B")
    id = apply!(proposal("create", [a, b]))
    ingest(measurement("OK", 2, %{"assignment_id" => a.assignment_id}))
    t = DateTime.add(at(), 90, :second)
    p = proposal("detach", [b], %{"case_id" => id})
    {:ok, review} = Correlations.preview(p, t)
    assert {:ok, _} = Correlations.apply(review["review_token"], t)
    assert Correlations.detail(id)["case"]["closed_at"] == Monitoring.iso(t)
    assert Correlations.detail(id)["case"]["closure_reason"] == "detach"
  end

  test "recovered members can be removed while peers fail" do
    a = incident("A")
    b = incident("B")
    id = apply!(proposal("create", [a, b]))
    ingest(measurement("OK", 2, %{"assignment_id" => a.assignment_id}))
    apply!(proposal("detach", [a], %{"case_id" => id}))
    assert Correlations.detail(id)["case"]["status"] == "open"
  end

  test "invalid fields and anchors are rejected without writes" do
    a = incident("A")
    b = incident("B")
    id = apply!(proposal("create", [a]))
    proposal = proposal("anchor", [], %{"case_id" => id, "anchor" => ref(b)})
    assert {:error, {:invalid, _}} = Correlations.preview(Map.put(proposal, "episodes", [ref(b)]))

    assert {:error, {:invalid, _}} =
             Correlations.preview(
               Map.merge(proposal("attach", [b], %{"case_id" => id}), %{"anchor" => ref(b)})
             )

    assert Repo.aggregate(CorrelationMembership, :count) == 1
  end

  test "retention protects current and historical members" do
    a = incident("A")
    b = incident("B")
    id = apply!(proposal("create", [a, b]))
    apply!(proposal("detach", [a], %{"case_id" => id}))
    ingest(measurement("OK", 2, %{"assignment_id" => a.assignment_id}))
    Repo.update_all(Occurrence, set: [status: "delivered"])
    Repo.update_all(Oban.Job, set: [state: "completed"])
    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(Monitoring.now(), 8_640_000, :second))
    assert Repo.get!(Incident, a.id)
    assert Correlations.detail(id)
    ingest(measurement("OK", 2, %{"assignment_id" => b.assignment_id}))
    Repo.update_all(Occurrence, set: [status: "delivered"])
    Repo.update_all(Oban.Job, set: [state: "completed"])
    assert {:ok, _} = Mondek.Sweeper.sweep(DateTime.add(Monitoring.now(), 8_640_000, :second))
    refute Repo.get(CorrelationCase, id)
    refute Repo.get(Incident, a.id)
  end
end

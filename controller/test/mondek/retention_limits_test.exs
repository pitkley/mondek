# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RetentionLimitsTest do
  use Mondek.DataCase, async: false
  alias Mondek.Sweeper

  test "a full pass schedules catch-up while a drained pass returns to the ordinary cadence" do
    connect()
    opening = measurement("CRIT", 1)
    assert disposition(ingest(opening)) == "current"
    insert_receipts(opening, 1001, DateTime.add(Monitoring.now(), -40 * 86_400))

    assert {:noreply, 0} = Sweeper.handle_info(:tick, 0)
    assert Repo.aggregate(Observation, :count) == 2
    assert {:noreply, 1} = Sweeper.handle_info(:tick, 0)
    assert Repo.aggregate(Observation, :count) == 1
    assert Repo.get!(Observation, opening["id"])
  end

  test "protected oldest evidence cannot starve later eligible receipts across committed passes" do
    connect()
    opening = measurement("CRIT", 1)
    assert disposition(ingest(opening)) == "current"
    insert_receipts(opening, 5, DateTime.add(at(), 1))
    future = DateTime.add(at(), 40 * 86_400)

    for expected <- [4, 2, 1] do
      # A new process reconstructs candidates solely from committed state.
      assert {:ok, %{deleted: %{observations: deleted}, more?: more?}} =
               Task.async(fn -> Sweeper.sweep(future, 2) end) |> Task.await()

      assert Repo.aggregate(Observation, :count) == expected
      assert deleted == if(expected == 1, do: 1, else: 2)
      assert more? == (expected != 1)
      assert Repo.get!(Observation, opening["id"]).payload == opening
      assert Repo.one!(Incident).status == "open"
      assert Repo.one!(Occurrence).status == "pending"
    end

    assert {:ok, %{deleted: %{observations: 0}, more?: false}} = Sweeper.sweep(future, 2)
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").last_sequence == 1
    assert disposition(ingest(opening)) == "duplicate"
  end

  @tag timeout: 60_000
  test "age and count cleanup share a budget and preserve the global newest 100000 receipts" do
    connect()
    opening = measurement("CRIT", 1)
    assert disposition(ingest(opening)) == "current"
    future = DateTime.add(at(), 40 * 86_400)
    insert_receipts(opening, 1, DateTime.add(at(), 1))
    insert_receipts(opening, 100_003, future)

    oldest_fresh =
      Repo.all(
        from o in Observation,
          where: o.received_at == ^future,
          order_by: o.id,
          limit: 3,
          select: o.id
      )

    assert {:ok, %{deleted: %{observations: 2}, more?: true}} = Sweeper.sweep(future, 2)
    assert Repo.aggregate(Observation, :count) == 100_003
    assert {:ok, %{deleted: %{observations: 2}, more?: true}} = Sweeper.sweep(future, 2)
    assert {:ok, %{deleted: %{observations: 0}, more?: false}} = Sweeper.sweep(future, 2)
    assert Repo.aggregate(Observation, :count) == 100_001
    refute Repo.exists?(from o in Observation, where: o.id in ^oldest_fresh)
    assert Repo.get!(Observation, opening["id"]).payload == opening

    assert Repo.aggregate(from(o in Observation, where: o.received_at == ^future), :count) ==
             100_000
  end

  defp insert_receipts(source, count, received_at) do
    Repo.query!(
      """
      INSERT INTO observations (id,assignment_id,installation_id,session_id,generation,sequence,
        started_at,evaluated_at,received_at,payload,disposition)
      SELECT gen_random_uuid(),assignment_id,installation_id,session_id,generation,100+n,
        started_at,evaluated_at,$3,payload,'historical'
      FROM observations CROSS JOIN generate_series(1,$1::integer) n WHERE id=$2::uuid
      """,
      [count, Ecto.UUID.dump!(source["id"]), received_at]
    )
  end
end

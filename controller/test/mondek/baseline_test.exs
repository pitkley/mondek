# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.BaselineTest do
  use Mondek.DataCase, async: false

  test "fresh schema has current evidence guards without obsolete storage" do
    %{rows: columns} =
      Repo.query!(
        "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='public'"
      )

    for column <- [
          ["assignments", "maintenance_until"],
          ["assignments", "maintenance_reason"],
          ["runners", "slot"],
          ["runners", "inventory_mode"],
          ["source_inventories", "skipped_checks"],
          ["maintenance_windows", "legacy"]
        ],
        do: refute(column in columns)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM pg_proc WHERE pronamespace='public'::regnamespace AND proname LIKE 'watchpost_%'"
             )

    assert %{rows: [[8]]} =
             Repo.query!(
               "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('immutable_condition_fact','immutable_condition_identity','immutable_contribution_identity','immutable_monitoring_incident','immutable_monitoring_owner','immutable_occurrence','immutable_occurrence_evidence','valid_condition_occurrence')"
             )

    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)

    assert_raise Postgrex.Error, ~r/immutable/, fn ->
      Repo.update_all(from(o in Occurrence, where: o.id == ^occurrence.id), set: [payload: %{}])
    end

    assert Repo.get!(Occurrence, occurrence.id).payload == occurrence.payload
  end

  test "baseline refuses retained migration history before scheduling DDL" do
    migration = Mondek.Repo.Migrations.CurrentBaseline

    unless Code.ensure_loaded?(migration),
      do:
        Code.require_file(
          Path.expand("../../priv/repo/migrations/00000000000001_current_baseline.exs", __DIR__)
        )

    assert_raise RuntimeError, ~r/requires a fresh database/, fn ->
      Ecto.Migrator.up(Repo, 2, migration, log: false)
    end

    assert Repo.aggregate(Assignment, :count) == 3
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM schema_migrations")
  end
end

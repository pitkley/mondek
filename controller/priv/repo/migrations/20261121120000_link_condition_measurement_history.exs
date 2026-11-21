# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.LinkConditionMeasurementHistory do
  use Ecto.Migration

  def change do
    alter table(:result_streams) do
      add :predecessor_stream_id,
          references(:result_streams, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:result_streams, [:predecessor_stream_id])

    execute(backfill_sql(), "UPDATE result_streams SET predecessor_stream_id = NULL")
  end

  @doc false
  def backfill_sql do
    """
    WITH boundaries AS (
      SELECT incoming.id AS incoming_id, outgoing.id AS outgoing_id,
        count(*) OVER (PARTITION BY incoming.id) AS outgoing_count,
        count(*) OVER (PARTITION BY outgoing.id) AS incoming_count
      FROM result_streams incoming
      JOIN result_streams outgoing
        ON outgoing.assignment_id = incoming.assignment_id
        AND outgoing.result_key = incoming.result_key
        AND outgoing.retirement_generation = incoming.admission_generation
        AND outgoing.admission_generation < incoming.admission_generation
    )
    UPDATE result_streams incoming SET predecessor_stream_id = outgoing.id
    FROM boundaries b
    JOIN result_streams outgoing ON outgoing.id = b.outgoing_id
    WHERE incoming.id = b.incoming_id
      AND b.outgoing_count = 1 AND b.incoming_count = 1
      AND outgoing.retired_at IS NOT NULL
      AND outgoing.environment IS NOT DISTINCT FROM incoming.environment
      AND outgoing.target->>'key' = incoming.target->>'key'
      AND outgoing.target->>'kind' = incoming.target->>'kind'
      AND ROW(outgoing.condition->>'namespace', outgoing.condition->>'key')
        IS DISTINCT FROM ROW(incoming.condition->>'namespace', incoming.condition->>'key')
      AND EXISTS (
        SELECT 1 FROM controls c WHERE c.stream_id = outgoing.id
          AND c.assignment_id = outgoing.assignment_id AND c.kind = 'condition_changed'
      )
    """
  end
end

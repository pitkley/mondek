# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Sweeper do
  @moduledoc "Reconstructable freshness ticks and reference-aware history cleanup."
  use GenServer
  import Ecto.Query
  alias Mondek.{Repo, Monitoring, MonitoringLoss, Occurrence, Conditions}
  @retention_batch_size 1000
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_),
    do:
      (
        Process.send_after(self(), :tick, 1000)
        {:ok, 0}
      )

  def handle_info(:tick, count) do
    MonitoringLoss.reconcile(Monitoring.now())
    Monitoring.notify()
    wake_held_notifications(Monitoring.now())

    next_count =
      if rem(count, 60) == 0 do
        case sweep(Monitoring.now()) do
          {:ok, %{more?: true}} -> 0
          _ -> count + 1
        end
      else
        count + 1
      end

    Process.send_after(self(), :tick, 1000)
    {:noreply, next_count}
  end

  @doc "Wake durable holds after a gate edit, including edits racing Oban's snooze commit."
  def wake_held_notifications(at) do
    result =
      Repo.transaction(fn ->
        candidates =
          Repo.all(
            from j in Oban.Job,
              join: o in Occurrence,
              on: fragment("?->>'occurrence_id'", j.args) == type(o.id, :string),
              where:
                j.worker == "Mondek.NotificationWorker" and
                  j.state in ["scheduled", "retryable"] and
                  o.status not in ["delivered", "exhausted"] and
                  fragment("(?->>'mondek_hold_revision') IS NOT NULL", j.args) and
                  fragment("(?->>'mondek_hold_revision')::bigint", j.args) != o.gate_revision,
              order_by: j.id,
              limit: 1000,
              select: j.id
          )

        Repo.update_all(
          from(j in Oban.Job,
            where: j.id in ^candidates and j.state in ["scheduled", "retryable"]
          ),
          set: [scheduled_at: at, state: "available"]
        )
      end)

    if match?({:ok, {count, _}} when count > 0, result),
      do: Oban.Notifier.notify(Oban, :insert, %{"queue" => "notifications"})

    result
  end

  @doc "One committed cleanup pass; limits eligible roots, not cascaded rows or elapsed time."
  def sweep(at, limit \\ @retention_batch_size)
      when is_integer(limit) and limit in 1..@retention_batch_size do
    # Each full pass yields before the next tick. Re-selecting durable candidates
    # after commit makes catch-up reconstructable after restart without a cursor.
    # Lock ownership is documented in docs/TRANSACTIONS-AND-LOCKS.md.
    Repo.transaction(fn ->
      # Retention removes window rows after acquiring incident/condition locks.
      # Take the gate first, matching edits, so cleanup cannot invert that order.
      Mondek.Maintenance.lock!(:shared)
      # Exhausted jobs remain a visible operator backlog instead of pretending that
      # a retry is still scheduled. Their occurrences and attempts are retained.
      candidates =
        Repo.all(
          from j in Oban.Job,
            join: o in Occurrence,
            on: fragment("?->>'occurrence_id'", j.args) == type(o.id, :string),
            where:
              j.worker == "Mondek.NotificationWorker" and j.state == "discarded" and
                o.status in ["pending", "retrying", "delivering"],
            distinct: true,
            select: fragment("?->>'occurrence_id'", j.args),
            limit: 1000
        )

      # Operator retry creates a new job for the same immutable occurrence. Lock
      # its check before re-reading job state so an old discarded job cannot
      # exhaust a newly queued budget, including a concurrent retry request.
      assignment_ids =
        Repo.all(
          from o in Occurrence,
            join: i in Mondek.Incident,
            on: i.id == o.incident_id,
            where: o.id in ^candidates,
            select: i.assignment_id,
            distinct: true,
            order_by: i.assignment_id
        )

      Enum.each(assignment_ids, &Monitoring.lock_assignment/1)

      condition_ids =
        Repo.all(
          from o in Occurrence,
            where: o.id in ^candidates and not is_nil(o.condition_incident_id),
            select: o.condition_incident_id,
            distinct: true
        )

      Conditions.lock_ids!(condition_ids)

      # Ingestion holds assignment/condition locks before reducing monitoring
      # gaps. Keep that order while serializing exhaustion and history cleanup.
      MonitoringLoss.lock!()

      latest =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Mondek.NotificationWorker" and
                fragment("?->>'occurrence_id'", j.args) in ^candidates,
            distinct: fragment("?->>'occurrence_id'", j.args),
            order_by: [desc: j.id],
            select: {fragment("?->>'occurrence_id'", j.args), j.state}
        )

      exhausted = for {id, "discarded"} <- latest, do: id

      Repo.update_all(
        from(o in Occurrence,
          where: o.id in ^exhausted and o.status in ["retrying", "delivering", "pending"]
        ),
        set: [status: "exhausted"]
      )

      Repo.all(
        from o in Occurrence,
          where: o.id in ^exhausted and not is_nil(o.condition_incident_id),
          select: o.condition_incident_id,
          distinct: true
      )
      |> Enum.each(&Conditions.request_gate_wake!/1)

      policy = Mondek.Retention.policy()
      receipt_cutoff = DateTime.add(at, -policy.receipt_days * 86_400)
      history_cutoff = DateTime.add(at, -policy.history_days * 86_400)
      # Current state, unresolved episode/notification evidence and installation
      # high-water marks survive either receipt retention boundary.
      protect_unresolved = """
      AND NOT EXISTS (SELECT 1 FROM occurrences n JOIN incidents i ON i.id=n.incident_id
        WHERE n.payload->>'observation_id'=observations.id::text
        AND (i.status='open' OR n.status NOT IN ('delivered','superseded')))
      AND NOT EXISTS (SELECT 1 FROM incidents i WHERE observations.id IN
        (i.opening_observation_id,i.latest_observation_id,i.closing_observation_id))
      AND NOT EXISTS (SELECT 1 FROM condition_incidents g WHERE g.closing_observation_id=observations.id)
      AND NOT EXISTS (SELECT 1 FROM condition_facts f WHERE f.opening_observation_id=observations.id)
      AND NOT EXISTS (SELECT 1 FROM occurrence_evidence e WHERE e.observation_id=observations.id)
      AND NOT EXISTS (SELECT 1 FROM publisher_lifecycle_evidence e WHERE e.observation_id=observations.id)
      AND NOT EXISTS (SELECT 1 FROM monitoring_gaps g
        WHERE g.details->>'observation_id'=observations.id::text)
      AND NOT EXISTS (SELECT 1 FROM monitoring_incidents m, unnest(m.member_snapshot) member
        WHERE member->>'observation_id'=observations.id::text)
      AND NOT EXISTS (SELECT 1 FROM monitoring_incidents m, unnest(m.closing_evidence) evidence
        WHERE evidence->>'observation_id'=observations.id::text)
      AND NOT EXISTS (SELECT 1 FROM occurrences n
        WHERE n.monitoring_incident_id IS NOT NULL
        AND (n.payload->'member_snapshot' @> jsonb_build_array(jsonb_build_object('observation_id',observations.id::text))
          OR n.payload->'closing_evidence' @> jsonb_build_array(jsonb_build_object('observation_id',observations.id::text))))
      """

      # Keep unresolved incidents and unfinished/exhausted delivery work regardless
      # of age. Only terminal history is eligible for deletion.
      terminal = """
      SELECT i.id FROM incidents i WHERE i.status = 'closed' AND i.closed_at < $1 AND i.condition_incident_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM occurrences o WHERE o.incident_id=i.id AND o.status NOT IN ('delivered','superseded'))
      AND NOT EXISTS (SELECT 1 FROM oban_jobs j JOIN occurrences o ON j.args->>'occurrence_id'=o.id::text WHERE o.incident_id=i.id AND j.state NOT IN ('completed','cancelled','discarded'))
      ORDER BY i.closed_at,i.id LIMIT $2
      """

      # Freeze the parent set before deleting children: re-evaluating a limited
      # selector between statements can otherwise select different episodes.
      terminal_ids = Repo.query!(terminal, [history_cutoff, limit]).rows |> List.flatten()

      Repo.query!(
        "DELETE FROM attempts WHERE occurrence_id IN (SELECT id FROM occurrences WHERE incident_id = ANY($1::uuid[]))",
        [terminal_ids]
      )

      Repo.query!("DELETE FROM occurrences WHERE incident_id = ANY($1::uuid[])", [terminal_ids])
      Repo.query!("DELETE FROM incidents WHERE id = ANY($1::uuid[])", [terminal_ids])

      # A contribution's history belongs to the complete shared episode. Delete
      # only terminal groups with no unfinished delivery or active job; cascading
      # parent deletion removes the internally referenced facts/evidence together.
      terminal_conditions = """
      SELECT g.id FROM condition_incidents g WHERE g.status='closed' AND g.closed_at < $1
      AND NOT EXISTS (SELECT 1 FROM occurrences o WHERE o.condition_incident_id=g.id AND o.status NOT IN ('delivered','superseded'))
      AND NOT EXISTS (SELECT 1 FROM oban_jobs j JOIN occurrences o ON j.args->>'occurrence_id'=o.id::text WHERE o.condition_incident_id=g.id AND j.state NOT IN ('completed','cancelled','discarded'))
      ORDER BY g.closed_at,g.id LIMIT $2
      """

      condition_ids =
        Repo.query!(terminal_conditions, [history_cutoff, limit]).rows |> List.flatten()

      Repo.query!(
        "DELETE FROM attempts WHERE occurrence_id IN (SELECT id FROM occurrences WHERE condition_incident_id = ANY($1::uuid[]))",
        [condition_ids]
      )

      Repo.query!("DELETE FROM condition_incidents WHERE id = ANY($1::uuid[])", [condition_ids])

      controls =
        Repo.query!(
          """
          DELETE FROM controls WHERE id IN (SELECT id FROM controls
          WHERE condition_incident_id IS NULL AND monitoring_incident_id IS NULL AND (
            (incident_id IS NOT NULL AND inserted_at < $1
              AND NOT EXISTS (SELECT 1 FROM incidents i WHERE i.id=controls.incident_id))
            OR (incident_id IS NULL AND COALESCE(until,inserted_at) < $1))
          ORDER BY inserted_at,id LIMIT $2)
          """,
          [history_cutoff, limit]
        )

      monitoring_count = MonitoringLoss.prune!(history_cutoff, limit)

      # Remove evidence only after terminal parents and their immutable references
      # have expired. Still-retained contributions/facts protect their exact rows.
      aged_observations =
        Repo.query!(
          """
          DELETE FROM observations WHERE id IN (SELECT observations.id FROM observations WHERE received_at < $1
          AND NOT EXISTS (SELECT 1 FROM assignments a WHERE (a.retired_at IS NULL OR a.retired_at >= $2) AND observations.id::text IN
            (a.current->>'observation_id', a.current->>'confirmed_observation_id'))
          AND NOT EXISTS (SELECT 1 FROM result_streams s JOIN assignments a ON a.id=s.assignment_id WHERE (s.retired_at IS NULL OR s.retired_at >= $2) AND observations.id::text IN (s.current->>'observation_id',s.current->>'confirmed_observation_id'))
          #{protect_unresolved}
          ORDER BY received_at,id LIMIT $3)
          """,
          [receipt_cutoff, history_cutoff, limit]
        )

      # Age and count cleanup share one receipt budget. Protection is evaluated
      # before LIMIT so protected older rows cannot starve eligible newer rows.
      capped_observations =
        Repo.query!(
          """
          DELETE FROM observations WHERE id IN (SELECT observations.id FROM observations WHERE id IN (
            SELECT id FROM observations ORDER BY received_at DESC,id DESC OFFSET $3
          ) AND NOT EXISTS (SELECT 1 FROM assignments a WHERE (a.retired_at IS NULL OR a.retired_at >= $1) AND observations.id::text IN
            (a.current->>'observation_id', a.current->>'confirmed_observation_id'))
          AND NOT EXISTS (SELECT 1 FROM result_streams s JOIN assignments a ON a.id=s.assignment_id WHERE (s.retired_at IS NULL OR s.retired_at >= $1) AND observations.id::text IN (s.current->>'observation_id',s.current->>'confirmed_observation_id'))
          #{protect_unresolved}
          ORDER BY received_at,id LIMIT $2)
          """,
          [history_cutoff, limit - aged_observations.num_rows, policy.max_observations]
        )

      # A window's audit remains available while a retained incident in its
      # explicit scope could need it, even after a long hold has ended.
      monitoring_maintenance_match = """
      EXISTS (
        SELECT 1 FROM (
          SELECT details FROM monitoring_gaps
          UNION ALL
          SELECT unnest(member_snapshot) AS details FROM monitoring_incidents
          UNION ALL
          SELECT jsonb_array_elements(payload->'member_snapshot') AS details
            FROM occurrences WHERE monitoring_incident_id IS NOT NULL
        ) evidence
        WHERE maintenance_selections_match(
          CASE WHEN w.scope='selection' THEN w.selections ELSE ARRAY[
            jsonb_build_object('scope',w.scope,'assignment_id',w.assignment_id,
              'source_id',w.source_id,'environment',w.environment,
              'target_kind',w.target_kind,'target_key',w.target_key)] END,
          evidence.details->>'assignment_id',evidence.details->>'source_id',
          evidence.details->>'environment',evidence.details->'target'->>'kind',
          evidence.details->'target'->>'key')
      )
      """

      windows =
        Repo.query!(
          """
          DELETE FROM maintenance_windows WHERE id IN (SELECT w.id FROM maintenance_windows w
          WHERE w.series_id IS NULL AND COALESCE(w.cancelled_at,w.ends_at) < $1
            AND NOT EXISTS (
              SELECT 1 FROM incidents i
              JOIN assignments a ON a.id=i.assignment_id
              LEFT JOIN result_streams s ON s.id=i.stream_id
              WHERE (w.scope='check' AND w.assignment_id=a.id)
                OR (w.scope='target' AND w.source_id=a.source_id
                  AND w.environment IS NOT DISTINCT FROM i.environment
                  AND w.target_kind=s.target->>'kind' AND w.target_key=s.target->>'key')
                OR (w.scope='selection' AND maintenance_selections_match(w.selections,a.id,a.source_id,i.environment,s.target->>'kind',s.target->>'key'))
            )
            AND NOT (#{monitoring_maintenance_match})
          ORDER BY w.ends_at,w.id LIMIT $2)
          """,
          [history_cutoff, limit]
        )

      # Keep each finite series complete while any member is still upcoming or
      # retained incident history can need its scope. Parent deletion cascades
      # only after every member satisfies the ordinary retention conditions.
      series =
        Repo.query!(
          """
          DELETE FROM maintenance_series WHERE id IN (SELECT ms.id FROM maintenance_series ms
          WHERE NOT EXISTS (
            SELECT 1 FROM maintenance_windows w WHERE w.series_id=ms.id
              AND COALESCE(w.cancelled_at,w.ends_at) >= $1
          ) AND NOT EXISTS (
            SELECT 1 FROM maintenance_windows w
            JOIN incidents i ON true
            JOIN assignments a ON a.id=i.assignment_id
            LEFT JOIN result_streams s ON s.id=i.stream_id
            WHERE w.series_id=ms.id AND (
              (w.scope='check' AND w.assignment_id=a.id)
              OR (w.scope='target' AND w.source_id=a.source_id
                AND w.environment IS NOT DISTINCT FROM i.environment
                AND w.target_kind=s.target->>'kind' AND w.target_key=s.target->>'key')
              OR (w.scope='selection' AND maintenance_selections_match(w.selections,a.id,a.source_id,i.environment,s.target->>'kind',s.target->>'key'))
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM maintenance_windows w
            WHERE w.series_id=ms.id AND (#{monitoring_maintenance_match})
          )
          ORDER BY ms.id LIMIT $2)
          """,
          [history_cutoff, limit]
        )

      # Configuration records needed by any receipt or current authority are kept;
      # abandoned saved revisions retain the last 20 per fixed assignment.
      configurations =
        Repo.query!(
          """
          DELETE FROM configurations WHERE id IN (SELECT c.id FROM configurations c WHERE c.saved_at < $1
          AND c.id NOT IN (SELECT id FROM (SELECT id, row_number() OVER (PARTITION BY assignment_id ORDER BY generation DESC) AS n FROM configurations) ranked WHERE n <= 20)
          AND NOT EXISTS (SELECT 1 FROM observations o WHERE o.assignment_id=c.assignment_id AND o.generation=c.generation)
          AND NOT EXISTS (SELECT 1 FROM assignments a WHERE a.id=c.assignment_id AND a.retired_at IS NULL AND c.generation IN (a.desired_generation,a.authorized_generation,a.active_generation,a.observed_generation))
          ORDER BY c.saved_at,c.id LIMIT $2)
          """,
          [history_cutoff, limit]
        )

      counts = %{
        incidents: length(terminal_ids),
        condition_incidents: length(condition_ids),
        monitoring_incidents: monitoring_count,
        controls: controls.num_rows,
        observations: aged_observations.num_rows + capped_observations.num_rows,
        maintenance_windows: windows.num_rows,
        maintenance_series: series.num_rows,
        configurations: configurations.num_rows
      }

      %{deleted: counts, more?: Enum.any?(counts, fn {_kind, count} -> count == limit end)}
    end)
  end
end

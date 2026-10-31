# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Monitoring do
  @moduledoc "Transaction boundaries for configuration, trustworthy evidence and operator state."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Assignment,
    Configuration,
    Runner,
    Observation,
    Incident,
    Occurrence,
    Attempt,
    Control,
    ResultStream,
    Conditions
  }

  def overview(at \\ now(), runner_id \\ nil), do: Mondek.Inspection.overview(at, runner_id)

  def list_streams(filters \\ %{}, at \\ now()),
    do: Mondek.Inspection.list_streams(filters, at)

  def list_grouped_streams(filters \\ %{}, at \\ now()),
    do: Mondek.Inspection.list_grouped_streams(filters, at)

  def list_target_streams(filters \\ %{}, at \\ now()),
    do: Mondek.Inspection.list_target_streams(filters, at)

  def list_checks(filters \\ %{}, at \\ now()), do: Mondek.Inspection.list_checks(filters, at)

  def list_incidents(filters \\ %{}, at \\ now()),
    do: Mondek.Inspection.list_incidents(filters, at)

  def stream_inspection(id, at \\ now()), do: Mondek.Inspection.stream_inspection(id, at)

  def delivery_inspection(filters \\ %{}, at \\ now()),
    do: Mondek.Inspection.delivery_inspection(filters, at)

  def select_bulk_configuration(filters), do: Mondek.BulkConfiguration.select(filters)

  def prepare_bulk_configuration(selection, page \\ 1),
    do: Mondek.BulkConfiguration.prepare(selection, page)

  def preview_bulk_configuration(token, params, page \\ 1),
    do: Mondek.BulkConfiguration.preview(token, params, page)

  def apply_bulk_configuration(token, params),
    do: Mondek.BulkConfiguration.apply(token, params)

  def bulk_configuration_status(receipts, page \\ 1),
    do: Mondek.BulkConfiguration.status(receipts, page)

  def now, do: DateTime.utc_now()
  def change(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()
  @active_job_states ~w(available scheduled executing retryable)

  def notify do
    if Process.whereis(Mondek.PubSub),
      do: Phoenix.PubSub.broadcast(Mondek.PubSub, "monitoring", :changed)

    :ok
  end

  @doc "Wake control polls after committed configuration or membership changes, never telemetry."
  def notify_control(runner_id \\ nil) do
    if Process.whereis(Mondek.PubSub),
      do: Phoenix.PubSub.broadcast(Mondek.PubSub, control_topic(runner_id), :control_changed)

    :ok
  end

  @doc false
  def control_topic(nil), do: "runner-control"

  def control_topic(runner_id) do
    {:ok, runner_id} = Ecto.UUID.cast(runner_id)
    "runner-control:" <> runner_id
  end

  def retire_source_assignment!(a, reason, at, options \\ []),
    do: retire_locked_assignment!(a, reason, "source_removed", "Runner source", at, options)

  @doc false
  def retire_publisher_assignment!(a, reason, at, action \\ "retire"),
    do:
      retire_locked_assignment!(
        a,
        reason,
        if(action == "replace", do: "publisher_replaced", else: "publisher_retired"),
        "Local operator",
        at,
        reduce: false
      )

  def retire_source_stream!(
        stream,
        assignment,
        reason,
        at,
        closure_reason \\ "source_removed",
        options \\ []
      ) do
    lock_condition_streams!([assignment.id])
    groups = Conditions.retire_contributions!([stream.id], closure_reason, at)

    incidents =
      Repo.all(
        from i in Incident,
          where:
            i.stream_id == ^stream.id and i.status == "open" and
              is_nil(i.condition_incident_id),
          lock: "FOR UPDATE"
      )

    for incident <- incidents do
      change(
        incident,
        Map.merge(
          end_acknowledgement_attrs!(
            incident,
            "Incident ended because its source membership changed (#{closure_reason}).",
            at
          ),
          %{
            status: "closed",
            closed_at: at,
            closure_reason: closure_reason,
            closing_observation_id: nil,
            attention_revision: incident.attention_revision + 1,
            acknowledged_until: nil
          }
        )
      )
    end

    ids = from i in Incident, where: i.stream_id == ^stream.id, select: i.id

    Repo.update_all(
      from(o in Occurrence,
        where:
          o.incident_id in subquery(ids) and
            o.status in ["pending", "retrying", "delivering", "exhausted"]
      ),
      set: [status: "superseded"]
    )

    Repo.insert!(%Control{
      assignment_id: assignment.id,
      stream_id: stream.id,
      incident_id: List.first(incidents) && hd(incidents).id,
      kind: closure_reason,
      actor: "Runner source",
      reason: reason,
      until: at,
      inserted_at: at
    })

    stream =
      change(stream, %{
        retired_at: at,
        retirement_reason: reason,
        retirement_generation: assignment.desired_generation
      })

    if Keyword.get(options, :reduce, true), do: Conditions.reduce!(groups, at)
    stream
  end

  defp retire_locked_assignment!(a, reason, kind, actor, at, options) do
    lock_condition_streams!([a.id])
    stream_ids = Repo.all(from s in ResultStream, where: s.assignment_id == ^a.id, select: s.id)
    groups = Conditions.retire_contributions!(stream_ids, kind, at)

    incidents =
      Repo.all(
        from i in Incident,
          where:
            i.assignment_id == ^a.id and i.status == "open" and
              is_nil(i.condition_incident_id),
          lock: "FOR UPDATE"
      )

    for incident <- incidents do
      change(
        incident,
        Map.merge(
          end_acknowledgement_attrs!(
            incident,
            "Incident ended because its check was retired.",
            at
          ),
          %{
            status: "closed",
            closed_at: at,
            closure_reason: kind,
            closing_observation_id: nil,
            attention_revision: incident.attention_revision + 1,
            acknowledged_until: nil
          }
        )
      )
    end

    occurrence_ids =
      from o in Occurrence,
        join: i in Incident,
        on: i.id == o.incident_id,
        where: i.assignment_id == ^a.id,
        select: o.id

    Repo.update_all(
      from(o in Occurrence,
        where:
          o.id in subquery(occurrence_ids) and
            o.status in ["pending", "retrying", "delivering", "exhausted"]
      ),
      set: [status: "superseded"]
    )

    Repo.update_all(
      from(s in ResultStream, where: s.assignment_id == ^a.id and is_nil(s.retired_at)),
      set: [
        retired_at: at,
        retirement_reason: String.trim(reason),
        retirement_generation: a.desired_generation + 1
      ]
    )

    Repo.insert!(%Control{
      assignment_id: a.id,
      incident_id: List.first(incidents) && hd(incidents).id,
      kind: kind,
      actor: actor,
      reason: String.trim(reason),
      until: at,
      inserted_at: at
    })

    a =
      change(a, %{
        retired_at: at,
        retirement_reason: String.trim(reason),
        revision: a.revision + 1
      })

    if Keyword.get(options, :reduce, true), do: Conditions.reduce!(groups, at)
    a
  end

  @doc false
  def lock_condition_streams!(assignment_ids, extra \\ []) do
    identities =
      Repo.all(
        from s in ResultStream,
          where:
            s.assignment_id in ^assignment_ids and is_nil(s.retired_at) and
              not is_nil(s.condition),
          select: {s.condition, s.environment}
      )
      |> Enum.map(fn {condition, environment} ->
        Map.put(condition, "environment", environment)
      end)

    Conditions.lock_keys!(identities ++ extra)
  end

  def retry_notification(id, reason, at \\ now()) do
    with :ok <- validate_reason(reason), :ok <- validate_notification_id(id) do
      result =
        Repo.transaction(fn ->
          existing = Repo.get(Occurrence, id) || Repo.rollback(:not_found)
          context = lock_delivery_context!(existing, at)
          occurrence = Repo.one!(from o in Occurrence, where: o.id == ^id, lock: "FOR UPDATE")

          if delivery_context_eligibility(occurrence, context, at) in [:delivered, :superseded],
            do: Repo.rollback(:superseded)

          if occurrence.status != "exhausted", do: Repo.rollback(:not_exhausted)
          if active_delivery_job?(id), do: Repo.rollback(:delivery_in_progress)

          # A new bounded attempt budget keeps the original occurrence identity,
          # payload and destination. Worker dispatch still applies current gates.
          occurrence = change(occurrence, %{status: "pending"})
          enqueue_notification!(id, occurrence.destination)

          if context.kind == :condition, do: Conditions.request_gate_wake!(context.incident.id)

          if context.kind == :monitoring do
            Repo.update_all(
              from(o in Occurrence, where: o.monitoring_incident_id == ^context.incident.id),
              inc: [gate_revision: 1]
            )
          end

          Repo.insert!(%Control{
            assignment_id: context.assignment && context.assignment.id,
            incident_id: if(context.kind == :individual, do: context.incident.id),
            condition_incident_id: if(context.kind == :condition, do: context.incident.id),
            monitoring_incident_id: if(context.kind == :monitoring, do: context.incident.id),
            occurrence_id: id,
            kind: "notification_retry",
            actor: "Local operator",
            reason: String.trim(reason),
            until: at,
            inserted_at: at
          })

          public(occurrence)
        end)

      notify()
      result
    end
  end

  @doc false
  # Caller owns the transaction; take the owning context before its occurrence.
  # The three ownership paths differ: see docs/TRANSACTIONS-AND-LOCKS.md.
  def lock_delivery_context!(occurrence, at \\ nil)

  def lock_delivery_context!(%Occurrence{monitoring_incident_id: id}, at) when not is_nil(id),
    do: %{
      kind: :monitoring,
      incident: Mondek.MonitoringLoss.lock_delivery_incident!(id, at),
      assignment: nil
    }

  def lock_delivery_context!(%Occurrence{condition_incident_id: id}, _at) when not is_nil(id),
    do: %{kind: :condition, incident: Conditions.lock!(id), assignment: nil}

  def lock_delivery_context!(%Occurrence{incident_id: id}, _at) do
    incident = Repo.get!(Incident, id)
    assignment = lock_assignment(incident.assignment_id)
    %{kind: :individual, incident: Repo.get!(Incident, id), assignment: assignment}
  end

  @doc false
  def delivery_context_eligibility(occurrence, %{kind: :monitoring, incident: incident}, at),
    do: Mondek.MonitoringLoss.delivery_eligibility(occurrence, incident, at)

  def delivery_context_eligibility(occurrence, %{kind: :condition, incident: group}, at),
    do: Conditions.delivery_eligibility(occurrence, group, at)

  def delivery_context_eligibility(occurrence, %{incident: incident, assignment: assignment}, at),
    do: delivery_eligibility(occurrence, incident, assignment, at)

  defp active_delivery_job?(id),
    do:
      Repo.exists?(
        from j in Oban.Job,
          where:
            j.worker == "Mondek.NotificationWorker" and j.state in ^@active_job_states and
              fragment("?->>'occurrence_id'", j.args) == ^id
      )

  defp validate_notification_id(id) do
    if match?({:ok, _}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, {:invalid, "Malformed notification ID."}}
  end

  defp validate_reason(reason) when is_binary(reason) do
    if byte_size(String.trim(reason)) in 1..500 and not String.match?(reason, ~r/[\x00-\x1f\x7f]/),
      do: :ok,
      else: {:error, {:invalid, "Supply a reason of 1 to 500 bytes without control characters."}}
  end

  defp validate_reason(_), do: {:error, {:invalid, "Supply a reason of 1 to 500 bytes."}}

  def save_assignment(id, revision, params, review_token \\ nil) do
    result =
      Mondek.ConfigurationRepository.transaction("ui", fn ->
        a = lock_configuration_assignment(id)

        cond do
          is_nil(a) ->
            Repo.rollback(:not_found)

          a.revision != revision ->
            Repo.rollback(:stale)

          not is_nil(a.retired_at) ->
            Repo.rollback(:retired)

          a.params_owner == "source" ->
            Repo.rollback(:source_owned)

          not is_map(params) ->
            Repo.rollback({:invalid, "Supply the complete typed parameter set."})

          true ->
            if review_token,
              do: Mondek.ConfigurationRules.validate_instance_review!(a, params, review_token)

            case Mondek.Parameters.validate(a.parameter_schema, params) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback({:invalid, reason})
            end

            saved =
              if review_token,
                do:
                  set_effective_configuration!(a, params, %{"kind" => "exception"}, now(), %{
                    instance_exception: params
                  }),
                else: update_configuration!(a, params, now())

            if saved.runner_id && saved.revision != a.revision,
              do: ensure_control_bound!(saved.runner_id)

            public(saved)
        end
      end)

    notify()
    if match?({:ok, _}, result), do: notify_control(elem(result, 1)["runner_id"])
    result
  end

  def configuration_changed?(a, params), do: not same_params?(a.params, params)

  @doc false
  def update_configuration!(a, params, at) do
    if same_params?(a.params, params) do
      a
    else
      extra = %{instance_exception: params}
      set_effective_configuration!(a, params, %{"kind" => "exception"}, at, extra)
    end
  end

  @doc false
  def set_effective_configuration!(a, params, origin, at, extra \\ %{}) do
    # Ecto's native numeric equality can otherwise omit a changed decimal
    # value when an integer and a large float share a binary approximation.
    params = Mondek.Parameters.normalized_json(params)

    if configuration_changed?(a, params) or
         not Mondek.Parameters.same_json?(a.configuration_origin, origin) or
         Enum.any?(extra, fn {key, value} ->
           not Mondek.Parameters.same_json?(Map.get(a, key), value)
         end) do
      if a.desired_generation >= 2_147_483_647 or a.revision >= 2_147_483_647,
        do: Repo.rollback({:invalid, "This check has exhausted its configuration version range."})

      generation = a.desired_generation + 1

      attrs =
        Map.merge(extra, %{
          params: params,
          configuration_origin: origin,
          revision: a.revision + 1,
          desired_generation: generation
        })

      updated = struct(a, attrs)

      Repo.insert!(%Configuration{
        assignment_id: a.id,
        generation: generation,
        params: params,
        definition: Mondek.Inventory.definition(updated),
        saved_at: at
      })

      change(a, attrs)
    else
      a
    end
  end

  defp lock_configuration_assignment(id) do
    case lookup_assignment(id, false) do
      nil ->
        nil

      reviewed ->
        Mondek.ConfigurationRules.lock_source!(reviewed.source_id)
        # Control, inventory and ingestion all acquire runner before assignment.
        # This also serializes disjoint saves against their shared response cap.
        if reviewed.runner_id do
          Repo.one!(
            from r in Runner, where: r.id == ^reviewed.runner_id, lock: "FOR NO KEY UPDATE"
          )
        end

        locked = lock_assignment(id)
        if locked && locked.runner_id != reviewed.runner_id, do: Repo.rollback(:stale)
        locked
    end
  end

  def ensure_control_bound!(runner_id, replacements \\ %{}) do
    assignments =
      Repo.all(from a in Assignment, where: a.runner_id == ^runner_id and is_nil(a.retired_at))
      |> Enum.map(&Map.get(replacements, &1.id, &1))

    control = %{
      "version" => 1,
      "assignments_authoritative" => true,
      "assignments" => Enum.map(assignments, &wire/1),
      "authorized" => Map.new(assignments, &{&1.id, &1.desired_generation})
    }

    if byte_size(Jason.encode!(control)) > 4_194_304,
      do:
        Repo.rollback(
          {:invalid,
           "Configuration exceeds this runner's 4 MiB response limit. Reduce parameter or inventory size, or split checks across runners."}
        )

    :ok
  end

  defp same_params?(saved, proposed),
    do: Mondek.Parameters.same_json?(saved, proposed)

  def inventory(params, at \\ now()), do: Mondek.Inventory.reconcile(params, at)

  def register_runner(params, at) do
    # Registration serializes only identity creation; the row fences this runner's
    # control, inventory and ingestion across sessions and concurrent sources.
    # Runner IDs never change. NO KEY UPDATE still excludes other writers, but
    # lets monitoring incidents validate their runner FK after taking the loss
    # lock; FOR UPDATE would invert that lock order through the implicit FK lock.
    Repo.query!("SELECT pg_advisory_xact_lock(774002)")

    existing =
      Repo.one(
        from r in Runner,
          where: r.id == ^params["installation_id"],
          lock: "FOR NO KEY UPDATE"
      )

    case existing do
      nil ->
        Repo.insert!(%Runner{
          id: params["installation_id"],
          session_id: params["session_id"],
          boot: params["boot"],
          label: params["runner_label"] || params["installation_id"],
          last_seen_at: at,
          status: params["status"] || %{}
        })

      r ->
        if r.boot > params["boot"] or
             (r.boot == params["boot"] and r.session_id != params["session_id"]),
           do: Repo.rollback(:session_conflict)

        change(r, %{
          session_id: params["session_id"],
          boot: params["boot"],
          # Inventory may wait on the journal while newer control commits.
          last_seen_at:
            if(DateTime.compare(r.last_seen_at, at) == :gt, do: r.last_seen_at, else: at),
          label: params["runner_label"] || r.label,
          status: params["status"] || r.status
        })
    end
  end

  def control(params, at \\ now()) do
    with :ok <- Mondek.Protocol.control(params) do
      result =
        Repo.transaction(fn ->
          runner = register_runner(params, at)

          assignments =
            Repo.all(
              from a in Assignment,
                where:
                  is_nil(a.retired_at) and
                    a.runner_id == ^runner.id,
                order_by: a.id,
                lock: "FOR UPDATE"
            )

          assignments =
            Enum.map(assignments, fn a ->
              prepared = get_in(params, ["prepared", a.id])
              active = get_in(params, ["active", a.id])
              updates = %{}
              # Preparation is the authoritative cutover. Active is only a later receipt.
              updates =
                if prepared == a.desired_generation,
                  do:
                    Map.merge(updates, %{
                      prepared_generation: prepared,
                      authorized_generation: prepared
                    }),
                  else: updates

              a = change(a, updates)

              a =
                if active == a.authorized_generation and not is_nil(active),
                  do: change(a, %{active_generation: active}),
                  else: a

              if is_integer(active) and active > a.desired_generation,
                do: Repo.rollback(:invalid_generation)

              a
            end)

          Mondek.MonitoringLoss.lock!()

          %{
            "version" => 1,
            "assignments_authoritative" => true,
            "inventory_refresh" =>
              Repo.all(
                from s in Mondek.SourceInventory,
                  where:
                    s.runner_id == ^runner.id and is_nil(s.retired_at) and
                      not is_nil(s.resume_after_revision),
                  order_by: s.source_id,
                  limit: 512,
                  select:
                    {s.source_id,
                     %{
                       "after_revision" => s.resume_after_revision,
                       "lifecycle_revision" => s.lifecycle_revision
                     }}
              )
              |> Map.new(),
            "assignments" => Enum.map(assignments, &wire/1),
            "authorized" =>
              Map.new(
                assignments |> Enum.reject(&is_nil(&1.authorized_generation)),
                &{&1.id, &1.authorized_generation}
              )
          }
        end)

      notify()
      result
    end
  end

  def ingest(params, at \\ now()) do
    with :ok <- Mondek.Protocol.envelope(params) do
      result =
        Repo.transaction(fn ->
          runner =
            Repo.one(
              from r in Runner,
                where: r.id == ^params["installation_id"],
                lock: "FOR NO KEY UPDATE"
            )

          if is_nil(runner) or runner.session_id != params["session_id"],
            do: Repo.rollback(:session_conflict)

          # Lock batch membership in the same order as control and retention.
          # Admission still follows original report order for exact dispositions.
          assignment_ids =
            params["reports"]
            |> Enum.map(& &1["assignment_id"])
            |> Enum.filter(&Mondek.Protocol.assignment_id?/1)
            |> Enum.uniq()

          locked_assignments =
            Repo.all(
              from a in Assignment,
                where: a.id in ^assignment_ids and a.runner_id == ^runner.id,
                order_by: a.id,
                lock: "FOR UPDATE"
            )

          # All condition identities are locked before reducing any report. The
          # remaining reduction follows report order, so transport batching cannot
          # erase a measured recovery followed by a new failure.
          lock_condition_streams!(Enum.map(locked_assignments, & &1.id))
          dispositions = Enum.map(params["reports"], &admit(&1, runner, at))
          %{"version" => 1, "dispositions" => dispositions}
        end)

      notify()
      result
    end
  end

  defp admit(report, runner, at) do
    id = report["id"]

    with :ok <- Mondek.Protocol.report(report, at),
         %Assignment{} = a <- lookup_assignment(report["assignment_id"], false),
         true <- a.runner_id == runner.id and report["installation_id"] == runner.id,
         %Configuration{} = configuration <-
           Repo.get_by(Configuration, assignment_id: a.id, generation: report["generation"]),
         :ok <- Mondek.Protocol.membership(report, configuration_keys(configuration, a)) do
      # JSONB may return an exponent-form JSON number as an integer. Compare
      # complete JSON values in PostgreSQL, preserving exact decimal numeric
      # equality without float coercion, tolerances or changed-field omissions.
      case observation_replay(report) do
        {original, true} ->
          %{"id" => id, "disposition" => "duplicate", "original_disposition" => original}

        {_, false} ->
          %{"id" => id, "disposition" => "conflict"}

        nil ->
          streams = eligible_streams(a, configuration)

          current? =
            streams != [] and is_nil(a.retired_at) and report["session_id"] == runner.session_id and
              report["generation"] == a.authorized_generation and
              report["sequence"] > a.last_sequence

          disposition = if current?, do: "current", else: "historical"

          observation =
            Repo.insert!(%Observation{
              id: id,
              assignment_id: a.id,
              installation_id: runner.id,
              session_id: report["session_id"],
              generation: report["generation"],
              sequence: report["sequence"],
              started_at: parse!(report["started_at"]),
              evaluated_at: parse!(report["evaluated_at"]),
              received_at: at,
              payload: report,
              disposition: disposition
            })

          if current?, do: reduce(a, observation, at, streams, configuration)

          %{"id" => id, "disposition" => disposition}
          |> then(fn result ->
            if a.retired_at, do: Map.put(result, "reason", "check_retired"), else: result
          end)
      end
    else
      {:error, {:unsupported_result_environment, message}} ->
        # Older controllers ignored these fields. An exact receipt already
        # committed for this installation remains replayable after the stricter
        # validation, without granting new measurement or namespace authority.
        existing =
          if report["installation_id"] == runner.id,
            do: observation_replay(report, runner.id)

        case existing do
          {original, true} ->
            %{"id" => id, "disposition" => "duplicate", "original_disposition" => original}

          {_, false} ->
            %{"id" => id, "disposition" => "conflict"}

          _ ->
            %{
              "id" => id,
              "disposition" => "rejected",
              "reason" => "unsupported_result_environment",
              "error" => message
            }
        end

      _ ->
        %{"id" => id, "disposition" => "rejected"}
    end
  end

  defp observation_replay(report, runner_id \\ nil) do
    query = from o in Observation, where: o.id == ^report["id"]

    query =
      if runner_id, do: from(o in query, where: o.installation_id == ^runner_id), else: query

    Repo.one(from o in query, select: {o.disposition, o.payload == ^report})
  end

  defp configuration_keys(configuration, a) do
    case configuration.definition["outputs"] do
      outputs when is_list(outputs) -> Enum.map(outputs, & &1["key"])
      _ -> configuration.definition["expected_keys"] || a.expected_keys
    end
  end

  defp eligible_streams(a, configuration) do
    Repo.all(
      from s in ResultStream,
        where:
          s.assignment_id == ^a.id and is_nil(s.retired_at) and
            s.admission_generation <= ^configuration.generation
    )
    |> Enum.filter(fn stream ->
      case configuration.definition["outputs"] do
        outputs when is_list(outputs) ->
          output = Enum.find(outputs, &(&1["key"] == stream.result_key))

          output &&
            (is_nil(output["target"]) or
               Map.take(output["target"], ~w(key kind)) == Map.take(stream.target, ~w(key kind)))

        _ ->
          stream.result_key in a.expected_keys
      end
    end)
  end

  defp reduce(a, o, at, streams, configuration) do
    groups =
      for stream <- streams do
        result = Enum.find(o.payload["results"], &(&1["key"] == stream.result_key))
        # Completeness is independent per declared output. A sibling's failure can
        # never manufacture recovery here or prevent a valid result from advancing.
        payload =
          Map.merge(o.payload, %{
            "results" => if(result, do: [result], else: []),
            "complete" => not is_nil(result)
          })

        {state, measured?} =
          project(
            %{a | current: stream.current, expected_keys: [stream.result_key]},
            %{o | payload: payload},
            at
          )

        stream = change(stream, %{current: state})

        if measured? do
          if Conditions.identity(configuration.definition, stream.result_key) do
            Conditions.observe!(a, stream, o, configuration.definition, state, at)
          else
            transition(a, state["health"], o, at, stream, configuration.definition)
            nil
          end
        end
      end

    Conditions.reduce!(Enum.reject(groups, &is_nil/1), at, o)

    {state, measured?} = project(a, o, at)

    change(a, %{
      current: state,
      observed_generation: if(measured?, do: o.generation, else: a.observed_generation),
      last_sequence: o.sequence
    })

    # Reduce every admitted report in order. A recovery followed by another
    # failure in one upload is two episodes, never one continuous gap.
    Mondek.MonitoringLoss.reconcile_runner!(a.runner_id, at, a.id)
    if a.source_id, do: Mondek.MonitoringLoss.observe_coverage!(a.source_id, at)
  end

  defp project(a, o, at) do
    report = o.payload
    results = report["results"]

    measured? =
      report["complete"] and length(results) == length(a.expected_keys) and
        Enum.all?(results, &(&1["health"] != "UNKNOWN" and not is_nil(&1["source_at"])))

    result =
      Enum.max_by(results, &severity(&1["health"]), fn ->
        %{
          "health" => "UNKNOWN",
          "summary" => report["diagnostic"] || "Expected output missing",
          "value" => nil,
          "source_at" => nil
        }
      end)

    previous_health = a.current["health"] || "UNKNOWN"

    fresh_measurement? =
      measured? and Enum.all?(results, &fresh?(&1["source_at"], a.freshness_seconds, at))

    # Health may outlive the latest execution. Preserve its own provenance rather
    # than attaching a retained verdict to an unavailable or stale report.
    confirmed =
      if fresh_measurement? do
        %{
          "confirmed_observation_id" => o.id,
          "confirmed_generation" => o.generation,
          "confirmed_session_id" => o.session_id,
          "confirmed_evaluated_at" => report["evaluated_at"]
        }
      else
        confirmed_evidence(a.current)
      end

    state = %{
      "health" => if(fresh_measurement?, do: result["health"], else: previous_health),
      "knowledge" =>
        cond do
          not measured? -> "unavailable"
          fresh_measurement? -> "fresh"
          true -> "stale"
        end,
      "summary" =>
        if(fresh_measurement?,
          do: result["summary"],
          else: a.current["summary"] || result["summary"]
        ),
      "value" => if(fresh_measurement?, do: result["value"], else: a.current["value"]),
      "details" => if(fresh_measurement?, do: result["details"], else: a.current["details"]),
      "impacts" =>
        if(fresh_measurement?,
          do: Map.get(result, "impacts", []),
          else: a.current["impacts"] || []
        ),
      "source_at" =>
        if(fresh_measurement?, do: result["source_at"], else: a.current["source_at"]),
      "reported_health" => result["health"],
      "reported_source_at" => result["source_at"],
      "execution_summary" => result["summary"],
      "execution_details" => result["details"],
      "execution_impacts" => Map.get(result, "impacts", []),
      "evaluated_at" => report["evaluated_at"],
      "started_at" => report["started_at"],
      "received_at" => iso(at),
      "observation_id" => o.id,
      "session_id" => o.session_id,
      "generation" => o.generation,
      "diagnostic" => report["diagnostic"],
      "complete" => measured?
    }

    {Map.merge(state, confirmed), fresh_measurement?}
  end

  defp confirmed_evidence(current) do
    case current["confirmed_observation_id"] do
      nil ->
        # Existing projections from before these fields were introduced can be
        # upgraded when their last execution itself established confirmed health.
        if current["knowledge"] == "fresh" and current["complete"] == true do
          %{
            "confirmed_observation_id" => current["observation_id"],
            "confirmed_generation" => current["generation"],
            "confirmed_session_id" => current["session_id"],
            "confirmed_evaluated_at" => current["evaluated_at"]
          }
        else
          %{}
        end

      _ ->
        Map.take(
          current,
          ~w(confirmed_observation_id confirmed_generation confirmed_session_id confirmed_evaluated_at)
        )
    end
  end

  defp transition(a, health, o, at, stream, definition) do
    result = Enum.find(o.payload["results"], &(&1["key"] == stream.result_key))
    impacts = (result && result["impacts"]) || []
    impact_keys = impacts |> Enum.map(& &1["key"]) |> Enum.sort()

    incident =
      Repo.one(
        from i in Incident,
          where: i.assignment_id == ^a.id and i.stream_id == ^stream.id and i.status == "open",
          lock: "FOR UPDATE"
      )

    cond do
      health in ["WARN", "CRIT"] and is_nil(incident) ->
        incident =
          Repo.insert!(%Incident{
            assignment_id: a.id,
            result_key: stream.result_key,
            stream_id: stream.id,
            environment: Map.get(definition, "environment", stream.environment),
            environment_label: Map.get(definition, "environment_label", stream.environment_label),
            health: health,
            impacts: impacts,
            opened_at: at,
            opening_generation: o.generation
          })

        occurrence(incident, "firing", o, at)

      health in ["WARN", "CRIT"] and
          (incident.health != health or
             Enum.sort(Enum.map(incident.impacts, & &1["key"])) != impact_keys) ->
        invalid_ack? =
          not is_nil(incident.acknowledgement_mode) and
            not is_nil(incident.acknowledgement_ceiling) and
            (severity(health) > severity(incident.acknowledgement_ceiling) or
               Enum.any?(impact_keys, &(&1 not in incident.acknowledgement_impacts)))

        attrs = %{
          health: health,
          impacts: impacts,
          attention_revision: incident.attention_revision + 1
        }

        attrs =
          if invalid_ack?,
            do:
              Map.merge(
                attrs,
                end_acknowledgement_attrs!(
                  incident,
                  if(severity(health) > severity(incident.acknowledgement_ceiling),
                    do:
                      "Acknowledgement ended automatically: severity rose from #{incident.health} to #{health}, above the acknowledged #{incident.acknowledgement_ceiling} limit.",
                    else:
                      "Acknowledgement ended automatically: a new material impact appeared outside the reviewed scope."
                  ),
                  at
                )
              ),
            else: attrs

        incident = change(incident, attrs)
        supersede_firing(incident)
        occurrence(incident, "update", o, at)

      health == "OK" and not is_nil(incident) ->
        reason =
          if same_recovery_contract?(a.id, incident.opening_generation, o.generation),
            do: "measured_recovery",
            else: "configuration_changed"

        incident =
          change(
            incident,
            Map.merge(
              end_acknowledgement_attrs!(
                incident,
                "Acknowledgement ended with the incident (#{reason}).",
                at
              ),
              %{
                status: "closed",
                closed_at: at,
                closure_reason: reason,
                closing_observation_id: o.id,
                attention_revision: incident.attention_revision + 1,
                acknowledged_until: nil
              }
            )
          )

        attempted? =
          Repo.exists?(
            from t in Attempt,
              join: n in Occurrence,
              on: t.occurrence_id == n.id,
              where: n.incident_id == ^incident.id and n.kind in ["firing", "update"]
          )

        supersede_firing(incident)

        if attempted?, do: occurrence(incident, "resolved", o, at)

      health in ["WARN", "CRIT"] ->
        change(incident, %{impacts: impacts})

      true ->
        :ok
    end
  end

  @doc false
  def same_recovery_contract?(_assignment_id, generation, generation), do: true

  def same_recovery_contract?(assignment_id, opening_generation, measured_generation) do
    parameters =
      Repo.all(
        from c in Configuration,
          where:
            c.assignment_id == ^assignment_id and
              c.generation in ^[opening_generation, measured_generation],
          select: {c.params, c.definition}
      )
      |> Enum.map(fn {params, definition} ->
        {params, Map.drop(definition, ~w(environment environment_label configuration_origin))}
      end)

    case parameters do
      [{first, definition}, {second, definition}] -> same_params?(first, second)
      _ -> false
    end
  end

  defp supersede_firing(incident) do
    Repo.update_all(
      from(n in Occurrence,
        where:
          n.incident_id == ^incident.id and n.kind != "resolved" and
            n.attention_revision < ^incident.attention_revision and
            n.status in ["pending", "retrying", "delivering", "exhausted"]
      ),
      set: [status: "superseded"]
    )
  end

  defp occurrence(incident, kind, observation, at) do
    id = Ecto.UUID.generate()

    payload = %{
      "version" => 1,
      "occurrence_id" => id,
      "incident_id" => incident.id,
      "assignment_id" => incident.assignment_id,
      "kind" => kind,
      "health" => incident.health,
      "attention_revision" => incident.attention_revision,
      "observation_id" => observation.id,
      "generation" => observation.generation,
      "result_key" => incident.result_key,
      "stream_id" => incident.stream_id,
      "environment" => incident.environment,
      "environment_label" => incident.environment_label,
      "target" => incident.stream_id && Repo.get!(ResultStream, incident.stream_id).target,
      "source_at" =>
        (Enum.find(observation.payload["results"], &(&1["key"] == incident.result_key)) || %{})[
          "source_at"
        ],
      "created_at" => iso(at),
      "closure_reason" => incident.closure_reason
    }

    payload =
      if incident.impacts == [], do: payload, else: Map.put(payload, "impacts", incident.impacts)

    result = Enum.find(observation.payload["results"], &(&1["key"] == incident.result_key)) || %{}
    assignment = Repo.get!(Assignment, incident.assignment_id)

    {payload, destination} =
      Mondek.NotificationDelivery.snapshot(
        payload,
        assignment.label,
        result["summary"],
        result["health"]
      )

    o =
      Repo.insert!(%Occurrence{
        id: id,
        incident_id: incident.id,
        kind: kind,
        attention_revision: incident.attention_revision,
        payload: payload,
        destination: destination,
        inserted_at: at
      })

    enqueue_notification!(o.id, destination)
    o
  end

  @doc false
  def enqueue_notification!(id, destination) do
    %{
      "occurrence_id" => id,
      "delivery_channel" => Mondek.NotificationDelivery.channel(destination)
    }
    |> Mondek.NotificationWorker.new(
      max_attempts: Application.get_env(:mondek, :notification_max_attempts, 100)
    )
    |> Oban.insert!()
  end

  @last_acknowledgement ~U[9999-12-31 23:59:59.999999Z]

  def acknowledge(id, options, note, at \\ now()) do
    if validate_incident_id(id) == :ok and Repo.get(Mondek.ConditionIncident, id),
      do: Conditions.acknowledge(id, options, note, at),
      else: acknowledge_result(id, options, note, at)
  end

  defp acknowledge_result(id, options, note, at) do
    with :ok <- validate_acknowledgement_note(note),
         :ok <- validate_incident_id(id),
         {:ok, mode, until, revisions} <- acknowledgement_options(options, at) do
      result =
        Repo.transaction(fn ->
          existing = Repo.get(Incident, id) || Repo.rollback(:not_found)
          lock_assignment(existing.assignment_id)
          if existing.condition_incident_id, do: Conditions.lock!(existing.condition_incident_id)
          incident = Repo.one!(from i in Incident, where: i.id == ^id, lock: "FOR UPDATE")

          if revisions &&
               (revisions["revision"] != incident.acknowledgement_revision or
                  revisions["attention_revision"] != incident.attention_revision),
             do: Repo.rollback(:stale)

          if incident.status != "open",
            do: Repo.rollback({:invalid, "Only an open incident can be acknowledged."})

          revision = incident.acknowledgement_revision + 1

          if revision > 9_223_372_036_854_775_806,
            do: Repo.rollback({:invalid, "Acknowledgement revision range exhausted."})

          ended? = mode == "end"

          Repo.insert!(%Control{
            assignment_id: incident.assignment_id,
            incident_id: id,
            kind: if(ended?, do: "acknowledgement_ended", else: "acknowledgement"),
            acknowledgement_mode: if(ended?, do: "ended", else: mode),
            acknowledgement_revision: revision,
            acknowledgement_ceiling:
              if(ended?, do: incident.acknowledgement_ceiling, else: incident.health),
            acknowledgement_impacts:
              if(ended?,
                do: incident.acknowledgement_impacts,
                else: Enum.map(incident.impacts, & &1["key"])
              ),
            actor: "Local operator",
            reason: note,
            until: if(ended?, do: at, else: until),
            inserted_at: at
          })

          request_gate_wake!(incident.id)

          incident
          |> change(%{
            acknowledgement_mode: if(ended?, do: nil, else: mode),
            acknowledgement_revision: revision,
            acknowledged_until: if(ended?, do: nil, else: until),
            acknowledged_by: "Local operator",
            acknowledgement_note: note,
            acknowledgement_ceiling: if(ended?, do: nil, else: incident.health),
            acknowledgement_impacts:
              if(ended?, do: [], else: Enum.map(incident.impacts, & &1["key"]))
          })
          |> public()
        end)

      notify()
      result
    end
  end

  def acknowledgement_active?(incident, at \\ now()) do
    value = fn key -> Map.get(incident, key, Map.get(incident, Atom.to_string(key))) end

    until =
      case value.(:acknowledged_until) do
        %DateTime{} = date ->
          date

        text when is_binary(text) ->
          case DateTime.from_iso8601(text) do
            {:ok, date, _} -> date
            _ -> nil
          end

        _ ->
          nil
      end

    value.(:status) == "open" and
      (value.(:acknowledgement_mode) == "until_incident_ends" or
         (value.(:acknowledgement_mode) == "until" and future?(until, at)))
  end

  @doc false
  def validate_acknowledgement_note(note) when is_binary(note) and byte_size(note) in 1..500 do
    if String.valid?(note) and String.trim(note) != "" and
         not String.match?(note, ~r/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/),
       do: :ok,
       else:
         {:error,
          {:invalid,
           "Supply a nonblank acknowledgement note of at most 500 bytes. Ordinary line breaks are supported."}}
  end

  def validate_acknowledgement_note(_),
    do: {:error, {:invalid, "Supply a nonblank acknowledgement note of at most 500 bytes."}}

  @doc false
  def acknowledgement_options(options, at) when is_map(options) do
    revisions? =
      is_integer(options["revision"]) and options["revision"] >= 0 and
        is_integer(options["attention_revision"]) and options["attention_revision"] > 0

    allowed =
      case options["mode"] do
        "duration" -> ~w(mode revision attention_revision seconds)
        "until" -> ~w(mode revision attention_revision expires_at)
        mode when mode in ["end", "until_incident_ends"] -> ~w(mode revision attention_revision)
        _ -> []
      end

    if revisions? and allowed != [] and Enum.all?(Map.keys(options), &(&1 in allowed)) do
      case options["mode"] do
        "until_incident_ends" ->
          {:ok, "until_incident_ends", nil, options}

        "end" ->
          {:ok, "end", nil, options}

        "duration" ->
          acknowledgement_duration(options["seconds"], at, options)

        "until" ->
          case options["expires_at"] do
            text when is_binary(text) and byte_size(text) <= 40 ->
              case DateTime.from_iso8601(text) do
                {:ok, until, _} ->
                  if DateTime.compare(until, at) == :gt and
                       DateTime.compare(until, @last_acknowledgement) != :gt,
                     do:
                       {:ok, "until", %{until | microsecond: {elem(until.microsecond, 0), 6}},
                        options},
                     else: acknowledgement_error()

                _ ->
                  acknowledgement_error()
              end

            _ ->
              acknowledgement_error()
          end
      end
    else
      acknowledgement_error()
    end
  end

  def acknowledgement_options(_, _), do: acknowledgement_error()

  defp acknowledgement_duration(seconds, at, revisions)
       when is_integer(seconds) and seconds > 0 do
    if seconds <= DateTime.diff(@last_acknowledgement, at),
      do: {:ok, "until", DateTime.add(at, seconds), revisions},
      else: acknowledgement_error()
  end

  defp acknowledgement_duration(_, _, _), do: acknowledgement_error()

  defp acknowledgement_error,
    do:
      {:error,
       {:invalid,
        "Choose until the incident ends, a positive duration, a future ISO8601 expiry with timezone offset (through year 9999), or end. Submit both reviewed revisions and only fields for that mode."}}

  @doc false
  def end_acknowledgement_attrs!(incident, reason, at) do
    revision = incident.acknowledgement_revision + 1

    if acknowledgement_active?(incident, at) do
      Repo.insert!(%Control{
        assignment_id: incident.assignment_id,
        incident_id: incident.id,
        kind: "acknowledgement_ended",
        acknowledgement_mode: "ended",
        acknowledgement_revision: revision,
        acknowledgement_ceiling: incident.acknowledgement_ceiling,
        acknowledgement_impacts: incident.acknowledgement_impacts,
        actor: "Mondek",
        reason: reason,
        until: at,
        inserted_at: at
      })
    end

    request_gate_wake!(incident.id)

    %{
      acknowledgement_mode: nil,
      acknowledged_until: nil,
      acknowledgement_ceiling: nil,
      acknowledgement_impacts: [],
      acknowledgement_revision: revision
    }
  end

  defp request_gate_wake!(incident_id) do
    Repo.update_all(from(o in Occurrence, where: o.incident_id == ^incident_id),
      inc: [gate_revision: 1]
    )

    case Repo.get(Incident, incident_id) do
      %Incident{condition_incident_id: id} when not is_nil(id) ->
        Conditions.request_gate_wake!(id)

      _ ->
        :ok
    end
  end

  defp validate_incident_id(id) do
    if match?({:ok, _}, Ecto.UUID.cast(id)),
      do: :ok,
      else: {:error, {:invalid, "Malformed incident ID."}}
  end

  def incident_detail(id, at \\ now(), filters \\ %{}) do
    if validate_incident_id(id) == :ok and Repo.get(Mondek.ConditionIncident, id),
      do: Mondek.ConditionInspection.detail(id, filters, at),
      else: result_incident_detail(id, at)
  end

  defp result_incident_detail(id, at) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Incident{} = incident <- Repo.get(Incident, id) do
      assignment = Repo.get!(Assignment, incident.assignment_id)
      stream = incident.stream_id && Repo.get(ResultStream, incident.stream_id)
      current = if stream, do: stream.current, else: assignment.current
      all_occurrences = from o in Occurrence, where: o.incident_id == ^id

      unresolved =
        Repo.all(
          from o in all_occurrences,
            where: o.status not in ["delivered", "superseded"],
            order_by: [asc: o.inserted_at, asc: o.id],
            limit: 100
        )

      recent =
        Repo.all(
          from o in all_occurrences, order_by: [desc: o.inserted_at, desc: o.id], limit: 100
        )

      firing = Repo.all(from o in all_occurrences, where: o.kind == "firing", limit: 1)

      occurrences =
        (unresolved ++ recent ++ firing)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

      occurrence_ids = Enum.map(occurrences, & &1.id)
      displayed_attempts = from t in Attempt, where: t.occurrence_id in ^occurrence_ids

      # Include one attempt for each displayed occurrence, even when another
      # occurrence's retries would otherwise fill the recent-attempt window.
      per_occurrence =
        Repo.all(
          from t in displayed_attempts,
            distinct: t.occurrence_id,
            order_by: [desc: t.started_at, desc: t.id]
        )

      recent_attempts =
        Repo.all(
          from t in displayed_attempts, order_by: [desc: t.started_at, desc: t.id], limit: 200
        )

      attempts =
        (per_occurrence ++ recent_attempts)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

      all_attempts =
        from t in Attempt,
          join: o in Occurrence,
          on: t.occurrence_id == o.id,
          where: o.incident_id == ^id

      all_controls =
        from c in Control,
          where:
            c.incident_id == ^id or
              (c.kind in [
                 "maintenance",
                 "check_retired",
                 "source_removed",
                 "publisher_retired",
                 "publisher_replaced"
               ] and
                 c.assignment_id == ^incident.assignment_id and
                 (is_nil(c.stream_id) or
                    fragment(
                      "? IS NOT DISTINCT FROM ?",
                      c.stream_id,
                      type(^incident.stream_id, :binary_id)
                    )) and
                 c.until >= ^incident.opened_at)

      all_controls =
        if incident.closed_at,
          do:
            from(c in all_controls,
              where: c.kind == "notification_retry" or c.inserted_at <= ^incident.closed_at
            ),
          else: all_controls

      controls =
        Repo.all(from c in all_controls, order_by: [desc: c.inserted_at, desc: c.id], limit: 100)

      reference_ids =
        ([
           incident.opening_observation_id,
           incident.latest_observation_id,
           incident.closing_observation_id,
           current["observation_id"],
           current["confirmed_observation_id"]
         ] ++
           Enum.map(occurrences, & &1.payload["observation_id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      referenced = Repo.all(from o in Observation, where: o.id in ^reference_ids)

      recent_query =
        if stream,
          do: Mondek.Inspection.stream_evidence_query(stream),
          else: from(o in Observation, where: o.assignment_id == ^incident.assignment_id)

      recent_evidence =
        Repo.all(from o in recent_query, order_by: [desc: o.received_at, desc: o.id], limit: 12)

      evidence =
        (referenced ++ recent_evidence)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.received_at, {:desc, DateTime})

      %{
        "incident" => public(incident),
        "assignment" => assignment_detail(incident.assignment_id, at),
        "stream" => Mondek.Inspection.stream_detail(incident.stream_id, at),
        "occurrences" => inspect_occurrences(occurrences, at),
        "attempts" => Enum.map(attempts, &public/1),
        "controls" => Enum.map(controls, &public/1),
        "evidence" => Enum.map(evidence, &public/1),
        "limits" => %{
          "occurrences" => detail_limit(all_occurrences, occurrences, 201),
          "attempts" => detail_limit(all_attempts, attempts, 401),
          "controls" => detail_limit(all_controls, controls, 100),
          "evidence" => %{
            "referenced" => length(reference_ids),
            "missing" => length(reference_ids) - length(referenced),
            "recent_limit" => 12
          }
        }
      }
    else
      _ -> nil
    end
  end

  defp detail_limit(query, records, limit) do
    total = Repo.aggregate(query, :count)

    %{
      "total" => total,
      "returned" => length(records),
      "omitted" => max(0, total - length(records)),
      "limit" => limit
    }
  end

  def snapshot(at \\ now()) do
    runners = Repo.all(Runner)

    active_assignments =
      Repo.all(from a in Assignment, where: is_nil(a.retired_at), order_by: a.id, limit: 100)

    retired_assignments =
      Repo.all(
        from a in Assignment,
          where: not is_nil(a.retired_at),
          order_by: [desc: a.retired_at, asc: a.id],
          limit: 100
      )

    retired_total = Repo.aggregate(from(a in Assignment, where: not is_nil(a.retired_at)), :count)
    # The active check limit and partial uniqueness constraint bound open episodes;
    # recent terminal history must never displace live operator work.
    open_incidents =
      Repo.all(
        from i in Incident, where: i.status == "open", order_by: [desc: i.opened_at], limit: 100
      )

    closed_incidents =
      Repo.all(
        from i in Incident, where: i.status == "closed", order_by: [desc: i.closed_at], limit: 100
      )

    unresolved = from o in Occurrence, where: o.status not in ["delivered", "superseded"]
    backlog_total = Repo.aggregate(unresolved, :count)

    backlog =
      Repo.all(from o in unresolved, order_by: [asc: o.inserted_at, asc: o.id], limit: 100)

    terminal =
      Repo.all(
        from o in Occurrence,
          where: o.status in ["delivered", "superseded"],
          order_by: [desc: o.inserted_at],
          limit: 100
      )

    # Keep the check identity attached to every displayed incident/notification,
    # even if that retired check is outside the recent retirement window.
    parent_incident_ids = Enum.map(backlog ++ terminal, & &1.incident_id)

    parent_assignment_ids =
      Repo.all(from i in Incident, where: i.id in ^parent_incident_ids, select: i.assignment_id)

    reference_ids =
      Enum.uniq(
        parent_assignment_ids ++ Enum.map(open_incidents ++ closed_incidents, & &1.assignment_id)
      )

    referenced_assignments = Repo.all(from a in Assignment, where: a.id in ^reference_ids)

    assignments =
      Enum.uniq_by(active_assignments ++ retired_assignments ++ referenced_assignments, & &1.id)

    confirmed_configurations = confirmed_configurations(assignments)

    open_ids = Enum.map(open_incidents, & &1.id)

    opening_ids =
      Repo.all(
        from o in Occurrence,
          where: o.incident_id in ^open_ids and o.kind == "firing",
          select: fragment("?->>'observation_id'", o.payload)
      )

    current_ids =
      Enum.flat_map(assignments, fn a ->
        [a.current["observation_id"], a.current["confirmed_observation_id"]]
      end)

    evidence_ids =
      Enum.uniq(current_ids ++ opening_ids ++ Enum.map(backlog, & &1.payload["observation_id"]))
      |> Enum.reject(&is_nil/1)

    retained_evidence = Repo.all(from o in Observation, where: o.id in ^evidence_ids)
    recent_evidence = Repo.all(from o in Observation, order_by: [desc: o.received_at], limit: 120)

    evidence =
      (retained_evidence ++ recent_evidence)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.received_at, {:desc, DateTime})

    %{
      "version" => 1,
      "now" => iso(at),
      "assignments" =>
        Enum.map(assignments, fn a ->
          runner = Enum.find(runners, &(&1.id == a.runner_id))

          knowledge =
            cond do
              not is_nil(a.retired_at) ->
                "retired"

              a.current == %{} ->
                "awaiting"

              a.current["generation"] != a.authorized_generation or
                  (runner && a.current["session_id"] != runner.session_id) ->
                "awaiting"

              a.current["knowledge"] in ["unavailable", "stale"] ->
                a.current["knowledge"]

              not fresh?(a.current["source_at"], a.freshness_seconds, at) ->
                "stale"

              true ->
                "fresh"
            end

          current =
            a.current
            |> Map.put("knowledge", knowledge)
            |> Map.put(
              "confirmed_params",
              Map.get(confirmed_configurations, {a.id, a.current["confirmed_generation"]})
            )

          a
          |> public()
          |> Map.put("current", current)
          |> Map.put("observed_generation", a.current["confirmed_generation"])
        end),
      "runners" => Enum.map(runners, &public/1),
      "assignment_limits" => %{
        "active" => Repo.aggregate(from(a in Assignment, where: is_nil(a.retired_at)), :count),
        "active_returned" => length(active_assignments),
        "active_limit" => 512,
        "active_limit_scope" => "per_runner",
        "retired_total" => retired_total,
        "retired_returned" => Enum.count(assignments, & &1.retired_at),
        "retired_recent_limit" => 100
      },
      "incidents" => Enum.map(open_incidents ++ closed_incidents, &public/1),
      "condition_incidents" =>
        Repo.all(
          from g in Mondek.ConditionIncident,
            order_by: [desc: g.status, desc: g.opened_at],
            limit: 200
        )
        |> Enum.map(&public/1),
      "evidence" => Enum.map(evidence, &public/1),
      "occurrences" => inspect_occurrences(backlog ++ terminal, at),
      "notification_backlog" => %{
        "total" => backlog_total,
        "returned" => length(backlog),
        "omitted" => max(0, backlog_total - length(backlog)),
        "limit" => 100
      },
      "attempts" => recent(Attempt, :started_at, 200),
      "controls" => recent(Control, :inserted_at, 100),
      "jobs" =>
        Repo.all(
          from j in Oban.Job,
            where: j.worker == "Mondek.NotificationWorker",
            order_by: [desc: j.id],
            limit: 100,
            select: %{
              id: j.id,
              state: j.state,
              attempt: j.attempt,
              max_attempts: j.max_attempts,
              scheduled_at: j.scheduled_at,
              args: j.args
            }
        )
        |> Enum.map(fn j ->
          Map.new(j, fn {k, v} ->
            {Atom.to_string(k), if(match?(%DateTime{}, v), do: iso(v), else: v)}
          end)
        end),
      "retention" => Mondek.Retention.summary()
    }
  end

  # This is shared by inspection and dispatch. It describes eligibility only;
  # dispatch still takes the assignment/occurrence locks before acting on it.
  def delivery_eligibility(occurrence, incident, assignment, at, maintenance_windows \\ :load) do
    obsolete? =
      occurrence.kind != "resolved" and
        (incident.status != "open" or occurrence.attention_revision < incident.attention_revision)

    maintenance =
      cond do
        occurrence.kind == "resolved" or obsolete? or
          occurrence.status in ["delivered", "superseded"] or not is_nil(assignment.retired_at) ->
          []

        maintenance_windows == :load ->
          Mondek.Maintenance.active_for(incident, assignment, at)

        true ->
          maintenance_windows
      end

    maintenance_until = maintenance |> Enum.map(& &1.ends_at) |> Enum.max(DateTime, fn -> nil end)

    gates =
      if occurrence.kind == "resolved" do
        []
      else
        [
          {"acknowledgement",
           if(acknowledgement_active?(incident, at),
             do: incident.acknowledged_until,
             else: :inactive
           )},
          {"maintenance", maintenance_until}
        ]
        |> Enum.filter(fn
          {"acknowledgement", nil} -> true
          {_, :inactive} -> false
          {_, until} -> future?(until, at)
        end)
      end

    cond do
      occurrence.status == "delivered" ->
        :delivered

      occurrence.status == "superseded" or obsolete? or not is_nil(assignment.retired_at) ->
        :superseded

      gates != [] ->
        {:gated, Enum.map(gates, &elem(&1, 0)),
         if(Enum.any?(gates, &is_nil(elem(&1, 1))),
           do: nil,
           else: Enum.max_by(gates, &elem(&1, 1), DateTime) |> elem(1)
         )}

      true ->
        :eligible
    end
  end

  defp confirmed_configurations(assignments) do
    selected =
      Enum.reduce(assignments, dynamic(false), fn a, selected ->
        case a.current["confirmed_generation"] do
          generation when is_integer(generation) ->
            dynamic([c], ^selected or (c.assignment_id == ^a.id and c.generation == ^generation))

          _ ->
            selected
        end
      end)

    Repo.all(from c in Configuration, where: ^selected)
    |> Map.new(&{{&1.assignment_id, &1.generation}, &1.params})
  end

  def inspect_occurrences([], _at), do: []

  def inspect_occurrences(occurrences, at) do
    ids = Enum.map(occurrences, & &1.id)

    parents =
      Repo.all(
        from o in Occurrence,
          join: i in Incident,
          on: i.id == o.incident_id,
          join: a in Assignment,
          on: a.id == i.assignment_id,
          where: o.id in ^ids,
          select: {o.id, i, a}
      )
      |> Map.new(fn {id, incident, assignment} -> {id, {incident, assignment}} end)

    maintenance_windows = Mondek.Maintenance.active_for_many(Map.values(parents), at)

    condition_parents =
      Repo.all(
        from o in Occurrence,
          join: g in Mondek.ConditionIncident,
          on: g.id == o.condition_incident_id,
          where: o.id in ^ids,
          select: {o.id, g}
      )
      |> Map.new(fn {id, group} -> {id, {group, nil}} end)

    condition_contexts =
      condition_parents
      |> Map.values()
      |> Enum.map(fn {group, _} -> group.id end)
      |> Enum.uniq()
      |> Map.new(&{&1, Conditions.delivery_context(&1, at)})

    monitoring_parents =
      Repo.all(
        from o in Occurrence,
          join: i in Mondek.MonitoringIncident,
          on: i.id == o.monitoring_incident_id,
          where: o.id in ^ids,
          select: {o.id, i}
      )
      |> Map.new(fn {id, incident} -> {id, {incident, nil}} end)

    parents = parents |> Map.merge(condition_parents) |> Map.merge(monitoring_parents)

    latest_attempts =
      Repo.all(
        from t in Attempt,
          where: t.occurrence_id in ^ids,
          distinct: t.occurrence_id,
          order_by: [desc: t.started_at, desc: t.id]
      )
      |> Map.new(&{&1.occurrence_id, public(&1)})

    attempt_counts =
      Repo.all(
        from t in Attempt,
          where: t.occurrence_id in ^ids,
          group_by: t.occurrence_id,
          select: {t.occurrence_id, count(t.id)}
      )
      |> Map.new()

    scheduled =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "Mondek.NotificationWorker" and
              j.state in ["available", "scheduled", "retryable"] and
              fragment("?->>'occurrence_id'", j.args) in ^ids,
          group_by: fragment("?->>'occurrence_id'", j.args),
          select: {fragment("?->>'occurrence_id'", j.args), min(j.scheduled_at)}
      )
      |> Map.new()

    active_jobs =
      Repo.all(
        from j in Oban.Job,
          where:
            j.worker == "Mondek.NotificationWorker" and j.state in ^@active_job_states and
              fragment("?->>'occurrence_id'", j.args) in ^ids,
          select: fragment("?->>'occurrence_id'", j.args)
      )
      |> MapSet.new()

    # Ordinary history may expire between the bounded reads. Current and open
    # work is protected; omit a concurrently expired historical parent.
    occurrences
    |> Enum.filter(&Map.has_key?(parents, &1.id))
    |> Enum.map(fn occurrence ->
      {incident, assignment} = Map.fetch!(parents, occurrence.id)

      eligible_maintenance =
        cond do
          occurrence.monitoring_incident_id ->
            Mondek.MonitoringLoss.maintenance_windows(incident, at)

          assignment ->
            Map.get(maintenance_windows, incident.id, [])

          true ->
            Conditions.supporting_maintenance(
              occurrence,
              Map.fetch!(condition_contexts, incident.id)
            )
        end

      eligibility =
        cond do
          occurrence.monitoring_incident_id ->
            Mondek.MonitoringLoss.delivery_eligibility(occurrence, incident, at)

          assignment ->
            delivery_eligibility(occurrence, incident, assignment, at, eligible_maintenance)

          true ->
            Conditions.delivery_eligibility(
              occurrence,
              incident,
              at,
              Map.fetch!(condition_contexts, incident.id)
            )
        end

      {gates, gated_until} =
        case eligibility do
          {:gated, gates, until} -> {gates, until}
          _ -> {[], nil}
        end

      next_retry =
        if eligibility not in [:delivered, :superseded] and
             occurrence.status not in ["exhausted", "delivering"] and
             not (gates != [] and is_nil(gated_until)) do
          case Map.get(scheduled, occurrence.id) do
            nil ->
              nil

            scheduled_at ->
              Enum.max([scheduled_at, gated_until] |> Enum.reject(&is_nil/1), DateTime)
          end
        end

      occurrence
      |> public()
      |> Map.merge(%{
        "assignment_id" => assignment && assignment.id,
        "check_label" => if(assignment, do: assignment.label, else: incident.label),
        "incident_status" => incident.status,
        "gates" => gates,
        "waiting_on_gates" => gates != [] and occurrence.status in ["pending", "retrying"],
        "gated_until" => iso(gated_until),
        "gated_indefinitely" => gates != [] and is_nil(gated_until),
        "maintenance_windows" =>
          Enum.map(eligible_maintenance, fn window ->
            if assignment, do: public(window), else: Mondek.Maintenance.reference(window)
          end),
        "next_retry_at" => iso(next_retry),
        "latest_attempt" => Map.get(latest_attempts, occurrence.id),
        "attempt_count" => Map.get(attempt_counts, occurrence.id, 0),
        "can_retry" =>
          occurrence.status == "exhausted" and eligibility not in [:delivered, :superseded] and
            not MapSet.member?(active_jobs, occurrence.id)
      })
    end)
  end

  defp recent(schema, order, count),
    do:
      Repo.all(from r in schema, order_by: [desc: field(r, ^order)], limit: ^count)
      |> Enum.map(&public/1)

  def assignment_detail(id, at \\ now()) do
    case lookup_assignment(id, false) do
      nil ->
        nil

      assignment ->
        runner = assignment.runner_id && Repo.get(Runner, assignment.runner_id)

        knowledge =
          cond do
            assignment.retired_at ->
              "retired"

            assignment.current == %{} ->
              "awaiting"

            assignment.current["generation"] != assignment.authorized_generation or
                (runner && assignment.current["session_id"] != runner.session_id) ->
              "awaiting"

            assignment.current["knowledge"] in ["unavailable", "stale"] ->
              assignment.current["knowledge"]

            not fresh?(assignment.current["source_at"], assignment.freshness_seconds, at) ->
              "stale"

            true ->
              "fresh"
          end

        confirmed = confirmed_configurations([assignment])

        current =
          assignment.current
          |> Map.put("knowledge", knowledge)
          |> Map.put(
            "confirmed_params",
            Map.get(confirmed, {id, assignment.current["confirmed_generation"]})
          )

        public(assignment)
        |> Map.put("current", current)
        |> Map.put("runner_label", runner && runner.label)
        |> Map.put("observed_generation", assignment.observed_generation)
        |> Map.put("streams", Mondek.Inspection.streams_for(id, at))
    end
  end

  def assignment_inspection(id, at \\ now()) do
    case assignment_detail(id, at) do
      nil ->
        nil

      assignment ->
        all_incidents = from i in Incident, where: i.assignment_id == ^id

        open =
          Repo.all(
            from i in all_incidents, where: i.status == "open", order_by: [desc: i.opened_at]
          )

        recent =
          Repo.all(
            from i in all_incidents,
              where: i.status == "closed",
              order_by: [desc: i.closed_at],
              limit: 100
          )

        incidents = open ++ recent
        all_controls = from c in Control, where: c.assignment_id == ^id

        controls =
          Repo.all(
            from c in all_controls, order_by: [desc: c.inserted_at, desc: c.id], limit: 100
          )

        reference_ids =
          ([
             assignment["current"]["observation_id"],
             assignment["current"]["confirmed_observation_id"]
           ] ++
             Enum.map(incidents, & &1.closing_observation_id))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        referenced = Repo.all(from o in Observation, where: o.id in ^reference_ids)

        recent_evidence =
          Repo.all(
            from o in Observation,
              where: o.assignment_id == ^id,
              order_by: [desc: o.received_at, desc: o.id],
              limit: 12
          )

        evidence =
          (referenced ++ recent_evidence)
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(& &1.received_at, {:desc, DateTime})

        %{
          "assignment" => assignment,
          "incidents" => Enum.map(incidents, &public/1),
          "controls" => Enum.map(controls, &public/1),
          "evidence" => Enum.map(evidence, &public/1),
          "limits" => %{
            "incidents" => detail_limit(all_incidents, incidents, 101),
            "controls" => detail_limit(all_controls, controls, 100),
            "evidence" => %{
              "referenced" => length(reference_ids),
              "missing" => length(reference_ids) - length(referenced),
              "recent_limit" => 12
            }
          }
        }
    end
  end

  def public(%Assignment{} = assignment),
    do: public_record(assignment) |> Map.put("retired", not is_nil(assignment.retired_at))

  def public(struct), do: public_record(struct)

  defp public_record(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), if(match?(%DateTime{}, value), do: iso(value), else: value)}
    end)
  end

  def lock_assignment(id), do: lookup_assignment(id, true)

  defp lookup_assignment(id, lock?) do
    if Mondek.Protocol.assignment_id?(id) do
      query = from a in Assignment, where: a.id == ^id
      Repo.one(if lock?, do: lock(query, "FOR UPDATE"), else: query)
    end
  end

  def wire(a) do
    config = %{
      "id" => a.id,
      "kind" => a.kind,
      "generation" => a.desired_generation,
      "params" => a.params,
      "interval_seconds" => a.interval_seconds,
      "timeout_seconds" => a.timeout_seconds,
      "freshness_seconds" => a.freshness_seconds,
      "expected_keys" => a.expected_keys,
      "source_id" => a.source_id,
      "source_key" => a.source_key,
      "source_revision" => a.source_revision,
      "definition_revision" => a.definition_revision,
      "environment" => a.environment,
      "environment_label" => a.environment_label,
      "params_owner" => a.params_owner,
      "parameter_schema" => a.parameter_schema,
      "outputs" => a.outputs
    }

    if a.parameter_contract,
      do: Map.put(config, "parameter_contract", a.parameter_contract),
      else: config
  end

  def parse!(value), do: elem(DateTime.from_iso8601(value), 1)
  def iso(nil), do: nil
  def iso(value), do: DateTime.to_iso8601(value)
  def fresh?(nil, _, _), do: false

  def fresh?(source, seconds, at) do
    case DateTime.from_iso8601(source) do
      {:ok, time, _} ->
        DateTime.diff(at, time, :microsecond) >= -2_000_000 and
          DateTime.diff(at, time, :microsecond) < seconds * 1_000_000

      _ ->
        false
    end
  end

  def future?(nil, _), do: false
  def future?(time, at), do: DateTime.compare(time, at) == :gt
  def severity("CRIT"), do: 3
  def severity("WARN"), do: 2
  def severity("UNKNOWN"), do: 1
  def severity(_), do: 0
end

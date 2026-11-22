# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationGroupingEvaluation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_grouping_evaluations" do
    field :incident_id, Ecto.UUID
    field :condition_incident_id, Ecto.UUID
    field :case_id, Ecto.UUID
    field :disposition, :string
    field :reason, :string
    field :evidence, :map
    field :evaluated_at, :utc_datetime_usec
  end
end

defmodule Mondek.CorrelationGrouping do
  @moduledoc "Applies approved primary dependency rules before either episode's first delivery attempt."
  import Ecto.Query

  alias Mondek.{
    Assignment,
    Attempt,
    CaseControls,
    Conditions,
    Configuration,
    CorrelationAttempt,
    CorrelationCandidates,
    CorrelationGroupingEvaluation,
    CorrelationMembership,
    CorrelationReservation,
    Correlations,
    Incident,
    Maintenance,
    Monitoring,
    Occurrence,
    Repo,
    ResultStream
  }

  alias Mondek.CorrelationAutomationPolicy, as: Policy
  alias Mondek.CorrelationGroupingWorker, as: Worker

  @page 32

  def enqueue_opening!(incident) do
    if Policy.enabled?() do
      enqueue_subject!(canonical(incident))
      enqueue!(%{"opening" => incident.id})
    end
  end

  def enqueue_resume!(ref) do
    enqueue_subject!(ref)

    case ref do
      %{"type" => "individual", "id" => id} -> enqueue!(%{"opening" => id})
      %{"type" => "condition", "id" => id} -> enqueue!(%{"resume_condition" => id})
    end
  end

  def resume_condition(id, cursor) do
    Repo.transaction(fn ->
      query =
        from i in Incident,
          where: i.condition_incident_id == ^id and i.status == "open",
          order_by: i.id,
          limit: ^(@page + 1),
          select: i.id

      ids = Repo.all(if cursor, do: where(query, [i], i.id > ^cursor), else: query)
      Enum.each(Enum.take(ids, @page), &enqueue!(%{"opening" => &1}))

      if length(ids) > @page,
        do: enqueue!(%{"resume_condition" => id, "cursor" => Enum.at(ids, @page - 1)})
    end)
  end

  def enqueue_subject!(ref), do: enqueue!(%{"subject" => ref})
  defp enqueue!(args), do: args |> Worker.new() |> Oban.insert!()

  defp canonical(%Incident{condition_incident_id: nil, id: id}),
    do: %{"type" => "individual", "id" => id}

  defp canonical(%Incident{condition_incident_id: id}), do: %{"type" => "condition", "id" => id}

  # A parent can open after a child. Select only opening declarations matching
  # its placement or condition; page by immutable contribution ID. Each child
  # gets its own fresh, fenced search irrespective of the reverse scan.
  def reverse(opening, cursor) do
    Repo.transaction(fn ->
      if Policy.enabled?() do
        if parent = opening_placement(opening) do
          children = reverse_children(parent, cursor)

          children
          |> Enum.take(@page)
          |> Enum.map(&canonical/1)
          |> Enum.uniq()
          |> Enum.each(&enqueue_subject!/1)

          if length(children) > @page,
            do: enqueue!(%{"opening" => opening, "cursor" => Enum.at(children, @page - 1).id})
        end
      end
    end)
  end

  defp opening_placement(id) do
    Repo.one(
      from i in Incident,
        join: a in Assignment,
        on: a.id == i.assignment_id,
        join: s in ResultStream,
        on: s.id == i.stream_id,
        left_join: g in Mondek.ConditionIncident,
        on: g.id == i.condition_incident_id,
        where: i.id == ^id and i.status == "open",
        select: %{
          id: i.id,
          opened_at: type(fragment("LEAST(?, ?)", g.opened_at, i.opened_at), :utc_datetime_usec),
          environment: i.environment,
          target: s.target,
          source_id: a.source_id,
          namespace: g.namespace,
          key: g.key
        }
    )
  end

  defp reverse_children(parent, cursor) do
    target =
      if parent.target do
        Map.merge(Map.take(parent.target, ~w(kind key)), %{
          "type" => "target",
          "source_id" => parent.source_id
        })
      end

    condition =
      if parent.namespace do
        %{"type" => "condition", "namespace" => parent.namespace, "key" => parent.key}
      end

    selectors = Enum.reject([target, condition], &is_nil/1)

    matches =
      Enum.reduce(selectors, dynamic(false), fn selector, acc ->
        dynamic(
          [i, c],
          ^acc or
            fragment(
              "? @> jsonb_build_object('outputs', jsonb_build_array(jsonb_build_object('key', ?::text, 'correlation_hints', jsonb_build_array(jsonb_build_object('depends_on', ?::jsonb)))))",
              c.definition,
              i.result_key,
              type(^selector, :map)
            )
        )
      end)

    lower = DateTime.add(parent.opened_at, -86_400)

    query =
      from i in Incident,
        join: c in Configuration,
        on: c.assignment_id == i.assignment_id and c.generation == i.opening_generation,
        where: i.status == "open" and i.id != ^parent.id and i.opened_at >= ^lower,
        where:
          fragment("? IS NOT DISTINCT FROM ?", i.environment, type(^parent.environment, :string)),
        where: ^matches,
        order_by: i.id,
        limit: ^(@page + 1),
        select: i

    Repo.all(if cursor, do: where(query, [i], i.id > ^cursor), else: query)
  end

  def evaluate(%{"type" => type, "id" => id} = subject, at \\ nil) do
    if approved_declarations(type, id) == [] do
      {:ok, nil}
    else
      Repo.transaction(fn ->
        Maintenance.lock!(:shared)
        Correlations.lock!()
        declarations = CorrelationCandidates.opening_rules(type, id)
        rules = approvals(declarations)

        if rules != [] do
          search = CorrelationCandidates.for_episode(type, id)

          if search && search["subject"] == subject do
            contributors = declarations |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
            decide(subject, search, rules, contributors, at)
          end
        end
      end)
    end
  end

  defp approved_declarations(type, id),
    do: type |> CorrelationCandidates.opening_rules(id) |> approvals()

  defp approvals(declarations) do
    approvals = declarations |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Policy.approved_rules()

    for {scope, contributor} <- declarations,
        rule = approvals[scope],
        do: %{
          "id" => rule.id,
          "revision" => rule.revision,
          "scope" => scope,
          "contributor" => contributor
        }
  end

  defp decide(subject, search, rules, contributors, at) do
    candidates = search["candidates"]
    evidence = %{"version" => 1, "rules" => rules, "search" => search}

    case {search, candidates} do
      {%{"status" => "complete", "conflicting_hints" => false}, [one]} ->
        parent = Map.take(one, ~w(id type))
        refs = [subject, parent]
        CaseControls.lock_owners!(refs)
        at = at || Monitoring.now()

        approved? =
          Enum.all?(contributors, fn contributor ->
            Enum.any?(rules, fn rule ->
              rule["contributor"] == contributor &&
                Enum.any?(one["matches"], fn match ->
                  Map.take(match, ~w(dimension depends_on window_seconds)) ==
                    rule["scope"]["hint"] &&
                    contributor in match["contributors"]
                end)
            end)
          end)

        reason =
          cond do
            !approved? -> "unapproved_match"
            Enum.any?(refs, &Policy.overridden?/1) -> "operator_override"
            Enum.any?(refs, &member?/1) -> "already_grouped"
            Enum.any?(refs, &held?(&1, at)) -> "native_hold"
            Enum.any?(refs, &delivery_started?/1) -> "delivery_history"
            true -> nil
          end

        if reason do
          record(subject, "review", reason, evidence, nil, at)
        else
          id = Correlations.create_from_rule!(subject, parent, one["label"], evidence, at)
          record(subject, "created", "unique_approved_parent", evidence, id, at)
        end

      _ ->
        reason =
          cond do
            search["status"] != "complete" -> "incomplete_search"
            search["conflicting_hints"] -> "conflicting_hints"
            candidates == [] -> "no_match"
            true -> "multiple_parents"
          end

        record(subject, "review", reason, evidence, nil, at || Monitoring.now())
    end
  end

  defp key("condition"), do: :condition_incident_id
  defp key("individual"), do: :incident_id

  defp member?(%{"type" => t, "id" => id}),
    do:
      Repo.exists?(
        from m in CorrelationMembership,
          where: field(m, ^key(t)) == ^id and is_nil(m.ended_at)
      )

  defp held?(%{"type" => "individual"} = ref, at) do
    i = CaseControls.episode(ref)

    Monitoring.acknowledgement_active?(i, at) ||
      Maintenance.active_for(i, Repo.get!(Assignment, i.assignment_id), at) != []
  end

  defp held?(ref, at) do
    g = CaseControls.episode(ref)
    ctx = Conditions.delivery_context(g.id, at)

    Monitoring.acknowledgement_active?(g, at) ||
      Enum.any?(ctx.members, fn {i, _} ->
        Monitoring.acknowledgement_active?(i, at) || Map.get(ctx.maintenance, i.id, []) != []
      end)
  end

  defp delivery_started?(%{"type" => t, "id" => id}) do
    occurrences = from o in Occurrence, where: field(o, ^key(t)) == ^id, select: o.id

    reservations =
      from r in CorrelationReservation, where: r.occurrence_id in subquery(occurrences)

    Repo.exists?(from a in Attempt, where: a.occurrence_id in subquery(occurrences)) ||
      Repo.exists?(from r in reservations, where: r.status == "reserved") ||
      Repo.exists?(
        from r in reservations, join: a in CorrelationAttempt, on: a.batch_id == r.batch_id
      )
  end

  defp record(%{"type" => type, "id" => id}, disposition, reason, evidence, case_id, at) do
    k = key(type)
    existing = Repo.get_by(CorrelationGroupingEvaluation, [{k, id}])
    # Replayed jobs cannot replace the successful decision with an already-grouped warning.
    preserve? =
      existing && existing.disposition == "created" && disposition == "review" &&
        match?(
          %{"case_id" => case_id} when case_id == existing.case_id,
          Correlations.membership(type, id)
        )

    unless preserve? do
      (existing || struct(CorrelationGroupingEvaluation, [{k, id}]))
      |> Ecto.Changeset.change(
        disposition: disposition,
        reason: reason,
        evidence: evidence,
        case_id: case_id,
        evaluated_at: at
      )
      |> Repo.insert_or_update!()
    end

    disposition
  end

  def latest(type, id) when type in ["condition", "individual"] do
    if row = Repo.get_by(CorrelationGroupingEvaluation, [{key(type), id}]) do
      %{
        "disposition" => row.disposition,
        "reason" => row.reason,
        "case_id" => row.case_id,
        "evidence" => row.evidence,
        "evaluated_at" => Monitoring.iso(row.evaluated_at)
      }
    end
  end
end

defmodule Mondek.CorrelationGroupingWorker do
  use Oban.Worker, queue: :correlations, max_attempts: 10

  @impl true
  def perform(%Oban.Job{args: args}) do
    result =
      case args do
        %{"subject" => ref} ->
          Mondek.CorrelationGrouping.evaluate(ref)

        %{"resume_condition" => id} ->
          Mondek.CorrelationGrouping.resume_condition(id, args["cursor"])

        %{"opening" => id} ->
          Mondek.CorrelationGrouping.reverse(id, args["cursor"])
      end

    case result do
      {:ok, status} when status in ["created", "review"] ->
        Mondek.Monitoring.notify()
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end

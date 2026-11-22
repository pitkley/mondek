# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationCase do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_cases" do
    field :topology_revision, :integer, default: 1
    field :batching_enabled, :boolean, default: false
    field :title, :string
    field :environment, :string
    field :revision, :integer, default: 1
    field :inserted_at, :utc_datetime_usec
    field :terminal_reason, :string
    field :terminal_at, :utc_datetime_usec
  end
end

defmodule Mondek.CorrelationMembership do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_memberships" do
    field :case_id, Ecto.UUID
    field :incident_id, Ecto.UUID
    field :condition_incident_id, Ecto.UUID
    field :provenance, :string, default: "operator"
    field :anchor, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :end_reason, :string
  end
end

defmodule Mondek.CorrelationDecision do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_decisions" do
    field :case_id, Ecto.UUID
    field :action, :string
    field :provenance, :string
    field :actor, :string
    field :reason, :string
    field :confidence, :float
    field :inserted_at, :utc_datetime_usec
    field :change, :map
  end
end

defmodule Mondek.CorrelationReceipt do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "correlation_receipts" do
    field :fingerprint, :string
    field :case_id, Ecto.UUID
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.Correlations do
  @moduledoc "Reviewed manual grouping; never grants acknowledgement or notification inhibition."
  import Ecto.Query
  alias Mondek.{Repo, Monitoring, Conditions, Incident, ConditionIncident}
  alias Mondek.{CorrelationCase, CorrelationMembership, CorrelationDecision, CorrelationReceipt}
  @salt "correlation-review-v1"
  @limit 250

  def lock!(mode \\ :exclusive) do
    function =
      if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Repo.query!("SELECT #{function}(774021)")
  end

  def preview(proposal, at \\ Monitoring.now()) do
    transact(fn ->
      p = validate!(proposal)
      state = state!(p)

      %{
        "proposal" => p,
        "review_token" =>
          Phoenix.Token.sign(MondekWeb.Endpoint, @salt, {p, state_fingerprint(state)}),
        "notification_effect" => "case_policy",
        "cases" => Enum.map(state.cases, &summary(&1)),
        "as_of" => Monitoring.iso(at)
      }
    end)
  end

  def apply(token, at \\ Monitoring.now()) do
    with {:ok, {p, expected}} <- verify(token) do
      transact(fn ->
        hash = fingerprint(p)

        case Repo.get(CorrelationReceipt, p["request_id"]) do
          %CorrelationReceipt{fingerprint: ^hash, case_id: id} ->
            %{"case_id" => id, "replayed" => true}

          %CorrelationReceipt{} ->
            Repo.rollback(:review_changed)

          nil ->
            state = state!(p)
            if state_fingerprint(state) != expected, do: Repo.rollback(:review_changed)
            id = execute!(p, state, at)

            Repo.insert!(%CorrelationReceipt{
              id: p["request_id"],
              fingerprint: hash,
              case_id: id,
              inserted_at: at
            })

            %{"case_id" => id, "replayed" => false}
        end
      end)
    end
  end

  defp transact(fun) do
    Repo.transaction(fn ->
      lock!()
      fun.()
    end)
  end

  defp verify(token) when is_binary(token) do
    case Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, {p, _} = data} when is_map(p) -> {:ok, data}
      {:error, :expired} -> {:error, :review_expired}
      _ -> {:error, :invalid_review}
    end
  end

  defp verify(_), do: {:error, :invalid_review}
  defp invalid(message), do: Repo.rollback({:invalid, message})

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()

  defp state_fingerprint(s) do
    fingerprint(%{
      cases: s.cases,
      memberships: s.memberships,
      episodes:
        Enum.map(
          s.episodes,
          &Map.take(&1, [
            :id,
            :status,
            :health,
            :attention_revision,
            :acknowledgement_revision,
            :condition_incident_id
          ])
        )
    })
  end

  defp validate!(p) when is_map(p) do
    fields = ~w(action request_id case_id other_case_id episodes anchor title reason)
    if Map.keys(p) -- fields != [], do: invalid("Unknown proposal fields.")

    if p["action"] not in ~w(create attach detach merge split anchor),
      do: invalid("Choose a grouping action.")

    if not text?(p["reason"], 2000), do: invalid("A reason of at most 2000 bytes is required.")

    if p["action"] in ~w(create split) and not text?(p["title"], 200),
      do: invalid("A title of at most 200 bytes is required.")

    p =
      Enum.reduce(~w(request_id case_id other_case_id), p, fn key, acc ->
        if Map.has_key?(acc, key), do: Map.update!(acc, key, &uuid!/1), else: acc
      end)

    if is_nil(p["request_id"]), do: invalid("A request identity is required.")

    if p["action"] != "create" and is_nil(p["case_id"]),
      do: invalid("A case identity is required.")

    if p["action"] == "merge" and is_nil(p["other_case_id"]),
      do: invalid("A source case identity is required.")

    allowed =
      case p["action"] do
        "create" -> ~w(action request_id episodes anchor title reason)
        "attach" -> ~w(action request_id case_id episodes reason)
        "detach" -> ~w(action request_id case_id episodes reason)
        "merge" -> ~w(action request_id case_id other_case_id reason)
        "split" -> ~w(action request_id case_id episodes anchor title reason)
        "anchor" -> ~w(action request_id case_id anchor reason)
      end

    if Map.keys(p) -- allowed != [], do: invalid("Fields do not match the action.")
    episodes = p["episodes"] || []

    if not is_list(episodes) or length(episodes) > @limit,
      do: invalid("Select at most 250 episodes.")

    episodes = Enum.map(episodes, &reference!/1)
    p = Map.put(p, "episodes", episodes)
    if length(Enum.uniq(episodes)) != length(episodes), do: invalid("Duplicate episodes.")

    if p["action"] in ~w(create attach detach split) and episodes == [],
      do: invalid("Select episodes.")

    p = if p["anchor"], do: Map.update!(p, "anchor", &reference!/1), else: p

    if p["action"] == "merge" and p["case_id"] == p["other_case_id"],
      do: invalid("Choose distinct cases.")

    p |> Map.put("episodes", Enum.sort(episodes)) |> Map.put_new("anchor", nil)
  end

  defp validate!(_), do: invalid("Supply a proposal.")

  defp text?(s, max),
    do:
      is_binary(s) and byte_size(s) <= max and String.trim(s) != "" and
        not String.contains?(s, <<0>>)

  defp uuid!(s) do
    case Ecto.UUID.cast(s) do
      {:ok, id} -> id
      _ -> invalid("Invalid identity.")
    end
  end

  defp reference!(%{"id" => id, "type" => t} = r) when t in ~w(individual condition) do
    if map_size(r) != 2, do: invalid("Invalid episode reference.")
    %{"id" => uuid!(id), "type" => t}
  end

  defp reference!(_), do: invalid("Use a typed health episode reference.")

  defp state!(p) do
    ids = Enum.filter([p["case_id"], p["other_case_id"]], & &1)
    cases = Enum.map(ids, fn id -> Repo.get(CorrelationCase, id) || Repo.rollback(:not_found) end)

    memberships =
      Repo.all(
        from m in CorrelationMembership,
          where: m.case_id in ^ids and is_nil(m.ended_at),
          order_by: m.id
      )

    refs =
      (Enum.map(memberships, &ref/1) ++ p["episodes"] ++ List.wrap(p["anchor"]))
      |> Enum.uniq()
      |> Enum.sort()

    # Native writers take the shared topology gate before native owners.
    # Acquire the complete owner set before touching case rows.
    individuals = Enum.filter(refs, &(&1["type"] == "individual")) |> Enum.map(&episode!/1)

    Enum.each(
      individuals |> Enum.map(& &1.assignment_id) |> Enum.uniq() |> Enum.sort(),
      &Monitoring.lock_assignment/1
    )

    Conditions.lock_ids!(for r <- refs, r["type"] == "condition", do: r["id"])
    episodes = Enum.map(refs, &episode!/1)

    Enum.each(cases, fn c ->
      if summary(c)["status"] != "open", do: Repo.rollback(:case_closed)
    end)

    selected = Enum.map(p["episodes"], &episode!/1)

    if p["action"] != "detach" and Enum.any?(selected, &(&1.status != "open")),
      do: Repo.rollback(:episode_closed)

    envs = Enum.uniq(Enum.map(episodes, & &1.environment) ++ Enum.map(cases, & &1.environment))

    if length(envs) != 1,
      do: invalid("All episodes must have the same exact monitored environment.")

    Enum.each(selected, fn e ->
      existing =
        Repo.one(
          from m in CorrelationMembership,
            where:
              is_nil(m.ended_at) and (m.incident_id == ^e.id or m.condition_incident_id == ^e.id)
        )

      cond do
        p["action"] in ~w(create attach) and existing ->
          Repo.rollback(:already_grouped)

        p["action"] in ~w(detach split) and (is_nil(existing) or existing.case_id != p["case_id"]) ->
          Repo.rollback(:review_changed)

        true ->
          :ok
      end
    end)

    if p["action"] in ~w(create attach merge split) do
      count =
        case p["action"] do
          "create" -> length(selected)
          "attach" -> length(memberships) + length(selected)
          "merge" -> length(memberships)
          "split" -> length(selected)
        end

      if count > @limit, do: invalid("Cases support at most 250 active episodes.")
    end

    allowed =
      case p["action"] do
        a when a in ~w(create split) -> p["episodes"]
        "detach" -> Enum.map(memberships, &ref/1) -- p["episodes"]
        _ -> Enum.map(memberships, &ref/1) ++ p["episodes"]
      end

    if p["anchor"] && p["anchor"] not in allowed,
      do: invalid("Anchor must be a member of the resulting case.")

    %{cases: cases, memberships: memberships, episodes: episodes}
  end

  defp episode!(%{"type" => type, "id" => id}) do
    row =
      Repo.get(if(type == "condition", do: ConditionIncident, else: Incident), id) ||
        Repo.rollback(:not_found)

    if type == "individual" and row.condition_incident_id,
      do: invalid("Select the containing condition episode.")

    row
  end

  defp ref(m),
    do: %{
      "type" => if(m.incident_id, do: "individual", else: "condition"),
      "id" => m.incident_id || m.condition_incident_id
    }

  defp change(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  @doc false
  def create_from_rule!(subject, parent, label, evidence, at) do
    proposal = %{
      "action" => "create",
      "episodes" => [parent, subject],
      "anchor" => parent,
      "title" => String.slice(label, 0, 200),
      "reason" => "One eligible upstream episode matched an approved dependency."
    }

    execute!(proposal, state!(proposal), at, evidence)
  end

  defp execute!(p, s, at, rule_evidence \\ nil) do
    destination =
      if p["action"] in ~w(create split) do
        Repo.insert!(%CorrelationCase{
          title: p["title"],
          environment: hd(s.episodes).environment,
          inserted_at: at
        })
      else
        hd(s.cases)
      end

    for c <- s.cases do
      Mondek.CaseControls.end!(c.id, "Topology changed", at)
      Mondek.CorrelationDelivery.release_case!(c.id)
    end

    ending =
      case p["action"] do
        "merge" -> Enum.filter(s.memberships, &(&1.case_id == p["other_case_id"]))
        a when a in ~w(detach split) -> Enum.filter(s.memberships, &(ref(&1) in p["episodes"]))
        _ -> []
      end

    Enum.each(ending, &change(&1, ended_at: at, end_reason: p["action"]))

    if p["action"] == "detach" do
      Enum.each(ending, fn m ->
        Mondek.CorrelationAutomationPolicy.set_override!(ref(m), true, p["reason"], at)
      end)
    end

    adding =
      case p["action"] do
        "merge" -> Enum.map(ending, &ref/1)
        a when a in ~w(create attach split) -> p["episodes"]
        _ -> []
      end

    Enum.each(adding, fn r ->
      Repo.insert!(%CorrelationMembership{
        case_id: destination.id,
        provenance: if(rule_evidence, do: "deterministic_rule", else: "operator"),
        incident_id: if(r["type"] == "individual", do: r["id"]),
        condition_incident_id: if(r["type"] == "condition", do: r["id"]),
        inserted_at: at
      })
    end)

    if p["action"] in ~w(create split anchor) do
      Repo.update_all(
        from(m in CorrelationMembership,
          where: m.case_id == ^destination.id and is_nil(m.ended_at)
        ),
        set: [anchor: false]
      )

      if p["anchor"] do
        m =
          Repo.all(
            from m in CorrelationMembership,
              where: m.case_id == ^destination.id and is_nil(m.ended_at)
          )
          |> Enum.find(&(ref(&1) == p["anchor"]))

        change(m, anchor: true)
      end
    end

    for c <- Enum.uniq_by([destination | s.cases], & &1.id) do
      Mondek.CaseControls.end!(c.id, "Topology changed", at)
      Mondek.CorrelationDelivery.release_case!(c.id)

      live =
        Repo.all(
          from m in CorrelationMembership, where: m.case_id == ^c.id and is_nil(m.ended_at)
        )

      ended = not Enum.any?(live, &(episode!(ref(&1)).status == "open"))

      change(c,
        revision: c.revision + 1,
        topology_revision: c.topology_revision + 1,
        terminal_at: if(ended, do: at),
        terminal_reason: if(ended, do: p["action"])
      )

      Repo.insert!(%CorrelationDecision{
        case_id: c.id,
        action: p["action"],
        provenance: if(rule_evidence, do: "deterministic_rule", else: "operator"),
        actor: if(rule_evidence, do: "Mondek correlation rule", else: "Local operator"),
        reason: p["reason"],
        inserted_at: at,
        change:
          %{
            "proposal" => p,
            "ended_membership_ids" => Enum.map(ending, & &1.id),
            "previous_anchor" => Enum.filter(s.memberships, & &1.anchor) |> Enum.map(&ref/1)
          }
          |> Map.merge(if(rule_evidence, do: %{"rule_evidence" => rule_evidence}, else: %{}))
      })
    end

    destination.id
  end

  def summary(c) do
    members =
      Repo.all(
        from m in CorrelationMembership,
          where: m.case_id == ^c.id and is_nil(m.ended_at),
          order_by: m.id
      )

    rows = episodes(Enum.map(members, &ref/1))
    open = Enum.filter(rows, &(&1.status == "open"))

    %{
      "id" => c.id,
      "title" => c.title,
      "environment" => c.environment,
      "revision" => c.revision,
      "status" => if(c.terminal_at || open == [], do: "closed", else: "open"),
      "closed_at" =>
        close_time(
          c.terminal_at ||
            if(open == [], do: Enum.max_by(rows, & &1.closed_at, DateTime, fn -> nil end))
        ),
      "closure_reason" => c.terminal_reason || if(open == [] and rows != [], do: "members_ended"),
      "health" =>
        cond do
          Enum.any?(open, &(&1.health == "CRIT")) -> "CRIT"
          open != [] -> "WARN"
          true -> nil
        end,
      "member_count" => length(members),
      "open_count" => length(open),
      "inserted_at" => Monitoring.iso(c.inserted_at),
      "anchor" => Enum.find(members, & &1.anchor) |> then(fn m -> if m, do: ref(m) end),
      "notification_effect" => "case_policy"
    }
  end

  defp close_time(nil), do: nil
  defp close_time(%DateTime{} = at), do: Monitoring.iso(at)
  defp close_time(row), do: close_time(row.closed_at)

  defp episodes(refs) do
    ids = for r <- refs, r["type"] == "individual", do: r["id"]
    groups = for r <- refs, r["type"] == "condition", do: r["id"]

    Repo.all(from i in Incident, where: i.id in ^ids) ++
      Repo.all(from g in ConditionIncident, where: g.id in ^groups)
  end

  def candidates(filters, at) do
    page = Mondek.Investigation.health_incidents(Map.merge(filters, %{"status" => "open"}), at)

    items =
      Enum.map(page["items"], fn i ->
        relation = membership(i["incident_type"], i["id"])
        Map.put(i, "correlation", relation)
      end)

    Map.put(page, "items", items)
  end

  def list(filters \\ %{}) do
    query =
      from c in CorrelationCase,
        order_by: [desc: c.inserted_at, desc: c.id]

    status = filters["status"]

    open =
      dynamic(
        [c],
        is_nil(c.terminal_at) and
          fragment(
            "EXISTS (SELECT 1 FROM correlation_memberships m LEFT JOIN incidents i ON i.id=m.incident_id LEFT JOIN condition_incidents g ON g.id=m.condition_incident_id WHERE m.case_id=? AND m.ended_at IS NULL AND (i.status='open' OR g.status='open'))",
            c.id
          )
      )

    query =
      case status do
        "open" -> from c in query, where: ^open
        "closed" -> from c in query, where: not (^open)
        _ -> query
      end

    paged(query, filters["page"], &summary/1)
  end

  def detail(id, filters \\ %{}) do
    case Repo.get(CorrelationCase, id) do
      nil ->
        nil

      c ->
        members =
          from m in CorrelationMembership,
            where: m.case_id == ^id,
            order_by: [desc: m.inserted_at, desc: m.id]

        decisions =
          from d in CorrelationDecision,
            where: d.case_id == ^id,
            order_by: [desc: d.inserted_at, desc: d.id]

        %{
          "case" => summary(c),
          "delivery" => Mondek.CorrelationDelivery.details(id, filters["batch_page"]),
          "members" =>
            paged(members, filters["page"], fn m ->
              r = ref(m)

              %{
                "id" => m.id,
                "episode" => r,
                "anchor" => m.anchor,
                "inserted_at" => Monitoring.iso(m.inserted_at),
                "ended_at" => close_time(m.ended_at),
                "end_reason" => m.end_reason,
                "incident" =>
                  Mondek.Inspection.incident_identity(
                    Monitoring.public(episode!(r)),
                    Mondek.Monitoring.now()
                  )
                  |> Mondek.Investigation.health_summary()
              }
            end),
          "decisions" =>
            paged(
              decisions,
              filters["history_page"],
              &Map.take(&1, [
                :id,
                :action,
                :provenance,
                :actor,
                :reason,
                :confidence,
                :inserted_at,
                :change
              ])
            )
        }
    end
  end

  @doc "Prune closed case histories first; callers hold the topology gate before native locks."
  def prune!(cutoff, limit) do
    sql = """
    DELETE FROM correlation_cases WHERE id IN (
      SELECT c.id FROM correlation_cases c WHERE c.inserted_at < $1
      AND NOT EXISTS (SELECT 1 FROM correlation_decisions d WHERE d.case_id=c.id AND d.inserted_at >= $1)
      AND NOT EXISTS (SELECT 1 FROM correlation_memberships m
        LEFT JOIN incidents i ON i.id=m.incident_id LEFT JOIN condition_incidents g ON g.id=m.condition_incident_id
        WHERE m.case_id=c.id AND (m.inserted_at >= $1 OR m.ended_at >= $1 OR i.status='open' OR g.status='open' OR i.closed_at >= $1 OR g.closed_at >= $1))
      AND NOT EXISTS (SELECT 1 FROM occurrences o JOIN correlation_memberships m ON (o.incident_id=m.incident_id OR o.condition_incident_id=m.condition_incident_id)
        WHERE m.case_id=c.id AND (o.status NOT IN ('delivered','superseded') OR EXISTS (SELECT 1 FROM oban_jobs j WHERE j.args->>'occurrence_id'=o.id::text AND j.state NOT IN ('completed','cancelled','discarded'))))
      AND NOT EXISTS (SELECT 1 FROM correlation_batches b WHERE b.case_id=c.id AND (b.status IN ('pending','delivering') OR b.terminal_status NOT IN ('none','accepted') OR b.inserted_at >= $1 OR b.accepted_at >= $1
        OR EXISTS (SELECT 1 FROM correlation_attempts t WHERE t.batch_id=b.id AND (t.started_at >= $1 OR t.finished_at >= $1))
        OR EXISTS (SELECT 1 FROM oban_jobs j WHERE j.worker='Mondek.CorrelationDeliveryWorker' AND j.args->>'batch_id'=b.id::text AND j.state NOT IN ('completed','cancelled','discarded'))))
      ORDER BY c.inserted_at,c.id LIMIT $2)
    """

    Repo.query!(sql, [cutoff, limit]).num_rows
  end

  def membership(type, id) do
    {type, id} =
      if type == "individual" do
        case Repo.get(Incident, id) do
          %Incident{condition_incident_id: parent} when not is_nil(parent) ->
            {"condition", parent}

          _ ->
            {type, id}
        end
      else
        {type, id}
      end

    query = from m in CorrelationMembership, where: is_nil(m.ended_at)

    query =
      if type == "individual",
        do: from(m in query, where: m.incident_id == ^id),
        else: from(m in query, where: m.condition_incident_id == ^id)

    row = Repo.one(query)

    if row,
      do: %{
        "case_id" => row.case_id,
        "episode" => ref(row),
        "provenance" => row.provenance,
        "notification_effect" => "case_policy"
      }
  end

  defp paged(query, n, mapper) do
    n = number(n)

    %{
      "items" =>
        Repo.all(from x in query, limit: 25, offset: ^((n - 1) * 25)) |> Enum.map(mapper),
      "page" => n,
      "page_size" => 25,
      "total" => Repo.aggregate(query, :count)
    }
  end

  defp number(n) when is_integer(n) and n > 0, do: n

  defp number(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> 1
    end
  end

  defp number(_), do: 1
end

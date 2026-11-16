# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CaseControls do
  @moduledoc "Reviewed case controls and native-owned acknowledgement witnesses."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Monitoring,
    Incident,
    ConditionIncident,
    Correlations,
    CorrelationCase,
    CorrelationMembership,
    CorrelationDecision,
    CorrelationReceipt,
    CorrelationAcknowledgement,
    CorrelationWitness
  }

  @salt "case-control-v1"

  def members(id),
    do:
      Repo.all(
        from m in CorrelationMembership,
          where: m.case_id == ^id and is_nil(m.ended_at),
          order_by: m.id
      )

  def ref(m),
    do: %{
      "type" => if(m.incident_id, do: "individual", else: "condition"),
      "id" => m.incident_id || m.condition_incident_id
    }

  def episode(%{"type" => t, "id" => id}),
    do: Repo.get!(if(t == "individual", do: Incident, else: ConditionIncident), id)

  def severity("CRIT"), do: 2
  def severity("WARN"), do: 1
  def severity(_), do: 0
  def keys(impacts), do: Enum.map(impacts || [], & &1["key"]) |> Enum.sort()
  def change_row(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  def lock_owners!(refs) do
    ids = for r <- Enum.uniq(refs), r["type"] == "individual", do: r["id"]

    Repo.all(from i in Incident, where: i.id in ^ids, select: i.assignment_id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Monitoring.lock_assignment/1)

    Mondek.Conditions.lock_ids!(for r <- refs, r["type"] == "condition", do: r["id"])
  end

  def preview(id, proposal, at \\ Monitoring.now()) do
    transaction(id, fn c, ms ->
      p = validate!(proposal)

      %{
        "case_id" => c.id,
        "proposal" => p,
        "scope" => scope(c, ms, p["action"], at),
        "review_token" =>
          Phoenix.Token.sign(MondekWeb.Endpoint, @salt, {p, c.id, fingerprint(c, ms, at)})
      }
    end)
  end

  defp scope(c, ms, _action, _at) do
    rows =
      Enum.map(ms, fn m ->
        x = episode(ref(m))

        %{
          episode: ref(m),
          label: Map.get(x, :label) || Map.get(x, :result_key),
          health: x.health,
          status: x.status,
          impacts: keys(x.impacts)
        }
      end)

    open = Enum.filter(rows, &(&1.status == "open"))

    %{
      title: c.title,
      members: rows,
      ceiling: if(Enum.any?(open, &(&1.health == "CRIT")), do: "CRIT", else: "WARN"),
      batching_enabled: c.batching_enabled,
      scope: "Current reviewed members only"
    }
  end

  def apply(token, at \\ Monitoring.now()) do
    case Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, {p, id, expected}} ->
        transaction(id, fn c, ms ->
          hash = digest({id, p})

          case Repo.get(CorrelationReceipt, p["request_id"]) do
            %CorrelationReceipt{fingerprint: ^hash, case_id: ^id} ->
              %{"case_id" => id, "replayed" => true}

            nil ->
              if fingerprint(c, ms, at) != expected, do: Repo.rollback(:review_changed)
              apply!(c, ms, p, at)

              Repo.insert!(%CorrelationReceipt{
                id: p["request_id"],
                case_id: id,
                fingerprint: hash,
                inserted_at: at
              })

              %{"case_id" => id, "replayed" => false}

            _ ->
              Repo.rollback(:review_changed)
          end
        end)

      {:error, :expired} ->
        {:error, :review_expired}

      _ ->
        {:error, :invalid_review}
    end
  end

  defp validate!(p) when is_map(p) do
    if Map.keys(p) -- ~w(action request_id note seconds) != [],
      do: Repo.rollback({:invalid, "Unknown fields."})

    if p["action"] not in ~w(enable disable acknowledge end),
      do: Repo.rollback({:invalid, "Unknown action."})

    if not is_binary(p["note"]) or String.trim(p["note"]) == "" or byte_size(p["note"]) > 2000,
      do: Repo.rollback({:invalid, "A note of at most 2000 bytes is required."})

    id =
      case Ecto.UUID.cast(p["request_id"]) do
        {:ok, id} -> id
        _ -> Repo.rollback({:invalid, "Invalid request identity."})
      end

    seconds = p["seconds"]

    if not is_nil(seconds) and
         (p["action"] != "acknowledge" or not is_integer(seconds) or seconds < 1 or
            seconds > 31_536_000),
       do: Repo.rollback({:invalid, "Invalid duration."})

    p |> Map.put("request_id", id) |> Map.update!("note", &String.trim/1)
  end

  defp validate!(_), do: Repo.rollback({:invalid, "Supply a proposal."})
  defp digest(x), do: :crypto.hash(:sha256, :erlang.term_to_binary(x)) |> Base.encode16()

  defp fingerprint(c, ms, at),
    do:
      digest(
        {c,
         Enum.map(ms, fn m ->
           x = episode(ref(m))
           {m.id, x.status, x.health, keys(x.impacts), x.attention_revision}
         end), data(c.id, at)}
      )

  def transaction(id, fun) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        Correlations.lock!()
        _c = Repo.get(CorrelationCase, id) || Repo.rollback(:not_found)
        ms = members(id)
        lock_owners!(Enum.map(ms, &ref/1))
        c = Repo.one!(from c in CorrelationCase, where: c.id == ^id, lock: "FOR UPDATE")
        fun.(c, ms)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp apply!(c, ms, p, at) do
    reconcile!(c.id, at)

    if p["action"] in ~w(enable acknowledge) and
         not Enum.any?(ms, &(episode(ref(&1)).status == "open")),
       do: Repo.rollback(:case_closed)

    if p["action"] in ~w(acknowledge end), do: end!(c.id, "Operator changed control", at)

    case p["action"] do
      action when action in ~w(enable disable) ->
        change_row(c, %{batching_enabled: action == "enable", revision: c.revision + 1})

        if action == "disable", do: Mondek.CorrelationDelivery.release_case!(c.id)

      "acknowledge" ->
        ms = Enum.filter(ms, &(episode(ref(&1)).status == "open"))
        ceiling = if Enum.any?(ms, &(episode(ref(&1)).health == "CRIT")), do: "CRIT", else: "WARN"

        revision =
          Repo.aggregate(from(a in CorrelationAcknowledgement, where: a.case_id == ^c.id), :count) +
            1

        ack =
          Repo.insert!(%CorrelationAcknowledgement{
            case_id: c.id,
            revision: revision,
            topology_revision: c.topology_revision,
            mode: if(p["seconds"], do: "duration", else: "until_case_ends"),
            until: if(p["seconds"], do: DateTime.add(at, p["seconds"], :second)),
            ceiling: ceiling,
            note: p["note"],
            actor: "Local operator",
            inserted_at: at
          })

        Enum.each(ms, fn m ->
          i = episode(ref(m))

          Repo.insert!(%CorrelationWitness{
            ack_id: ack.id,
            incident_id: m.incident_id,
            condition_incident_id: m.condition_incident_id,
            ceiling: ceiling,
            impacts: keys(i.impacts)
          })
        end)

      "end" ->
        :ok
    end

    audit!(c.id, p["action"], p["note"], at)
    wake!(c.id)
  end

  defp audit!(id, action, note, at),
    do:
      Repo.insert!(%CorrelationDecision{
        case_id: id,
        action: action,
        provenance: "operator",
        actor: "Local operator",
        reason: note,
        inserted_at: at,
        change: %{"case_control" => action}
      })

  def latest(id),
    do:
      Repo.one(
        from a in CorrelationAcknowledgement,
          where: a.case_id == ^id,
          order_by: [desc: a.revision],
          limit: 1
      )

  def active?(nil, _, _), do: false

  def active?(a, c, at) do
    is_nil(a.ended_at) and a.topology_revision == c.topology_revision and
      (is_nil(a.until) or DateTime.compare(a.until, at) == :gt) and
      Enum.any?(members(c.id), &(episode(ref(&1)).status == "open")) and
      not Repo.exists?(
        from w in CorrelationWitness, where: w.ack_id == ^a.id and not is_nil(w.invalidated_at)
      )
  end

  def data(id, at) do
    c = Repo.get!(CorrelationCase, id)
    a = latest(id)

    if a,
      do:
        Map.take(a, [
          :id,
          :revision,
          :mode,
          :until,
          :ceiling,
          :note,
          :ended_at,
          :end_reason,
          :inserted_at
        ])
        |> Map.put(:active, active?(a, c, at)),
      else: %{active: false, revision: 0}
  end

  def end!(id, reason, at) do
    rows =
      Repo.all(
        from a in CorrelationAcknowledgement, where: a.case_id == ^id and is_nil(a.ended_at)
      )

    Enum.each(rows, &change_row(&1, %{ended_at: at, end_reason: reason}))
    if rows != [], do: wake!(id)
  end

  def reconcile!(id, at) do
    c = Repo.get!(CorrelationCase, id)
    a = latest(id)

    if a && is_nil(a.ended_at) && not active?(a, c, at),
      do: end!(id, "Scope invalidated or expired", at)
  end

  def native_changed!(%module{} = old, new) when module in [Incident, ConditionIncident] do
    grouped_contribution? = module == Incident and not is_nil(old.condition_incident_id)

    if not grouped_contribution? and
         (old.status != new.status or old.health != new.health or
            keys(old.impacts) != keys(new.impacts)) do
      query =
        from w in CorrelationWitness,
          join: a in CorrelationAcknowledgement,
          on: a.id == w.ack_id,
          where: is_nil(w.invalidated_at) and is_nil(a.ended_at)

      query =
        if module == Incident,
          do: from(w in query, where: w.incident_id == ^old.id),
          else: from(w in query, where: w.condition_incident_id == ^old.id)

      Enum.each(Repo.all(query), fn w ->
        if new.status == "closed",
          do:
            Mondek.CorrelationDelivery.enqueue!(%{
              "case_id" => Repo.get!(CorrelationAcknowledgement, w.ack_id).case_id
            })

        if severity(new.health) > severity(w.ceiling) or
             Enum.any?(keys(new.impacts), &(&1 not in w.impacts)) do
          change_row(w, %{invalidated_at: Monitoring.now(), reason: "Member ended or escalated"})
          ack = Repo.get!(CorrelationAcknowledgement, w.ack_id)
          Mondek.CorrelationDelivery.enqueue!(%{"case_id" => ack.case_id})
        end
      end)
    end

    :ok
  end

  def native_changed!(_, _), do: :ok

  def wake!(id) do
    ms = members(id)
    ids = for m <- ms, m.incident_id, do: m.incident_id
    groups = for m <- ms, m.condition_incident_id, do: m.condition_incident_id

    Repo.update_all(
      from(o in Mondek.Occurrence,
        where: o.incident_id in ^ids or o.condition_incident_id in ^groups
      ),
      inc: [gate_revision: 1]
    )
  end
end

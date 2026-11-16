# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationAcknowledgement do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_acknowledgements" do
    field :case_id, Ecto.UUID
    field :revision, :integer
    field :topology_revision, :integer
    field :mode, :string
    field :until, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :end_reason, :string
    field :ceiling, :string
    field :note, :string
    field :actor, :string
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Mondek.CorrelationWitness do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_witnesses" do
    field :ack_id, Ecto.UUID
    field :incident_id, Ecto.UUID
    field :condition_incident_id, Ecto.UUID
    field :ceiling, :string
    field :impacts, {:array, :string}, default: []
    field :invalidated_at, :utc_datetime_usec
    field :reason, :string
  end
end

defmodule Mondek.CorrelationBatch do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_batches" do
    field :case_id, Ecto.UUID
    field :topology_revision, :integer
    field :status, :string
    field :payload, :map
    field :destination, :string
    field :transport, :map
    field :limit, :integer
    field :attempts, :integer, default: 0
    field :deadline, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :terminal_id, Ecto.UUID
    field :terminal_payload, :map
    field :terminal_attempts, :integer, default: 0
    field :terminal_status, :string, default: "none"
  end
end

defmodule Mondek.CorrelationReservation do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_reservations" do
    field :batch_id, Ecto.UUID
    field :occurrence_id, Ecto.UUID
    field :epoch, :integer
    field :membership_id, Ecto.UUID
    field :status, :string
  end
end

defmodule Mondek.CorrelationAttempt do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_attempts" do
    field :batch_id, Ecto.UUID
    field :kind, :string
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string
  end
end

defmodule Mondek.CorrelationCredit do
  use Ecto.Schema
  @primary_key {:occurrence_id, :binary_id, autogenerate: false}
  schema "correlation_credits" do
    field :epoch, :integer
    field :limit, :integer
    field :spent, :integer, default: 0
    field :handover_until, :utc_datetime_usec
  end
end

defmodule Mondek.CorrelationDelivery do
  @moduledoc "Immutable exact batches with one aggregate attempt and native fallback."
  import Ecto.Query
  alias Mondek.{Repo, Monitoring, Conditions, Occurrence, Attempt, CaseControls}

  alias Mondek.{
    CorrelationCase,
    CorrelationBatch,
    CorrelationReservation,
    CorrelationCredit,
    CorrelationAttempt
  }

  def enqueue!(args) do
    args |> Mondek.CorrelationDeliveryWorker.new(max_attempts: 100) |> Oban.insert!()
  end

  def epoch!(id, limit) do
    old = Repo.get(CorrelationCredit, id)

    attrs = %{
      epoch: if(old, do: old.epoch + 1, else: 1),
      limit: limit,
      spent: 0,
      handover_until: nil
    }

    if old,
      do: CaseControls.change_row(old, attrs),
      else: Repo.insert!(struct(CorrelationCredit, Map.put(attrs, :occurrence_id, id)))
  end

  defp ref(o),
    do:
      if(o.incident_id,
        do: %{"type" => "individual", "id" => o.incident_id},
        else:
          if(o.condition_incident_id,
            do: %{"type" => "condition", "id" => o.condition_incident_id}
          )
      )

  defp association(o) do
    r = ref(o)
    r && Mondek.Correlations.membership(r["type"], r["id"])
  end

  def lock_native!(o) do
    Mondek.Correlations.lock!(:shared)
    a = association(o)
    refs = if a, do: Enum.map(CaseControls.members(a["case_id"]), &CaseControls.ref/1), else: []
    CaseControls.lock_owners!(refs ++ List.wrap(ref(o)))

    if a,
      do: Repo.one!(from c in CorrelationCase, where: c.id == ^a["case_id"], lock: "FOR UPDATE")

    a && a["case_id"]
  end

  defp native_eligibility(o, at),
    do: Monitoring.delivery_context_eligibility(o, Monitoring.lock_delivery_context!(o, at), at)

  defp rows(id) do
    ms = CaseControls.members(id)
    ids = for m <- ms, m.incident_id, do: m.incident_id
    groups = for m <- ms, m.condition_incident_id, do: m.condition_incident_id

    Repo.all(
      from o in Occurrence,
        join: cr in CorrelationCredit,
        on: cr.occurrence_id == o.id,
        where:
          (o.incident_id in ^ids or o.condition_incident_id in ^groups) and o.status == "pending" and
            o.kind != "resolved" and cr.limit - cr.spent >= 2 and is_nil(cr.handover_until),
        where: fragment("NOT EXISTS (SELECT 1 FROM attempts t WHERE t.occurrence_id=?)", o.id),
        order_by: o.id,
        limit: 100
    )
  end

  def gate!(o, id, at) do
    coverage =
      Repo.one(
        from r in CorrelationReservation,
          where: r.occurrence_id == ^o.id and r.status == "accepted",
          limit: 1
      )

    reserved =
      Repo.one(
        from r in CorrelationReservation,
          where: r.occurrence_id == ^o.id and r.status == "reserved"
      )

    cond do
      coverage ->
        :delivered

      reserved ->
        batch = Repo.get!(CorrelationBatch, reserved.batch_id)

        if batch.status == "delivering",
          do:
            (
              recover_attempt!(batch, at)

              if Repo.get!(CorrelationBatch, batch.id).status == "released",
                do: gate!(o, id, at),
                else: held(at)
            ),
          else:
            if(batch.status == "pending" and DateTime.compare(at, batch.deadline) == :lt,
              do: held(at),
              else:
                (
                  release!(batch)
                  gate!(o, id, at)
                )
            )

      is_nil(id) ->
        :eligible

      true ->
        CaseControls.reconcile!(id, at)

        if o.kind != "resolved" and CaseControls.data(id, at).active,
          do: {:gated, ["case_acknowledgement"], CaseControls.latest(id).until},
          else: maybe_batch!(o, id, at)
    end
  end

  defp held(at), do: {:gated, ["exact_batch_delivery"], DateTime.add(at, 1, :second)}

  def spend_native!(id) do
    case Repo.get(CorrelationCredit, id) do
      nil ->
        :ok

      c when c.spent < c.limit ->
        CaseControls.change_row(c, %{spent: c.spent + 1})
        :ok

      _ ->
        :exhausted
    end
  end

  defp maybe_batch!(o, id, at) do
    c = Repo.get!(CorrelationCase, id)

    if c.batching_enabled and o.kind != "resolved" and native_eligibility(o, at) == :eligible do
      eligible =
        rows(id)
        |> Enum.filter(fn x ->
          credit = Repo.get(CorrelationCredit, x.id)

          x.kind != "resolved" and x.status == "pending" and not is_nil(credit) and
            credit.limit - credit.spent >= 2 and
            is_nil(credit.handover_until) and transport_key(x) == transport_key(o) and
            not Repo.exists?(from t in Attempt, where: t.occurrence_id == ^x.id) and
            compatible?(x) and
            native_eligibility(x, at) == :eligible
        end)
        |> Enum.take(100)

      if length(eligible) >= 2 and Enum.any?(eligible, &(&1.id == o.id)) do
        if freeze!(c, eligible, at), do: held(at), else: :eligible
      else
        :eligible
      end
    else
      :eligible
    end
  end

  defp compatible?(o) do
    d = o.payload["webhook_delivery"]

    not String.starts_with?(o.destination, "webhook:") or
      (is_map(d) and Map.has_key?(d, "template") and Map.has_key?(d, "public_url"))
  end

  defp transport_key(o),
    do:
      {o.destination, o.payload["email"] && Map.take(o.payload["email"], ~w(from public_url)),
       o.payload["webhook_delivery"] &&
         Map.take(
           o.payload["webhook_delivery"],
           ~w(destination_id destination_hash template public_url)
         )}

  defp requested_health(o) do
    case o.payload["requested_fact"] do
      %{"kind" => "severity", "key" => key} -> key
      %{} -> nil
      _ -> o.payload["health"]
    end
  end

  defp excerpt(o),
    do:
      Map.take(
        o.payload,
        ~w(occurrence_id incident_id condition_incident_id requested_fact attention_revision observation_id source_at created_at health group_health_at_creation impacts result_key)
      )

  defp freeze!(c, originals, at) do
    id = Ecto.UUID.generate()

    payload = %{
      "occurrence_id" => id,
      "incident_type" => "correlation",
      "correlation_case_id" => c.id,
      "kind" => "firing",
      "created_at" => Monitoring.iso(at),
      "health" =>
        originals
        |> Enum.map(&requested_health/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&CaseControls.severity/1, fn -> nil end),
      "environment" => c.environment,
      "member_count" => length(originals),
      "members" => Enum.map(originals, &excerpt/1),
      "scope" => "Only these exact notification facts"
    }

    case safe_snapshot(payload, c.title, hd(originals)) do
      nil ->
        nil

      {payload, transport} ->
        b =
          Repo.insert!(%CorrelationBatch{
            id: id,
            case_id: c.id,
            topology_revision: c.revision,
            status: "pending",
            payload: payload,
            destination: hd(originals).destination,
            transport: transport,
            limit: 1,
            deadline: DateTime.add(at, 30, :second),
            inserted_at: at,
            terminal_id: Ecto.UUID.generate()
          })

        ms = CaseControls.members(c.id)

        Enum.each(originals, fn o ->
          credit = Repo.get!(CorrelationCredit, o.id)
          CaseControls.change_row(credit, %{handover_until: b.deadline})

          Repo.insert!(%CorrelationReservation{
            batch_id: id,
            occurrence_id: o.id,
            epoch: credit.epoch,
            membership_id: Enum.find(ms, &(CaseControls.ref(&1) == ref(o))).id,
            status: "reserved"
          })
        end)

        enqueue!(%{"batch_id" => id})
        b
    end
  end

  defp safe_snapshot(payload, title, o) do
    p = Mondek.CorrelationTransport.freeze!(payload, title, o)
    if byte_size(Jason.encode!(elem(p, 0))) <= 262_144, do: p
  rescue
    _ -> nil
  end

  def reservations(id),
    do:
      Repo.all(
        from r in CorrelationReservation, where: r.batch_id == ^id, order_by: r.occurrence_id
      )

  def release_case!(id) do
    Repo.all(from b in CorrelationBatch, where: b.case_id == ^id and b.status == "pending")
    |> Enum.each(&release!/1)
  end

  defp release!(b) do
    Repo.update_all(
      from(r in CorrelationReservation, where: r.batch_id == ^b.id and r.status == "reserved"),
      set: [status: "released"]
    )

    CaseControls.change_row(b, %{status: "released"})
  end

  def begin_attempt(id, at \\ nil) do
    Repo.transaction(fn ->
      Mondek.Maintenance.lock!(:shared)
      Mondek.Correlations.lock!(:shared)
      b = Repo.get(CorrelationBatch, id) || Repo.rollback(:not_found)
      rs = reservations(id)
      refs = Enum.map(rs, fn r -> ref(Repo.get!(Occurrence, r.occurrence_id)) end)

      CaseControls.lock_owners!(
        refs ++ Enum.map(CaseControls.members(b.case_id), &CaseControls.ref/1)
      )

      c = Repo.one!(from c in CorrelationCase, where: c.id == ^b.case_id, lock: "FOR UPDATE")
      b = Repo.one!(from b in CorrelationBatch, where: b.id == ^id, lock: "FOR UPDATE")

      os =
        Repo.all(
          from o in Occurrence,
            where: o.id in ^Enum.map(rs, & &1.occurrence_id),
            order_by: o.id,
            lock: "FOR UPDATE"
        )

      at = at || Monitoring.now()
      CaseControls.reconcile!(c.id, at)

      cond do
        b.status == "delivering" ->
          recover_attempt!(b, at)

        b.status == "pending" ->
          valid =
            DateTime.compare(at, b.deadline) == :lt and c.revision == b.topology_revision and
              c.batching_enabled and not CaseControls.data(c.id, at).active and
              Enum.all?(os, &(native_eligibility(&1, at) == :eligible)) and
              Enum.all?(rs, fn r ->
                cr = Repo.get!(CorrelationCredit, r.occurrence_id)
                r.status == "reserved" and r.epoch == cr.epoch and cr.spent < cr.limit - 1
              end)

          if valid do
            Enum.each(rs, fn r ->
              cr = Repo.get!(CorrelationCredit, r.occurrence_id)
              CaseControls.change_row(cr, %{spent: cr.spent + 1})
            end)

            attempt =
              Repo.insert!(%CorrelationAttempt{
                batch_id: b.id,
                kind: "failure",
                status: "started",
                started_at: at
              })

            CaseControls.change_row(b, %{
              status: "delivering",
              attempts: b.attempts + 1,
              terminal_status: "waiting"
            })

            {:send, b, attempt, b.payload}
          else
            release!(b)
            :wait
          end

        b.terminal_status == "delivering" ->
          recover_attempt!(b, at)

        b.terminal_status in ["waiting", "pending"] ->
          terminal!(b, refs, at)

        true ->
          :done
      end
    end)
  end

  defp recover_attempt!(b, at) do
    latest =
      Repo.one(
        from t in CorrelationAttempt,
          where: t.batch_id == ^b.id and t.status == "started",
          order_by: [desc: t.started_at],
          limit: 1
      )

    if latest && DateTime.diff(at, latest.started_at, :second) < 60 do
      :wait
    else
      if latest,
        do:
          CaseControls.change_row(latest, %{
            status: "ambiguous",
            finished_at: at,
            error: "Abandoned admission"
          })

      if b.status == "delivering",
        do: release!(b),
        else:
          CaseControls.change_row(b, %{
            terminal_status: if(b.terminal_attempts >= 3, do: "exhausted", else: "pending")
          })

      :wait
    end
  end

  defp terminal!(b, refs, at) do
    episodes = Enum.map(refs, &CaseControls.episode/1)

    if Enum.all?(episodes, &(&1.status == "closed")) do
      if b.terminal_attempts >= 3 do
        CaseControls.change_row(b, %{terminal_status: "exhausted"})
        :done
      else
        payload =
          b.terminal_payload ||
            %{
              "occurrence_id" => b.terminal_id,
              "incident_type" => "correlation",
              "correlation_case_id" => b.case_id,
              "kind" => "resolved",
              "created_at" => Monitoring.iso(at),
              "scope" => "All episodes in this notification batch ended",
              "failure_batch_id" => b.id,
              "closure_reason" => "batch_episodes_ended",
              "members" =>
                Enum.zip(refs, episodes)
                |> Enum.map(fn {r, x} ->
                  Map.merge(r, %{
                    "closed_at" => Monitoring.iso(x.closed_at),
                    "closure_reason" => x.closure_reason
                  })
                end)
            }

        {payload, _} =
          if b.terminal_payload,
            do: {payload, nil},
            else: Mondek.CorrelationTransport.terminal!(payload, b.transport)

        attempt =
          Repo.insert!(%CorrelationAttempt{
            batch_id: b.id,
            kind: "terminal",
            status: "started",
            started_at: at
          })

        CaseControls.change_row(b, %{
          terminal_payload: payload,
          terminal_status: "delivering",
          terminal_attempts: b.terminal_attempts + 1
        })

        {:send, b, attempt, payload}
      end
    else
      :wait
    end
  rescue
    _ ->
      CaseControls.change_row(b, %{terminal_status: "exhausted"})
      :done
  end

  def finish(id, attempt_id, result, at \\ Monitoring.now()) do
    success =
      match?({:ok, :smtp}, result) or
        match?({:ok, {{_, code, _}, _, _}} when code in 200..299, result)

    Repo.transaction(fn ->
      Mondek.Correlations.lock!(:shared)
      _b = Repo.get!(CorrelationBatch, id)
      rs = reservations(id)
      CaseControls.lock_owners!(Enum.map(rs, &ref(Repo.get!(Occurrence, &1.occurrence_id))))
      b = Repo.one!(from b in CorrelationBatch, where: b.id == ^id, lock: "FOR UPDATE")
      a = Repo.get!(CorrelationAttempt, attempt_id)

      if a.status == "started" or (success and a.status != "accepted") do
        CaseControls.change_row(a, %{
          status: if(success, do: "accepted", else: "failed_or_ambiguous"),
          finished_at: at,
          error: if(success, do: nil, else: "Receiver failed or reply ambiguous")
        })

        if a.kind == "failure" do
          if success do
            for r <- rs do
              CaseControls.change_row(r, %{status: "accepted"})
              o = Repo.get!(Occurrence, r.occurrence_id)
              if o.condition_incident_id, do: Conditions.delivery_accepted!(o, at)

              if o.status not in ["delivered", "superseded"],
                do: CaseControls.change_row(o, %{status: "superseded"})
            end

            CaseControls.change_row(b, %{status: "accepted", accepted_at: at})
          else
            if b.status != "accepted", do: release!(b)
          end
        else
          if b.terminal_status != "accepted",
            do:
              CaseControls.change_row(b, %{
                terminal_status:
                  if(success,
                    do: "accepted",
                    else: if(b.terminal_attempts >= 3, do: "exhausted", else: "pending")
                  )
              })
        end
      end
    end)
  end

  def reconcile(id) do
    CaseControls.transaction(id, fn _, _ ->
      CaseControls.reconcile!(id, Monitoring.now())
      :ok
    end)
  end

  def inspect_gate(o, at) do
    r =
      Repo.one(
        from r in CorrelationReservation,
          where: r.occurrence_id == ^o.id and r.status in ["reserved", "accepted"],
          limit: 1
      )

    cond do
      r && r.status == "accepted" ->
        :delivered

      r ->
        held(at)

      true ->
        a = association(o)

        if a && o.kind != "resolved" && CaseControls.data(a["case_id"], at).active,
          do: {:gated, ["case_acknowledgement"], CaseControls.latest(a["case_id"]).until},
          else: :eligible
    end
  end

  def repair! do
    candidates =
      Repo.all(
        from b in CorrelationBatch,
          where:
            b.status in ["pending", "delivering"] or
              b.terminal_status in ["pending", "waiting", "delivering"],
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM oban_jobs j WHERE j.worker='Mondek.CorrelationDeliveryWorker' AND j.args->>'batch_id'=? AND j.state IN ('available','executing','scheduled','retryable'))",
              type(b.id, :string)
            ),
          order_by: b.inserted_at,
          limit: 25
      )

    Enum.each(candidates, fn b ->
      active =
        Repo.exists?(
          from j in Oban.Job,
            where:
              j.worker == "Mondek.CorrelationDeliveryWorker" and
                j.state in ["available", "executing", "scheduled", "retryable"] and
                fragment("?->>'batch_id'", j.args) == ^b.id
        )

      if not active, do: enqueue!(%{"batch_id" => b.id})
    end)
  end

  def details(id, page \\ 1) do
    page =
      case page do
        n when is_integer(n) and n > 0 ->
          n

        n when is_binary(n) ->
          case Integer.parse(n) do
            {v, ""} when v > 0 -> v
            _ -> 1
          end

        _ ->
          1
      end

    batches =
      Repo.all(
        from b in CorrelationBatch,
          where: b.case_id == ^id,
          order_by: [
            asc:
              fragment(
                "CASE WHEN ? IN ('pending','delivering') OR ? IN ('waiting','pending','delivering','exhausted') THEN 0 ELSE 1 END",
                b.status,
                b.terminal_status
              ),
            desc: b.inserted_at
          ],
          offset: ^((page - 1) * 25),
          limit: 25
      )

    %{
      acknowledgement: CaseControls.data(id, Monitoring.now()),
      batching_enabled: Repo.get!(CorrelationCase, id).batching_enabled,
      batch_page: %{
        page: page,
        page_size: 25,
        total: Repo.aggregate(from(b in CorrelationBatch, where: b.case_id == ^id), :count)
      },
      batches:
        Enum.map(batches, fn b ->
          Map.take(b, [
            :id,
            :status,
            :attempts,
            :accepted_at,
            :deadline,
            :inserted_at,
            :terminal_id,
            :terminal_status,
            :terminal_attempts
          ])
          |> Map.put(
            :members,
            Enum.map(reservations(b.id), &Map.take(&1, [:occurrence_id, :status]))
          )
        end)
    }
  end
end

defmodule Mondek.CorrelationDeliveryWorker do
  use Oban.Worker, queue: :notifications, max_attempts: 100

  def perform(%Oban.Job{args: %{"case_id" => id}}) do
    Mondek.CorrelationDelivery.reconcile(id)
    :ok
  end

  def perform(%Oban.Job{args: %{"batch_id" => id}}) do
    case Mondek.CorrelationDelivery.begin_attempt(id) do
      {:ok, {:send, b, a, payload}} ->
        result =
          Mondek.NotificationDelivery.deliver(%{
            id: payload["occurrence_id"],
            payload: payload,
            destination: b.destination,
            inserted_at: b.inserted_at
          })

        Mondek.CorrelationDelivery.finish(id, a.id, result)
        {:snooze, 2}

      {:ok, :wait} ->
        {:snooze, 2}

      {:ok, :done} ->
        :ok

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end

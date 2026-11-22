# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationRelationship do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_relationships" do
    field :sequence, :integer, read_after_writes: true
    field :subject_incident_id, Ecto.UUID
    field :subject_condition_id, Ecto.UUID
    field :target_incident_id, Ecto.UUID
    field :target_condition_id, Ecto.UUID
    field :dimension, :string
    field :matches, {:array, :map}
    field :actor, :string
    field :reason, :string
    field :inserted_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :removed_by, :string
    field :removal_reason, :string
  end
end

defmodule Mondek.CorrelationRelationshipReceipt do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "correlation_relationship_receipts" do
    field :relationship_id, Ecto.UUID
    field :fingerprint, :string
  end
end

defmodule Mondek.CorrelationRelationships do
  @moduledoc "Operator-reviewed directional hypotheses between exact health episodes."
  import Ecto.Query

  alias Mondek.{
    CorrelationCandidates,
    CorrelationRelationship,
    CorrelationRelationshipReceipt,
    ConditionIncident,
    Incident,
    Monitoring,
    Repo,
    Correlations
  }

  @salt "secondary-relationship-review-v1"
  @page_size 20
  @limit 16
  @actor "Local operator"

  def preview(proposal, at \\ Monitoring.now()) do
    transaction(fn ->
      p = validate!(proposal)
      {matches, history, relationship} = review!(p)
      token = Phoenix.Token.sign(MondekWeb.Endpoint, @salt, {p, fingerprint({matches, history})})

      %{
        "proposal" => p,
        "review_token" => token,
        "as_of" => Monitoring.iso(at),
        "matches" => matches,
        "relationship" => relationship,
        "notification_effect" => "none"
      }
    end)
  end

  def apply(token, at \\ Monitoring.now())

  def apply(token, at) when is_binary(token) do
    case Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, {p, expected}} ->
        transaction(fn ->
          hash = fingerprint(p)

          case Repo.get(CorrelationRelationshipReceipt, p["request_id"]) do
            %{fingerprint: ^hash, relationship_id: id} ->
              %{"relationship_id" => id, "replayed" => true}

            nil ->
              {matches, history, _relationship} = review!(p, :apply)
              if fingerprint({matches, history}) != expected, do: Repo.rollback(:review_changed)
              row = execute!(p, matches, at)

              Repo.insert!(%CorrelationRelationshipReceipt{
                id: p["request_id"],
                relationship_id: row.id,
                fingerprint: hash
              })

              %{"relationship_id" => row.id, "replayed" => false}

            _ ->
              Repo.rollback(:review_changed)
          end
        end)
        |> tap(fn
          {:ok, %{"replayed" => false}} -> Monitoring.notify()
          _ -> :ok
        end)

      {:error, :expired} ->
        {:error, :review_expired}

      _ ->
        {:error, :invalid_review}
    end
  end

  def apply(_, _), do: {:error, :invalid_review}

  defp transaction(fun),
    do:
      Repo.transaction(fn ->
        Correlations.lock!()
        fun.()
      end)

  defp fingerprint(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16()

  defp validate!(
         %{"action" => action, "request_id" => request, "subject" => subject, "reason" => reason} =
           p
       )
       when action in ["add", "remove"] do
    unless is_binary(reason) and String.valid?(reason) and byte_size(reason) <= 2000 and
             String.trim(reason) != "" and not String.contains?(reason, <<0>>),
           do: invalid!("Provide a reason of at most 2000 bytes.")

    p = %{p | "request_id" => uuid!(request), "subject" => ref!(subject)}

    case action do
      "add" ->
        unless map_size(p) == 6 and Mondek.Protocol.stable_key?(p["dimension"]),
          do: invalid!("Choose a valid relationship dimension.")

        target = ref!(p["target"])
        if target == p["subject"], do: invalid!("Choose distinct episodes.")
        %{p | "target" => target}

      "remove" ->
        unless map_size(p) == 5 and Map.has_key?(p, "relationship_id"),
          do: invalid!("Choose a relationship.")

        %{p | "relationship_id" => uuid!(p["relationship_id"])}
    end
  end

  defp validate!(_), do: invalid!("Supply a relationship proposal.")

  defp ref!(%{"type" => t, "id" => id} = r)
       when t in ["individual", "condition"] and map_size(r) == 2, do: %{r | "id" => uuid!(id)}

  defp ref!(_), do: invalid!("Choose a typed health episode.")

  defp uuid!(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      _ -> invalid!("Invalid identity.")
    end
  end

  defp invalid!(message), do: Repo.rollback({:invalid, message})
  defp reject!(:apply, _), do: Repo.rollback(:review_changed)
  defp reject!(:preview, message), do: invalid!(message)

  defp schema("individual"), do: Incident
  defp schema("condition"), do: ConditionIncident
  defp endpoint_field(:subject, "individual"), do: :subject_incident_id
  defp endpoint_field(:subject, "condition"), do: :subject_condition_id
  defp endpoint_field(:target, "individual"), do: :target_incident_id
  defp endpoint_field(:target, "condition"), do: :target_condition_id

  defp ref(row, side) do
    if id = Map.fetch!(row, endpoint_field(side, "individual")) do
      %{"type" => "individual", "id" => id}
    else
      %{"type" => "condition", "id" => Map.fetch!(row, endpoint_field(side, "condition"))}
    end
  end

  defp related(%{"type" => t, "id" => id}) do
    from r in CorrelationRelationship,
      where:
        field(r, ^endpoint_field(:subject, t)) == ^id or
          field(r, ^endpoint_field(:target, t)) == ^id
  end

  defp with_endpoints(query) do
    from r in query,
      left_join: si in Incident,
      on: si.id == r.subject_incident_id,
      left_join: sc in ConditionIncident,
      on: sc.id == r.subject_condition_id,
      left_join: ti in Incident,
      on: ti.id == r.target_incident_id,
      left_join: tc in ConditionIncident,
      on: tc.id == r.target_condition_id
  end

  defp active_count(ref) do
    Repo.aggregate(
      from([r, si, sc, ti, tc] in with_endpoints(related(ref)),
        where:
          is_nil(r.removed_at) and (si.status == "open" or sc.status == "open") and
            (ti.status == "open" or tc.status == "open")
      ),
      :count
    )
  end

  defp lock_open!(refs, mode) do
    ids = for %{"type" => "individual", "id" => id} <- refs, do: id

    Repo.all(
      from i in Incident,
        where: i.id in ^ids,
        distinct: true,
        order_by: i.assignment_id,
        select: i.assignment_id
    )
    |> Enum.each(&Monitoring.lock_assignment/1)

    Mondek.Conditions.lock_ids!(for %{"type" => "condition", "id" => id} <- refs, do: id)

    Enum.each(refs, fn %{"type" => t, "id" => id} ->
      row = Repo.get(schema(t), id)

      unless match?(%{status: "open"}, row) and is_nil(Map.get(row, :condition_incident_id)),
        do: reject!(mode, "Choose open, canonical episodes.")
    end)
  end

  defp review!(p, mode \\ :preview)

  defp review!(%{"action" => "add", "subject" => s, "target" => t, "dimension" => d}, mode) do
    lock_open!([s, t], mode)

    candidate =
      CorrelationCandidates.for_episode(s["type"], s["id"])["candidates"]
      |> Enum.find(&(Map.take(&1, ["id", "type"]) == t))

    matches = Enum.filter((candidate || %{})["matches"] || [], &(&1["dimension"] == d))
    if matches == [], do: reject!(mode, "Choose a current candidate and matched dimension.")

    same =
      from r in CorrelationRelationship,
        where:
          field(r, ^endpoint_field(:subject, s["type"])) == ^s["id"] and
            field(r, ^endpoint_field(:target, t["type"])) == ^t["id"] and r.dimension == ^d

    if Repo.exists?(from r in same, where: is_nil(r.removed_at)),
      do: reject!(mode, "This relationship already exists.")

    if active_count(s) >= @limit or active_count(t) >= @limit,
      do: reject!(mode, "An episode already has 16 active relationships.")

    latest = Repo.one(from r in same, order_by: [desc: r.sequence], limit: 1, select: r.id)
    {matches, latest, nil}
  end

  defp review!(%{"action" => "remove", "subject" => s, "relationship_id" => id}, mode) do
    row = Repo.one(from r in related(s), where: r.id == ^id and is_nil(r.removed_at))
    unless row, do: reject!(mode, "Choose an active relationship of this episode.")
    lock_open!([ref(row, :subject), ref(row, :target)], mode)
    {row.matches, row.id, item({row, "open", "open"})}
  end

  defp execute!(%{"action" => "add", "subject" => s, "target" => t} = p, matches, at) do
    struct!(CorrelationRelationship, %{
      endpoint_field(:subject, s["type"]) => s["id"],
      endpoint_field(:target, t["type"]) => t["id"],
      dimension: p["dimension"],
      actor: @actor,
      reason: p["reason"],
      inserted_at: at,
      matches: matches
    })
    |> Repo.insert!()
  end

  defp execute!(p, _, at) do
    row = Repo.get!(CorrelationRelationship, p["relationship_id"])
    removed_at = if DateTime.before?(at, row.inserted_at), do: row.inserted_at, else: at

    Ecto.Changeset.change(row,
      removed_at: removed_at,
      removed_by: @actor,
      removal_reason: p["reason"]
    )
    |> Repo.update!()
  end

  def list(type, id, page \\ 1)

  def list(type, id, page)
      when type in ["individual", "condition"] and is_integer(page) and page > 0 do
    with {:ok, id} <- Ecto.UUID.cast(id), %{} = episode <- Repo.get(schema(type), id) do
      subject =
        case episode do
          %Incident{condition_incident_id: group} when not is_nil(group) ->
            %{"type" => "condition", "id" => group}

          _ ->
            %{"type" => type, "id" => id}
        end

      query = related(subject)
      total = Repo.aggregate(query, :count)

      rows =
        if (page - 1) * @page_size >= total,
          do: [],
          else:
            Repo.all(
              from [r, si, sc, ti, tc] in with_endpoints(query),
                select: {r, coalesce(si.status, sc.status), coalesce(ti.status, tc.status)},
                order_by: [desc: r.inserted_at, desc: r.id],
                limit: @page_size,
                offset: ^((page - 1) * @page_size)
            )

      %{
        "subject" => subject,
        "items" => Enum.map(rows, &item/1),
        "page" => page,
        "page_size" => @page_size,
        "total" => total
      }
    else
      _ -> nil
    end
  end

  def list(_, _, _), do: nil

  @doc "Prune ended hypotheses in bounded batches under the shared correlation gate."
  def prune!(cutoff, limit) do
    sql = """
    DELETE FROM correlation_relationships WHERE id IN (
      SELECT r.id FROM correlation_relationships r
      LEFT JOIN incidents si ON si.id = r.subject_incident_id
      LEFT JOIN incidents ti ON ti.id = r.target_incident_id
      LEFT JOIN condition_incidents sc ON sc.id = r.subject_condition_id
      LEFT JOIN condition_incidents tc ON tc.id = r.target_condition_id
      WHERE r.inserted_at < $1
        AND COALESCE(r.removed_at, LEAST(si.closed_at, ti.closed_at, sc.closed_at, tc.closed_at)) < $1
      ORDER BY r.inserted_at, r.id LIMIT $2)
    """

    Repo.query!(sql, [cutoff, limit]).num_rows
  end

  defp item({row, subject_status, target_status}) do
    s = Map.put(ref(row, :subject), "status", subject_status)
    t = Map.put(ref(row, :target), "status", target_status)

    status =
      cond do
        row.removed_at -> "removed"
        s["status"] != "open" or t["status"] != "open" -> "endpoint_closed"
        true -> "active"
      end

    %{
      "id" => row.id,
      "subject" => s,
      "target" => t,
      "status" => status,
      "dimension" => row.dimension,
      "matches" => row.matches,
      "actor" => row.actor,
      "reason" => row.reason,
      "inserted_at" => Monitoring.iso(row.inserted_at),
      "revision" => if(status == "active", do: 1, else: 2),
      "removed_at" => Monitoring.iso(row.removed_at),
      "removed_by" => row.removed_by,
      "removal_reason" => row.removal_reason
    }
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConsumerState.Namespace do
  use Ecto.Schema
  @primary_key {:source_id, :string, autogenerate: false}
  schema "consumer_state_namespaces" do
    field :bytes, :integer, default: 0
    field :entries, :integer, default: 0
  end
end

defmodule Mondek.ConsumerState.Entry do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "consumer_state_entries" do
    field :source_id, :string
    field :scope, :string
    field :key, :string
    field :payload, :map
    field :version, Ecto.UUID
    field :bytes, :integer
    field :updated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :installation_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :assignment_id, :string
    field :generation, :integer
  end
end

defmodule Mondek.ConsumerState do
  @moduledoc "Bounded consumer data, separate from observations and configuration history."
  import Ecto.Query
  alias Mondek.{Repo, Runner, Assignment, SourceInventory}
  alias Mondek.ConsumerState.{Entry, Namespace}

  def limits, do: %{value_bytes: 65_536, source_bytes: 1_048_576, source_entries: 1024, depth: 32}

  # Structural ASCII JSON cost: finite nonintegral floats always cost 24 bytes.
  # Object order does not affect cost. The SDK implements this same rule.
  def value_bytes(value), do: cost(value, 0)
  defp cost(_, depth) when depth > 32, do: throw(:invalid_state_value)
  defp cost(nil, _), do: 4
  defp cost(true, _), do: 4
  defp cost(false, _), do: 5

  defp cost(v, _) when is_integer(v) do
    s = Integer.to_string(v)
    if byte_size(String.trim_leading(s, "-")) > 4096, do: throw(:invalid_state_value)
    byte_size(s)
  end

  defp cost(v, d) when is_float(v) do
    case Mondek.Parameters.normalized_json(v) do
      n when is_integer(n) -> cost(n, d)
      _ -> 24
    end
  end

  defp cost(v, _) when is_binary(v) do
    if not String.valid?(v) or String.contains?(v, <<0>>), do: throw(:invalid_state_value)

    2 +
      Enum.sum(
        for c <- String.to_charlist(v) do
          cond do
            c in [8, 9, 10, 12, 13, 34, 92] -> 2
            c < 32 -> 6
            c < 127 -> 1
            c <= 65_535 -> 6
            true -> 12
          end
        end
      )
  end

  defp cost(v, d) when is_list(v),
    do: 2 + max(length(v) - 1, 0) + Enum.sum(Enum.map(v, &cost(&1, d + 1)))

  defp cost(v, d) when is_map(v) and not is_struct(v) do
    2 + max(map_size(v) - 1, 0) +
      Enum.sum(
        Enum.map(v, fn {k, x} ->
          if not is_binary(k), do: throw(:invalid_state_value)
          cost(k, d + 1) + 1 + cost(x, d + 1)
        end)
      )
  end

  defp cost(_, _), do: throw(:invalid_state_value)

  def exchange(params, clock \\ &now/0) do
    with :ok <- validate(params) do
      params =
        Enum.reduce(~w(installation_id session_id assignment_id expected_version), params, fn key,
                                                                                              acc ->
          if uuid?(acc[key]), do: Map.update!(acc, key, &String.downcase/1), else: acc
        end)

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '2s'")
        Repo.query!("SET LOCAL statement_timeout = '3s'")
        admit!(params)
        # Missing reads never allocate namespace metadata.
        ns =
          lock_namespace(
            params["source_id"],
            params["operation"] == "put" or
              (params["operation"] == "compare_and_set" and
                 params["expected_version"] == "missing")
          )

        at = clock.()

        scope =
          if params["scope"] == "source",
            do: "source",
            else: "assignment:" <> params["assignment_id"]

        entry =
          if ns,
            do:
              Repo.get_by(Entry, source_id: params["source_id"], scope: scope, key: params["key"])

        current = if live?(entry, at), do: entry
        result = perform(params, ns, entry, current, scope, at)
        Map.put(result, "version", 1)
      end)
    end
  end

  defp validate(p) when is_map(p) do
    allowed =
      ~w(version operation installation_id session_id boot assignment_id generation source_id scope key value expected_version ttl_seconds)

    valid =
      p["version"] == 1 and p["operation"] in ~w(get put compare_and_set delete) and
        p["scope"] in ~w(source check) and text?(p["source_id"]) and text?(p["key"]) and
        uuid?(p["installation_id"]) and uuid?(p["session_id"]) and uuid?(p["assignment_id"]) and
        is_integer(p["boot"]) and p["boot"] > 0 and is_integer(p["generation"]) and
        p["generation"] > 0 and
        Enum.all?(Map.keys(p), &(&1 in allowed)) and
        (not Map.has_key?(p, "ttl_seconds") or
           (is_integer(p["ttl_seconds"]) and p["ttl_seconds"] in 1..2_592_000)) and
        (not Map.has_key?(p, "expected_version") or p["expected_version"] == "missing" or
           uuid?(p["expected_version"])) and
        (p["operation"] != "compare_and_set" or Map.has_key?(p, "expected_version")) and
        (p["operation"] in ~w(put compare_and_set) or not Map.has_key?(p, "value")) and
        (p["operation"] in ~w(put compare_and_set) or not Map.has_key?(p, "ttl_seconds")) and
        (p["operation"] in ~w(compare_and_set delete) or not Map.has_key?(p, "expected_version"))

    if not valid, do: throw(:invalid_state_value)

    if p["operation"] in ~w(put compare_and_set) do
      if not Map.has_key?(p, "value") or value_bytes(p["value"]) > 65_536,
        do: throw(:invalid_state_value)
    end

    :ok
  catch
    :invalid_state_value ->
      {:error, {:invalid, "Invalid consumer state request or value bounds."}}
  end

  defp validate(_), do: {:error, {:invalid, "Expected a consumer state request."}}

  defp text?(v),
    do:
      is_binary(v) and String.valid?(v) and byte_size(v) in 1..200 and
        not String.match?(v, ~r/[\x00-\x1f\x7f]/u)

  defp uuid?(v), do: is_binary(v) and byte_size(v) == 36 and match?({:ok, _}, Ecto.UUID.cast(v))

  defp admit!(p) do
    r =
      Repo.one(from r in Runner, where: r.id == ^p["installation_id"], lock: "FOR NO KEY UPDATE")

    if is_nil(r) or r.session_id != p["session_id"] or r.boot != p["boot"],
      do: Repo.rollback(:state_not_authorized)

    pub =
      Repo.one(
        from s in SourceInventory,
          where: s.runner_id == ^r.id and s.source_id == ^p["source_id"],
          lock: "FOR UPDATE"
      )

    if is_nil(pub) or pub.retired_at != nil or pub.resume_after_revision != nil,
      do: Repo.rollback(:state_not_authorized)

    a = Repo.one(from a in Assignment, where: a.id == ^p["assignment_id"], lock: "FOR UPDATE")

    if is_nil(a) or a.runner_id != r.id or a.source_id != p["source_id"] or a.retired_at != nil or
         a.authorized_generation != p["generation"],
       do: Repo.rollback(:state_not_authorized)

    now = now()

    requests =
      if r.state_window_at && DateTime.diff(now, r.state_window_at, :microsecond) in 0..999_999,
        do: r.state_requests + 1,
        else: 1

    if requests > 256, do: Repo.rollback(:state_rate_limited)
    window = if requests == 1, do: now, else: r.state_window_at

    r
    |> Ecto.Changeset.change(state_requests: requests, state_window_at: window)
    |> Repo.update!()
  end

  defp lock_namespace(source, create?) do
    if create?,
      do:
        Repo.insert_all(Namespace, [%{source_id: source, bytes: 0, entries: 0}],
          on_conflict: :nothing
        )

    Repo.one(from n in Namespace, where: n.source_id == ^source, lock: "FOR UPDATE")
  end

  defp live?(nil, _), do: false
  defp live?(e, at), do: is_nil(e.expires_at) or DateTime.compare(e.expires_at, at) == :gt

  defp perform(%{"operation" => "get"}, _, _, current, _, at),
    do: Map.put(receipt(current, "found"), "observed_at", Mondek.Monitoring.iso(at))

  defp perform(p, ns, old, current, scope, at) do
    expected = p["expected_version"]

    matches =
      is_nil(expected) or (expected == "missing" and is_nil(current)) or
        (current != nil and current.version == expected)

    if not matches do
      %{"status" => "conflict"}
    else
      case p["operation"] do
        "delete" ->
          if old, do: remove!(ns, old)
          %{"status" => "deleted"}

        _ ->
          bytes = byte_size(p["key"]) + value_bytes(p["value"])
          used = ns.bytes - if(old, do: old.bytes, else: 0) + bytes
          count = ns.entries + if(old, do: 0, else: 1)
          if used > 1_048_576 or count > 1024, do: Repo.rollback(:state_quota_exceeded)

          attrs = %{
            source_id: p["source_id"],
            scope: scope,
            key: p["key"],
            payload: %{"value" => Mondek.Parameters.normalized_json(p["value"])},
            version: Ecto.UUID.generate(),
            bytes: bytes,
            updated_at: at,
            expires_at: if(p["ttl_seconds"], do: DateTime.add(at, p["ttl_seconds"], :second)),
            installation_id: p["installation_id"],
            session_id: p["session_id"],
            assignment_id: p["assignment_id"],
            generation: p["generation"]
          }

          e =
            if old,
              do: old |> Ecto.Changeset.change(attrs) |> Repo.update!(log: false),
              else: struct(Entry, attrs) |> Repo.insert!(log: false)

          ns |> Ecto.Changeset.change(bytes: used, entries: count) |> Repo.update!()
          receipt(e, "stored")
      end
    end
  end

  defp receipt(nil, _), do: %{"status" => "missing", "entry" => nil}
  defp receipt(e, status), do: %{"status" => status, "entry" => detail(e)}

  defp remove!(ns, e) do
    Repo.delete!(e)

    ns
    |> Ecto.Changeset.change(bytes: ns.bytes - e.bytes, entries: ns.entries - 1)
    |> Repo.update!()
  end

  @doc false
  def now do
    %{rows: [[at]]} = Repo.query!("SELECT clock_timestamp()")
    at
  end

  def filter_options(field, query) when field in ~w(source_id scope) do
    name = String.to_existing_atom(field)

    Repo.all(
      from e in Entry,
        where: ilike(field(e, ^name), ^("%" <> query <> "%")),
        distinct: true,
        select: field(e, ^name),
        order_by: field(e, ^name),
        limit: 20
    )
    |> Enum.map(&%{key: &1, label: &1, kind: ""})
  end

  defp page_number(n) when is_integer(n), do: n

  defp page_number(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp page_number(_), do: nil

  def list(params \\ %{}, at \\ now()) do
    page = max(1, min(page_number(params["page"]) || 1, 1_000_000))
    q = from(e in Entry)

    q =
      Enum.reduce(~w(source_id scope key), q, fn name, query ->
        if params[name] in [nil, ""],
          do: query,
          else: where(query, [e], field(e, ^String.to_existing_atom(name)) == ^params[name])
      end)

    q = visible(q, at)
    total = Repo.aggregate(q, :count)

    items =
      Repo.all(
        from e in q,
          order_by: [e.source_id, e.scope, e.key],
          limit: 20,
          offset: ^((page - 1) * 20)
      )

    ns = if params["source_id"], do: Repo.get(Namespace, params["source_id"])

    %{
      items: Enum.map(items, &metadata/1),
      page: page,
      page_size: 20,
      total: total,
      usage: if(ns, do: %{bytes: ns.bytes, entries: ns.entries}),
      limits: limits()
    }
  end

  def get(id, at \\ now()) do
    case Repo.one(visible(from(e in Entry, where: e.id == ^id), at)) do
      nil -> {:error, :not_found}
      e -> {:ok, detail(e)}
    end
  end

  defp visible(q, at) do
    from e in q,
      left_join: a in Assignment,
      on: e.scope == fragment("'assignment:' || ?", a.id),
      where:
        (is_nil(e.expires_at) or e.expires_at > ^at) and
          (e.scope == "source" or (not is_nil(a.id) and is_nil(a.retired_at)))
  end

  defp metadata(e),
    do:
      Map.take(
        Map.from_struct(e),
        ~w(id source_id scope key version bytes updated_at expires_at installation_id session_id assignment_id generation)a
      )

  defp detail(e), do: Map.put(metadata(e), :value, e.payload["value"])

  @doc "Independent bounded cleanup, never acquires runner/publication/assignment locks."
  def cleanup(limit \\ 1000) when limit in 1..1000 do
    at = now()

    candidates =
      Repo.all(
        from e in Entry,
          left_join: a in Assignment,
          on: e.scope == fragment("'assignment:' || ?", a.id),
          where:
            e.expires_at <= ^at or
              (e.scope != "source" and (is_nil(a.id) or not is_nil(a.retired_at))),
          order_by: e.source_id,
          limit: ^limit,
          select: {e.source_id, e.id}
      )

    Enum.each(Enum.group_by(candidates, &elem(&1, 0), &elem(&1, 1)), fn {source, ids} ->
      Repo.transaction(fn ->
        ns = lock_namespace(source, false)
        # Recheck after waits; a concurrent replacement may have renewed TTL.
        now = now()

        rows =
          Repo.all(
            from e in Entry,
              left_join: a in Assignment,
              on: e.scope == fragment("'assignment:' || ?", a.id),
              where:
                e.id in ^ids and
                  (e.expires_at <= ^now or
                     (e.scope != "source" and (is_nil(a.id) or not is_nil(a.retired_at))))
          )

        Enum.reduce(rows, ns, fn e, current ->
          remove!(current, e)
          %{current | bytes: current.bytes - e.bytes, entries: current.entries - 1}
        end)
      end)
    end)

    length(candidates)
  end
end

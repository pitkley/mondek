# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Coverage do
  @moduledoc "Published intent and placement inspection, independent of evidence ownership."
  import Ecto.Query
  alias Mondek.{Repo, Monitoring, Parameters, SourceInventory, CoverageDeclaration, Assignment}

  @statuses ~w(missing awaiting observed partial stale unavailable unconfirmed)
  @page_size 25

  def validate(p) do
    if not Map.has_key?(p, "coverage") or valid_catalogue?(p["coverage"], p["checks"]),
      do: :ok,
      else: {:error, {:invalid, "Malformed coverage catalogue or selected declaration mismatch."}}
  end

  defp valid_catalogue?(c, checks) when is_map(c) and is_list(checks) do
    keys?(c, ~w(version code_revision runtime_revision runner_context candidates)) and
      c["version"] == 1 and digest?(c["code_revision"]) and digest?(c["runtime_revision"]) and
      context?(c["runner_context"]) and is_list(c["candidates"]) and
      length(c["candidates"]) <= 512 and unique?(c["candidates"], "key") and
      Enum.all?(c["candidates"], &candidate?/1) and selected_match?(c["candidates"], checks)
  end

  defp valid_catalogue?(_, _), do: false

  defp context?(c) when is_map(c) do
    keys?(c, ~w(id label local_environment target capabilities)) and text?(c["id"], 128) and
      text?(c["label"], 200) and optional_text?(c["local_environment"], 128) and
      (is_nil(c["target"]) or target?(c["target"])) and is_list(c["capabilities"]) and
      length(c["capabilities"]) <= 512 and unique?(c["capabilities"], "name") and
      Enum.all?(c["capabilities"], &capability?/1)
  end

  defp context?(_), do: false

  defp capability?(%{"name" => name, "environments" => environments} = c) do
    keys?(c, ~w(name environments)) and text?(name, 128) and
      (is_nil(environments) or
         (is_list(environments) and length(environments) in 1..512 and
            Enum.all?(environments, &text?(&1, 128)) and
            length(environments) == length(Enum.uniq(environments))))
  end

  defp capability?(_), do: false

  defp candidate?(c) when is_map(c) do
    keys?(
      c,
      ~w(key label selected exclusion_reason environment environment_label scope_resolved scope_reason definition_revision outputs)
    ) and
      text?(c["key"], 200) and text?(c["label"], 200) and
      is_boolean(c["selected"]) and is_boolean(c["scope_resolved"]) and
      digest?(c["definition_revision"]) and optional_text?(c["environment"], 128) and
      optional_text?(c["environment_label"], 200) and
      (not is_nil(c["environment"]) or is_nil(c["environment_label"])) and
      is_list(c["outputs"]) and length(c["outputs"]) in 1..16 and unique?(c["outputs"], "key") and
      Enum.all?(c["outputs"], fn o ->
        is_map(o) and keys?(Map.delete(o, "group"), ~w(key label target)) and text?(o["key"], 200) and
          text?(o["label"], 200) and (is_nil(o["target"]) or target?(o["target"])) and
          (not Map.has_key?(o, "group") or Mondek.Protocol.check_group?(o["group"]))
      end) and
      if(c["selected"],
        do: c["scope_resolved"] and is_nil(c["exclusion_reason"]),
        else: text?(c["exclusion_reason"], 2048)
      ) and
      if c["scope_resolved"],
        do:
          is_nil(c["scope_reason"]) and
            Enum.all?(c["outputs"], &target?(&1["target"])),
        else: not c["selected"] and text?(c["scope_reason"], 200)
  end

  defp candidate?(_), do: false

  defp selected_match?(candidates, checks) do
    selected = Enum.filter(candidates, & &1["selected"])
    by_key = Map.new(checks, &{&1["key"], &1})

    length(selected) == length(checks) and
      Enum.all?(selected, fn c ->
        case by_key[c["key"]] do
          nil ->
            false

          check ->
            Enum.all?(~w(key label environment environment_label), &(c[&1] == check[&1])) and
              Enum.sort_by(c["outputs"], & &1["key"]) ==
                Enum.sort_by(
                  Enum.map(check["outputs"], &Map.take(&1, ~w(key label target group))),
                  & &1["key"]
                )
        end
      end)
  end

  defp target?(t) when is_map(t),
    do:
      keys?(t, ~w(key kind label)) and text?(t["key"], 200) and text?(t["kind"], 64) and
        text?(t["label"], 200)

  defp target?(_), do: false
  defp keys?(m, keys), do: Enum.sort(Map.keys(m)) == Enum.sort(keys)

  defp text?(v, limit),
    do: Parameters.text?(v, limit) and byte_size(v) <= limit

  defp optional_text?(nil, _), do: true
  defp optional_text?(v, limit), do: text?(v, limit)
  defp digest?(v), do: is_binary(v) and Regex.match?(~r/\A[a-f0-9]{64}\z/, v)

  defp unique?(items, key),
    do: Enum.all?(items, &is_map/1) and length(items) == length(Enum.uniq_by(items, & &1[key]))

  @doc false
  def reconcile!(%SourceInventory{} = source, p) do
    case p["coverage"] do
      nil ->
        Monitoring.change(source, %{coverage_confirmed: false})

      c ->
        Repo.delete_all(from d in CoverageDeclaration, where: d.source_inventory_id == ^source.id)

        assignments =
          Repo.all(
            from a in Assignment,
              where:
                a.runner_id == ^source.runner_id and a.source_id == ^source.source_id and
                  is_nil(a.retired_at),
              select: {a.source_key, a.id}
          )
          |> Map.new()

        rows =
          for candidate <- c["candidates"], output <- candidate["outputs"] do
            target = output["target"] || %{}

            %{
              source_inventory_id: source.id,
              runner_id: source.runner_id,
              source_id: source.source_id,
              source_key: candidate["key"],
              result_key: output["key"],
              scope_id:
                if(candidate["scope_resolved"], do: scope_id(source.source_id, candidate, output)),
              environment: candidate["environment"],
              environment_label: candidate["environment_label"],
              target_kind: target["kind"],
              target_key: target["key"],
              target_label: target["label"],
              check_group: output["group"],
              check_label: candidate["label"],
              result_label: output["label"],
              selected: candidate["selected"],
              exclusion_reason: candidate["exclusion_reason"],
              scope_resolved: candidate["scope_resolved"],
              scope_reason: candidate["scope_reason"],
              definition_revision: candidate["definition_revision"],
              assignment_id: if(candidate["selected"], do: assignments[candidate["key"]])
            }
          end

        # Stay comfortably below PostgreSQL's parameter limit at 8192 outputs.
        Enum.each(Enum.chunk_every(rows, 1000), &Repo.insert_all(CoverageDeclaration, &1))

        Monitoring.change(source, %{
          coverage_version: 1,
          coverage_revision: source.revision,
          coverage_received_at: source.received_at,
          coverage_source_revision: source.source_revision,
          coverage_code_revision: c["code_revision"],
          coverage_runtime_revision: c["runtime_revision"],
          coverage_context: c["runner_context"],
          coverage_confirmed: true
        })
    end
  end

  defp scope_id(source, c, o),
    do:
      :crypto.hash(
        :sha256,
        Jason.encode!([
          source,
          c["key"],
          o["key"],
          c["environment"],
          o["target"]["kind"],
          o["target"]["key"]
        ])
      )
      |> Base.encode16(case: :lower)

  # One row is one publisher's output declaration. Its own accepted assignment is
  # the only authority for observation; an unrelated observer never fills it in.
  @declarations """
  WITH declarations AS (
    SELECT d.*, d.runner_id::text AS runner_id_text,p.coverage_confirmed AS audit_confirmed, p.coverage_code_revision AS code_revision,
      p.coverage_runtime_revision AS runtime_revision, p.coverage_context AS runner_context,
      p.revision AS inventory_revision, p.coverage_revision, p.source_revision,
      p.coverage_source_revision, p.coverage_received_at, r.label AS runner_label, r.last_seen_at,r.session_id::text AS current_session_id,
      a.desired_generation, a.prepared_generation, a.authorized_generation, a.active_generation,
      a.observed_generation, s.id::text AS stream_id,
      CASE WHEN a.id IS NOT NULL AND s.id IS NOT NULL THEN true ELSE false END AS admitted,
      CASE WHEN r.last_seen_at > $2::timestamptz - interval '15 seconds' THEN true ELSE false END AS online,
      s.current,
      CASE WHEN s.current <> '{}'::jsonb AND s.current->>'session_id'=r.session_id::text
        AND s.current->>'knowledge' NOT IN ('unavailable','stale')
        AND s.current->>'confirmed_observation_id' IS NOT NULL
        AND (s.current->>'source_at')::timestamptz > $2::timestamptz - a.freshness_seconds * interval '1 second'
        THEN true ELSE false END AS fresh_evidence,
      CASE WHEN (s.current->>'generation')::bigint=a.desired_generation
        AND c.definition->>'source_revision'=p.coverage_source_revision
        AND p.coverage_source_revision=p.source_revision THEN true ELSE false END AS desired_evidence
    FROM coverage_declarations d
    JOIN source_inventories p ON p.id=d.source_inventory_id AND p.retired_at IS NULL AND p.resume_after_revision IS NULL
    JOIN runners r ON r.id=d.runner_id
    LEFT JOIN assignments a ON a.id=d.assignment_id AND a.retired_at IS NULL
      AND a.runner_id=d.runner_id AND a.source_id=d.source_id AND a.source_key=d.source_key
    LEFT JOIN result_streams s ON s.assignment_id=a.id AND s.retired_at IS NULL
      AND s.result_key=d.result_key AND s.environment IS NOT DISTINCT FROM d.environment
      AND s.target->>'kind'=d.target_kind AND s.target->>'key'=d.target_key
    LEFT JOIN configurations c ON c.assignment_id=a.id AND c.generation=(s.current->>'generation')::bigint
  ), classified AS (
    SELECT *,
      CASE WHEN NOT audit_confirmed THEN 'unconfirmed'
        WHEN NOT selected THEN 'excluded'
        WHEN NOT admitted THEN 'unadmitted'
        WHEN NOT desired_evidence THEN 'pending'
        WHEN current->>'session_id' IS DISTINCT FROM current_session_id::text THEN 'pending'
        WHEN current->>'knowledge'='unavailable' THEN 'unavailable'
        WHEN fresh_evidence THEN 'fresh'
        WHEN current IS NULL OR current='{}'::jsonb THEN 'pending'
        ELSE 'stale' END AS measurement_state,
      (audit_confirmed AND selected AND admitted AND fresh_evidence AND NOT desired_evidence) AS older_version
    FROM declarations
  ), scope_counts AS (
    SELECT scope_id AS id, source_id, source_key, result_key, environment, target_kind, target_key,
      min(environment_label) AS environment_label, min(target_label) AS target_label,
      min(check_label) AS check_label, min(result_label) AS result_label,
      count(*)::integer AS declaring,
      count(*) FILTER (WHERE selected AND audit_confirmed)::integer AS selected,
      count(*) FILTER (WHERE admitted AND selected AND audit_confirmed)::integer AS admitted,
      count(*) FILTER (WHERE measurement_state='fresh')::integer AS fresh,
      min((current->>'source_at')::timestamptz) FILTER (WHERE selected AND audit_confirmed) AS latest_source_at,
      count(*) FILTER (WHERE measurement_state IN ('pending','unadmitted'))::integer AS pending,
      count(*) FILTER (WHERE measurement_state='stale')::integer AS stale,
      count(*) FILTER (WHERE measurement_state='unavailable')::integer AS unavailable,
      count(*) FILTER (WHERE older_version)::integer AS older_version,
      count(*) FILTER (WHERE NOT audit_confirmed)::integer AS unconfirmed,
      count(*) FILTER (WHERE selected AND audit_confirmed AND NOT online)::integer AS offline,
      count(DISTINCT code_revision)::integer AS code_variants,
      count(DISTINCT runtime_revision)::integer AS runtime_variants,
      count(DISTINCT definition_revision)::integer AS definition_variants,
      bool_or(runner_id::text=($1::jsonb->>'runner_id')) AS matches_runner,
      bool_or(position(lower($1::jsonb->>'search') in lower(concat_ws(' ',source_id,source_key,result_key,environment,environment_label,target_kind,target_key,target_label,check_label,result_label,runner_label)))>0) AS matches_search
    FROM classified WHERE scope_resolved GROUP BY scope_id,source_id,source_key,result_key,environment,target_kind,target_key
  ), scopes AS (
    SELECT *, CASE WHEN declaring=unconfirmed THEN 'unconfirmed'
      WHEN selected=0 THEN 'missing'
      WHEN fresh=selected AND unconfirmed=0 THEN 'observed'
      WHEN fresh>0 THEN 'partial'
      WHEN pending>0 THEN 'awaiting'
      WHEN unavailable>0 THEN 'unavailable'
      ELSE 'stale' END AS status
    FROM scope_counts
  ), filtered AS (
    SELECT * FROM scopes WHERE
      (NOT ($1::jsonb ? 'source_id') OR source_id=$1::jsonb->>'source_id') AND
      (NOT ($1::jsonb ? 'environment') OR environment=$1::jsonb->>'environment') AND
      (NOT ($1::jsonb ? 'runner_id') OR matches_runner) AND
      (NOT ($1::jsonb ? 'id') OR id=$1::jsonb->>'id') AND
      (NOT ($1::jsonb ? 'status') OR status=$1::jsonb->>'status') AND
      (NOT ($1::jsonb ? 'search') OR matches_search)
  )
  """

  @doc false
  def monitoring_scopes(at), do: query(@declarations <> "SELECT * FROM scopes", [%{}, at])

  def scopes(filters \\ %{}, at \\ Monitoring.now()) do
    read(fn -> read_scopes(filters, at) end)
  end

  defp read_scopes(filters, at) do
    filters = filters(filters)
    summary = summary(filters, at)
    page = page_number(filters, summary["scopes"])

    items =
      query(
        @declarations <>
          "SELECT * FROM filtered ORDER BY CASE status WHEN 'missing' THEN 0 WHEN 'unconfirmed' THEN 1 WHEN 'unavailable' THEN 2 WHEN 'stale' THEN 3 WHEN 'awaiting' THEN 4 WHEN 'partial' THEN 5 ELSE 6 END,source_id,source_key,result_key,environment,target_kind,target_key LIMIT 25 OFFSET $3",
        [filters, at, (page - 1) * @page_size]
      )
      |> Enum.map(&scope_public/1)

    %{
      "items" => items,
      "page" => page,
      "page_size" => @page_size,
      "total" => summary["scopes"],
      "summary" => summary
    }
  end

  def summary(filters \\ %{}, at \\ Monitoring.now()) do
    read(fn -> read_summary(filters, at) end)
  end

  defp read_summary(filters, at) do
    filters = filters(filters)

    counts =
      Enum.map_join(@statuses, ",", fn status ->
        "count(*) FILTER (WHERE status='#{status}')::integer AS #{status}"
      end)

    [base] =
      query(
        @declarations <>
          "SELECT count(*)::integer AS scopes," <>
          counts <>
          ",count(*) FILTER (WHERE code_variants>1 OR runtime_variants>1 OR definition_variants>1)::integer AS mixed_versions FROM filtered",
        [filters, at]
      )

    [publishers] =
      query(
        publisher_cte() <>
          "SELECT count(*) FILTER (WHERE lifecycle_status='active')::integer AS publishers,count(*) FILTER (WHERE lifecycle_status='retired')::integer AS retired_publishers,count(*) FILTER (WHERE lifecycle_status='awaiting_inventory')::integer AS awaiting_publishers,count(*) FILTER (WHERE lifecycle_status='active' AND coverage_version IS NULL)::integer AS unsupported_publishers,count(*) FILTER (WHERE lifecycle_status='active' AND coverage_version IS NOT NULL AND NOT coverage_confirmed)::integer AS unconfirmed_publishers,coalesce(sum(unbound) FILTER (WHERE lifecycle_status='active'),0)::integer AS unbound_declarations FROM filtered_publishers",
        [filters]
      )

    Map.merge(base, publishers)
  end

  def scope(id, at \\ Monitoring.now()) do
    if digest?(id),
      do:
        query(@declarations <> "SELECT * FROM filtered", [%{"id" => id}, at])
        |> List.first()
        |> then(&if(&1, do: scope_public(&1))),
      else: nil
  end

  def observers(id, filters \\ %{}, at \\ Monitoring.now()) do
    read(fn -> read_observers(id, filters, at) end)
  end

  defp read_observers(id, filters, at) do
    filters = filters(filters) |> Map.put("id", if(digest?(id), do: id, else: "invalid"))

    [count] =
      query(
        @declarations <>
          "SELECT count(*)::integer AS total FROM classified WHERE scope_id=$1::jsonb->>'id'",
        [filters, at]
      )

    page = page_number(filters, count["total"])

    rows =
      query(
        @declarations <>
          "SELECT * FROM classified WHERE scope_id=$1::jsonb->>'id' ORDER BY selected DESC,runner_label,runner_id,source_inventory_id LIMIT 25 OFFSET $3",
        [filters, at, (page - 1) * @page_size]
      )

    %{
      "items" => Enum.map(rows, &observer_public/1),
      "page" => page,
      "page_size" => @page_size,
      "total" => count["total"]
    }
  end

  def publishers(filters \\ %{}, _at \\ Monitoring.now()) do
    read(fn -> read_publishers(filters) end)
  end

  defp read_publishers(filters) do
    filters = filters(filters)

    [count] =
      query(publisher_cte() <> "SELECT count(*)::integer AS total FROM filtered_publishers", [
        filters
      ])

    page = page_number(filters, count["total"])

    rows =
      query(
        publisher_cte() <>
          "SELECT * FROM filtered_publishers ORDER BY source_id,runner_label,runner_id LIMIT 25 OFFSET $2",
        [filters, (page - 1) * @page_size]
      )

    %{"items" => rows, "page" => page, "page_size" => @page_size, "total" => count["total"]}
  end

  def diagnostics(filters \\ %{}, at \\ Monitoring.now()) do
    read(fn -> read_diagnostics(filters, at) end)
  end

  defp read_diagnostics(filters, at) do
    filters = filters(filters)

    suffix =
      " FROM classified WHERE NOT scope_resolved AND (NOT ($1::jsonb ? 'source_id') OR source_id=$1::jsonb->>'source_id') AND (NOT ($1::jsonb ? 'runner_id') OR runner_id::text=$1::jsonb->>'runner_id') AND (NOT ($1::jsonb ? 'environment') OR environment=$1::jsonb->>'environment') AND (NOT ($1::jsonb ? 'search') OR position(lower($1::jsonb->>'search') in lower(concat_ws(' ',source_id,source_key,check_label,scope_reason,exclusion_reason)))>0)"

    [count] = query(@declarations <> "SELECT count(*)::integer AS total" <> suffix, [filters, at])
    page = page_number(filters, count["total"])

    rows =
      query(
        @declarations <>
          "SELECT *" <>
          suffix <> " ORDER BY source_id,source_key,runner_id,result_key LIMIT 25 OFFSET $3",
        [filters, at, (page - 1) * @page_size]
      )

    %{
      "items" => Enum.map(rows, &observer_public/1),
      "page" => page,
      "page_size" => @page_size,
      "total" => count["total"]
    }
  end

  defp publisher_cte do
    """
    WITH publisher_counts AS (
      SELECT p.id,p.runner_id::text AS runner_id,p.source_id,p.revision AS inventory_revision,p.source_revision,p.received_at,
        p.coverage_version,p.coverage_revision,p.coverage_received_at,p.coverage_confirmed,p.coverage_source_revision,
        p.lifecycle_revision,p.retired_at,p.retirement_reason,p.replacement_id,p.resume_after_revision,
        CASE WHEN p.retired_at IS NOT NULL THEN 'retired' WHEN p.resume_after_revision IS NOT NULL THEN 'awaiting_inventory' ELSE 'active' END AS lifecycle_status,
        p.coverage_code_revision AS code_revision,p.coverage_runtime_revision AS runtime_revision,
        p.coverage_context AS runner_context,r.label AS runner_label,r.last_seen_at,
        count(d.id)::integer AS declarations,count(DISTINCT d.source_key)::integer AS candidates,
        count(d.id) FILTER (WHERE NOT d.scope_resolved)::integer AS unbound,
        count(d.id) FILTER (WHERE d.selected)::integer AS selected,
        bool_or(d.environment=$1::jsonb->>'environment') AS matches_environment,
        CASE WHEN p.coverage_version IS NULL THEN 'unsupported' WHEN p.coverage_confirmed THEN 'confirmed' ELSE 'unconfirmed' END AS audit_status
      FROM source_inventories p JOIN runners r ON r.id=p.runner_id
      LEFT JOIN coverage_declarations d ON d.source_inventory_id=p.id
      GROUP BY p.id,r.id
    ), filtered_publishers AS (
      SELECT * FROM publisher_counts WHERE
        (NOT ($1::jsonb ? 'source_id') OR source_id=$1::jsonb->>'source_id') AND
        (NOT ($1::jsonb ? 'lifecycle') OR $1::jsonb->>'lifecycle'='all' OR lifecycle_status=$1::jsonb->>'lifecycle') AND
        (NOT ($1::jsonb ? 'runner_id') OR runner_id::text=$1::jsonb->>'runner_id') AND
        (NOT ($1::jsonb ? 'environment') OR matches_environment) AND
        (NOT ($1::jsonb ? 'search') OR position(lower($1::jsonb->>'search') in lower(concat_ws(' ',source_id,runner_label,runner_context->>'id')))>0)
    )
    """
  end

  defp scope_public(row) do
    row
    |> Map.drop(
      ~w(target_kind target_key target_label declaring selected admitted fresh pending stale unavailable older_version unconfirmed offline matches_runner matches_search)
    )
    |> Map.put("target", %{
      "kind" => row["target_kind"],
      "key" => row["target_key"],
      "label" => row["target_label"]
    })
    |> Map.put(
      "counts",
      Map.take(
        row,
        ~w(declaring selected admitted fresh pending stale unavailable older_version unconfirmed offline)
      )
    )
  end

  defp observer_public(row) do
    row
    |> Map.drop(~w(fresh_evidence desired_evidence))
    |> Map.put("runner_id", row["runner_id_text"])
    |> Map.delete("runner_id_text")
    |> Map.put(
      "target",
      if(row["target_key"],
        do: %{
          "kind" => row["target_kind"],
          "key" => row["target_key"],
          "label" => row["target_label"]
        }
      )
    )
    |> Map.put(
      "configuration",
      Map.take(
        row,
        ~w(desired_generation prepared_generation authorized_generation active_generation observed_generation)
      )
    )
  end

  defp query(sql, args) do
    result = Repo.query!(sql, args)

    Enum.map(result.rows, fn values ->
      Map.new(Enum.zip(result.columns, values))
      |> Map.new(fn {key, value} ->
        value =
          case value do
            %DateTime{} -> Monitoring.iso(value)
            %NaiveDateTime{} -> value |> DateTime.from_naive!("Etc/UTC") |> Monitoring.iso()
            other -> other
          end

        {key, value}
      end)
    end)
  end

  defp read(function) do
    if Repo.in_transaction?() do
      function.()
    else
      {:ok, result} =
        Repo.transaction(fn ->
          Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
          function.()
        end)

      result
    end
  end

  defp filters(values) when is_map(values) do
    values
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(~w(source_id environment runner_id search status page id lifecycle))
    |> Enum.filter(fn {_k, v} ->
      (is_binary(v) and v != "" and byte_size(v) <= 200 and String.valid?(v) and
         not String.contains?(v, <<0>>)) or is_integer(v)
    end)
    |> Map.new()
  end

  defp filters(_), do: %{}

  defp page_number(filters, total) do
    page =
      case filters["page"] do
        n when is_integer(n) ->
          n

        n when is_binary(n) ->
          case Integer.parse(n) do
            {n, ""} -> n
            _ -> 1
          end

        _ ->
          1
      end

    page |> max(1) |> min(max(1, div(total + @page_size - 1, @page_size)))
  end
end

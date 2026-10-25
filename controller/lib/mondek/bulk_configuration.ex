# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.BulkConfiguration do
  @moduledoc "Bounded, reviewed whole-set parameter edits with one atomic database commit."
  import Ecto.Query
  import Kernel, except: [apply: 2]
  alias Mondek.{Assignment, Inspection, Monitoring, Parameters, Protocol, Repo, Runner}
  @limit 512
  @page_size 25
  @max_age 900
  @stages ~w(pending prepared active measured superseded retired missing)

  def select(filters) when is_map(filters) do
    Repo.transaction(fn ->
      filters = Map.new(filters, fn {key, value} -> {to_string(key), value} end)

      for key <-
            ~w(search runner_id environment status source_id parameter_contract schema_fingerprint) do
        value = filters[key]

        if value not in [nil, ""] and not Parameters.text?(value, 200),
          do:
            Repo.rollback(
              {:invalid,
               "Supply bounded text without control characters for configuration filters."}
            )
      end

      query = Inspection.checks_query(filters)
      total = Repo.aggregate(query, :count)

      query =
        Enum.reduce(~w(source_id parameter_contract), query, fn name, query ->
          if is_binary(filters[name]) and filters[name] != "" do
            field = if name == "source_id", do: :source_id, else: :parameter_contract
            from [a, r] in query, where: field(a, ^field) == ^filters[name]
          else
            query
          end
        end)

      query =
        if is_binary(filters["schema_fingerprint"]) and filters["schema_fingerprint"] != "",
          do:
            from([a, r] in query,
              where: a.parameter_schema_fingerprint == ^filters["schema_fingerprint"]
            ),
          else: query

      eligible =
        from [a, r] in query,
          where:
            is_nil(a.retired_at) and a.params_owner == "ui" and not is_nil(a.parameter_contract) and
              not is_nil(a.runner_id)

      count = Repo.aggregate(eligible, :count)

      if count > @limit,
        do:
          Repo.rollback(
            {:invalid,
             "More than 512 editable checks match. Narrow the filters before selecting all."}
          )

      selection =
        Repo.all(
          from [a, r] in eligible,
            order_by: a.id,
            limit: @limit,
            select: %{id: a.id, revision: a.revision}
        )
        |> Enum.map(&%{"id" => &1.id, "revision" => &1.revision})

      %{
        "selection" => selection,
        "total_matching" => total,
        "eligible_count" => count,
        "excluded_count" => total - count
      }
    end)
  end

  def select(_), do: {:error, {:invalid, "Supply configuration filters."}}

  def prepare(selection, page) do
    Repo.transaction(fn ->
      selection = validate_selection!(selection)
      rows = selected_rows(selection)
      schema = validate_reviewed_rows!(selection, rows)
      prepared = token_data(selection, rows)

      summary(rows, schema, page)
      |> Map.put("prepare_token", sign("prepare", prepared))
    end)
  end

  def preview(token, params, page) do
    with {:ok, prepared} <- verify("prepare", token) do
      Repo.transaction(fn ->
        selection = validate_selection!(prepared["selection"])
        rows = selected_rows(selection)
        schema = validate_reviewed_rows!(selection, rows)
        verify_fingerprint!(prepared, rows)
        validate_params!(schema, params)
        # Preview uses the same future response budget as commit, with no writes.
        ensure_projected_bounds!(rows, params)
        changed = Enum.filter(rows, &Monitoring.configuration_changed?(&1, params))

        summary(rows, schema, page)
        |> Map.update!("rows", fn visible ->
          Enum.map(visible, fn row ->
            Map.merge(row, %{
              "proposed_params" => params,
              "changed" => not equal_params?(row["current_params"], params)
            })
          end)
        end)
        |> Map.merge(%{
          "review_token" =>
            sign("review", Map.put(prepared, "params_fingerprint", fingerprint(params))),
          "changed_count" => length(changed),
          "unchanged_count" => length(rows) - length(changed),
          "affected_results" => Enum.sum(Enum.map(changed, &length(&1.expected_keys)))
        })
      end)
    end
  end

  def apply(token, params) do
    with {:ok, reviewed} <- verify("review", token) do
      result =
        Mondek.ConfigurationRepository.transaction("ui", fn ->
          if reviewed["params_fingerprint"] != fingerprint(params),
            do: Repo.rollback(:review_changed)

          selection = validate_selection!(reviewed["selection"])
          initial = selected_rows(selection)
          validate_reviewed_rows!(selection, initial)

          initial
          |> Enum.map(& &1.source_id)
          |> Enum.uniq()
          |> Enum.sort()
          |> Enum.each(&Mondek.ConfigurationRules.lock_source!/1)

          runner_ids = initial |> Enum.map(& &1.runner_id) |> Enum.uniq() |> Enum.sort()

          Repo.all(
            from r in Runner,
              where: r.id in ^runner_ids,
              order_by: r.id,
              lock: "FOR NO KEY UPDATE"
          )

          rows = selected_rows(selection, true)
          schema = validate_reviewed_rows!(selection, rows)
          verify_fingerprint!(reviewed, rows)
          validate_params!(schema, params)

          # Expiry still applies if acquiring the database locks took time.
          case verify("review", token) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          at = Monitoring.now()

          receipts =
            Enum.map(rows, fn row ->
              saved = Monitoring.update_configuration!(row, params, at)

              %{
                "id" => row.id,
                "revision" => saved.revision,
                "target_generation" => saved.desired_generation,
                "changed" => saved.revision != row.revision
              }
            end)

          for runner_id <- runner_ids, do: Monitoring.ensure_control_bound!(runner_id)
          count = Enum.count(receipts, & &1["changed"])

          %{
            "changed_count" => count,
            "unchanged_count" => length(receipts) - count,
            "receipts" => receipts
          }
        end)

      if match?({:ok, _}, result), do: Monitoring.notify()
      if match?({:ok, _}, result), do: Monitoring.notify_control()
      result
    end
  end

  def status(receipts, page) do
    Repo.transaction(fn ->
      selection =
        if is_list(receipts) do
          Enum.map(receipts, fn
            %{
              "id" => id,
              "revision" => revision,
              "target_generation" => generation,
              "changed" => changed
            }
            when is_integer(generation) and generation in 1..2_147_483_647 and is_boolean(changed) ->
              %{"id" => id, "revision" => revision}

            _ ->
              Repo.rollback({:invalid, "Supply the bounded saved configuration receipts."})
          end)
        else
          Repo.rollback({:invalid, "Supply the bounded saved configuration receipts."})
        end

      selection = validate_selection!(selection)
      rows = selected_rows(selection)
      by_id = Map.new(rows, &{&1.id, &1})
      runners = runner_labels(rows)

      entries =
        receipts
        |> Enum.sort_by(& &1["id"])
        |> Enum.map(fn receipt ->
          row = by_id[receipt["id"]]

          public =
            if row,
              do: row_public(row, runners),
              else: %{"id" => receipt["id"], "label" => "Unavailable check"}

          Map.merge(public, %{
            "target_generation" => receipt["target_generation"],
            "stage" => stage(row, receipt["target_generation"]),
            "changed" => receipt["changed"]
          })
        end)

      counts = Enum.frequencies_by(entries, & &1["stage"])

      page_result(entries, page)
      |> Map.put("counts", Map.new(@stages, &{&1, Map.get(counts, &1, 0)}))
    end)
  end

  defp stage(nil, _), do: "missing"
  defp stage(%{retired_at: retired}, _) when not is_nil(retired), do: "retired"
  defp stage(%{desired_generation: current}, target) when current != target, do: "superseded"
  defp stage(%{observed_generation: target}, target), do: "measured"
  defp stage(%{active_generation: target}, target), do: "active"
  defp stage(%{prepared_generation: target}, target), do: "prepared"
  defp stage(_, _), do: "pending"

  defp validate_selection!(selection)
       when is_list(selection) and length(selection) in 1..@limit do
    entries =
      Enum.map(selection, fn
        %{"id" => id, "revision" => revision}
        when is_integer(revision) and revision in 1..2_147_483_647 ->
          if not Protocol.assignment_id?(id),
            do: Repo.rollback({:invalid, "The selection contains an invalid check ID."})

          %{"id" => id, "revision" => revision}

        _ ->
          Repo.rollback({:invalid, "Select checks with the exact revisions shown in the list."})
      end)

    if length(Enum.uniq_by(entries, & &1["id"])) != length(entries),
      do: Repo.rollback({:invalid, "Select each check only once."})

    Enum.sort_by(entries, & &1["id"])
  end

  defp validate_selection!(_), do: Repo.rollback({:invalid, "Select between 1 and 512 checks."})

  defp selected_rows(selection, lock? \\ false) do
    ids = Enum.map(selection, & &1["id"])
    query = from a in Assignment, where: a.id in ^ids, order_by: a.id
    Repo.all(if lock?, do: lock(query, "FOR UPDATE"), else: query)
  end

  defp validate_reviewed_rows!(selection, rows) do
    by_id = Map.new(rows, &{&1.id, &1})

    stale =
      Enum.filter(selection, fn s ->
        is_nil(by_id[s["id"]]) or by_id[s["id"]].revision != s["revision"]
      end)

    if stale != [], do: Repo.rollback({:stale, Enum.map(stale, & &1["id"])})

    for row <- rows do
      if not is_nil(row.retired_at) or row.params_owner != "ui" or is_nil(row.source_id) or
           is_nil(row.parameter_contract) or is_nil(row.runner_id),
         do:
           Repo.rollback(
             {:invalid,
              "#{row.label} is not an active check with an explicitly delegated parameter contract."}
           )
    end

    first = hd(rows)
    schema = Parameters.normalized_schema(first.parameter_schema)

    if Enum.any?(rows, fn row ->
         row.source_id != first.source_id or row.parameter_contract != first.parameter_contract or
           Parameters.normalized_schema(row.parameter_schema) !== schema
       end),
       do:
         Repo.rollback(
           {:invalid,
            "Choose checks from one source and explicit parameter contract with exactly the same schema, units, bounds and comparisons."}
         )

    schema
  end

  defp validate_params!(schema, params) do
    case Parameters.validate(schema, params) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid, reason})
    end
  end

  defp summary(rows, schema, page) do
    first = hd(rows)

    mixed =
      schema["fields"]
      |> Map.keys()
      |> Enum.filter(fn key ->
        Enum.any?(rows, &(not Parameters.same_json?(&1.params[key], first.params[key])))
      end)
      |> Enum.sort()

    common = Map.drop(first.params, mixed)
    labels = runner_labels(rows)

    visible =
      rows
      |> Enum.sort_by(&{&1.label, labels[&1.runner_id] || "", &1.id})
      |> Enum.map(&row_public(&1, labels))

    page_result(visible, page)
    |> Map.merge(%{
      "source_id" => first.source_id,
      "parameter_contract" => first.parameter_contract,
      "parameter_schema" => schema,
      "schema_fingerprint" => Parameters.schema_fingerprint(schema),
      "common_params" => common,
      "mixed_fields" => mixed,
      "selected_count" => length(rows),
      "selected_result_count" => Enum.sum(Enum.map(rows, &length(&1.expected_keys))),
      "expires_in_seconds" => @max_age
    })
  end

  defp page_result(rows, requested) do
    page =
      case requested do
        n when is_integer(n) and n > 0 ->
          n

        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} when n > 0 -> n
            _ -> 1
          end

        _ ->
          1
      end

    page = min(page, max(1, div(length(rows) + @page_size - 1, @page_size)))

    %{
      "rows" => Enum.slice(rows, (page - 1) * @page_size, @page_size),
      "page" => page,
      "page_size" => @page_size,
      "total" => length(rows)
    }
  end

  defp runner_labels(rows) do
    ids = rows |> Enum.map(& &1.runner_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    Repo.all(from r in Runner, where: r.id in ^ids, select: {r.id, r.label}) |> Map.new()
  end

  defp row_public(row, labels) do
    %{
      "id" => row.id,
      "label" => row.label,
      "runner_id" => row.runner_id,
      "runner_label" => labels[row.runner_id],
      "environment" => row.environment,
      "environment_label" => row.environment_label,
      "outputs" => row.outputs,
      "revision" => row.revision,
      "current_params" => row.params,
      "desired_generation" => row.desired_generation,
      "source_id" => row.source_id,
      "source_key" => row.source_key,
      "parameter_contract" => row.parameter_contract
    }
  end

  defp token_data(selection, rows),
    do: %{"selection" => selection, "fingerprint" => rows_fingerprint(rows)}

  defp rows_fingerprint(rows) do
    rows
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :revision,
        :runner_id,
        :source_id,
        :source_key,
        :source_revision,
        :definition_revision,
        :parameter_contract,
        :parameter_schema,
        :params_owner,
        :params,
        :outputs,
        :expected_keys,
        :retired_at
      ])
    )
    |> fingerprint()
  end

  defp verify_fingerprint!(token, rows) do
    if token["fingerprint"] != rows_fingerprint(rows),
      do: Repo.rollback({:stale, Enum.map(rows, & &1.id)})
  end

  defp fingerprint(value),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Parameters.normalized_json(value), [:deterministic])
      )
      |> Base.encode16(case: :lower)

  defp sign(purpose, data),
    do:
      Phoenix.Token.sign(
        MondekWeb.Endpoint,
        "bulk-configuration/" <> purpose,
        Map.put(data, "purpose", purpose)
      )

  defp verify(purpose, token) when is_binary(token) and byte_size(token) <= 131_072 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, "bulk-configuration/" <> purpose, token,
           max_age: @max_age
         ) do
      {:ok, %{"purpose" => ^purpose} = data} -> {:ok, data}
      {:error, :expired} -> {:error, :review_expired}
      _ -> {:error, :invalid_review}
    end
  end

  defp verify(_, _), do: {:error, :invalid_review}

  defp equal_params?(first, second), do: Parameters.same_json?(first, second)

  defp ensure_projected_bounds!(rows, params) do
    params = Parameters.normalized_json(params)

    replacements =
      Map.new(rows, fn row ->
        candidate =
          if Monitoring.configuration_changed?(row, params),
            do: %{row | params: params, desired_generation: row.desired_generation + 1},
            else: row

        {row.id, candidate}
      end)

    runner_ids = rows |> Enum.map(& &1.runner_id) |> Enum.uniq()

    for runner_id <- runner_ids do
      Monitoring.ensure_control_bound!(runner_id, replacements)
    end
  end
end

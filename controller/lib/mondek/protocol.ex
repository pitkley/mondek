# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Protocol do
  @integer_limit Integer.pow(10, 4096)
  @moduledoc "Bounded, versioned local runner transport validation."
  def control(p) when is_map(p) do
    valid =
      p["version"] == 1 and uuid?(p["installation_id"]) and uuid?(p["session_id"]) and
        positive?(p["boot"]) and
        (is_nil(p["runner_label"]) or Mondek.Parameters.text?(p["runner_label"], 200)) and
        is_map(Map.get(p, "status", %{})) and json_text?(Map.get(p, "status", %{})) and
        byte_size(Jason.encode!(Map.get(p, "status", %{}))) <= 16_384 and
        generations?(Map.get(p, "prepared", %{})) and generations?(Map.get(p, "active", %{})) and
        is_integer(Map.get(p, "wait_seconds", 0)) and Map.get(p, "wait_seconds", 0) in 0..10

    validate(valid)
  end

  def control(_), do: invalid()

  def envelope(p) when is_map(p) do
    validate(
      p["version"] == 1 and uuid?(p["installation_id"]) and uuid?(p["session_id"]) and
        is_list(p["reports"]) and length(p["reports"]) in 1..32 and
        Enum.all?(p["reports"], &is_map/1)
    )
  end

  def envelope(_), do: invalid()

  def report(p, now) when is_map(p) do
    valid =
      json_text?(p) and uuid?(p["id"]) and uuid?(p["installation_id"]) and uuid?(p["session_id"]) and
        assignment_id?(p["assignment_id"]) and
        generation?(p["generation"]) and positive?(p["sequence"]) and is_boolean(p["complete"]) and
        text?(p["diagnostic"], 2048, true) and
        timestamp?(p["started_at"], now) and timestamp?(p["evaluated_at"], now) and
        ordered?(p["started_at"], p["evaluated_at"]) and
        is_list(p["results"]) and length(p["results"]) <= 16 and
        Enum.all?(p["results"], &result?(&1, now, p["evaluated_at"]))

    if valid and Enum.any?(p["results"], &per_output_environment?/1),
      do:
        {:error,
         {:unsupported_result_environment,
          "Results cannot override environment or environment_label. The accepted scheduled check defines their monitored environment; use separate environment bindings."}},
      else: validate(valid)
  end

  def report(_, _), do: invalid()

  @doc false
  def per_output_environment?(value) when is_map(value),
    do: Map.has_key?(value, "environment") or Map.has_key?(value, "environment_label")

  def per_output_environment?(_), do: false

  def membership(p, expected) do
    keys = Enum.map(p["results"], & &1["key"])

    validate(
      length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in expected)) and
        (not p["complete"] or Enum.sort(keys) == Enum.sort(expected))
    )
  end

  defp result?(r, now, evaluated) when is_map(r) do
    text?(r["key"], 200, false) and r["health"] in ["OK", "WARN", "CRIT", "UNKNOWN"] and
      text?(r["summary"], 2048, false) and
      text?(r["details"], 16_384, true) and
      (not Map.has_key?(r, "discovery") or Mondek.Discovery.valid?(r["discovery"])) and
      impacts?(Map.get(r, "impacts", [])) and
      (r["health"] != "OK" or Map.get(r, "impacts", []) == []) and
      (is_nil(r["value"]) or is_number(r["value"])) and
      (is_nil(r["source_at"]) or
         (timestamp?(r["source_at"], now) and ordered?(r["source_at"], evaluated)))
  end

  defp result?(_, _, _), do: false

  def check_group?(%{"key" => key, "label" => label} = value),
    do: map_size(value) == 2 and stable_key?(key) and bounded_label?(label)

  def check_group?(_), do: false

  def condition?(nil), do: true

  def condition?(%{"namespace" => namespace, "key" => key, "label" => label} = value),
    do:
      map_size(value) == 3 and stable_key?(namespace) and stable_key?(key) and
        bounded_label?(label)

  def condition?(_), do: false

  def impacts?(values) when is_list(values) and length(values) <= 16 do
    Enum.all?(values, fn
      %{"key" => key, "label" => label} = value ->
        map_size(value) == 2 and stable_key?(key) and bounded_label?(label)

      _ ->
        false
    end) and length(values) == length(Enum.uniq_by(values, & &1["key"]))
  end

  def impacts?(_), do: false

  defp stable_key?(value),
    do:
      is_binary(value) and String.valid?(value) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:\/@-]{0,127}\z/, value)

  defp bounded_label?(value),
    do: is_binary(value) and byte_size(value) <= 200 and Mondek.Parameters.text?(value, 200)

  def json_text?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  def json_text?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> json_text?(key) and json_text?(item) end)

  def json_text?(value) when is_list(value), do: Enum.all?(value, &json_text?/1)
  def json_text?(value) when is_integer(value), do: json_numbers?(value)
  def json_text?(value), do: is_nil(value) or is_boolean(value) or is_float(value)

  def json_numbers?(value) when is_integer(value), do: abs(value) < @integer_limit

  def json_numbers?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> json_numbers?(key) and json_numbers?(item) end)

  def json_numbers?(value) when is_list(value), do: Enum.all?(value, &json_numbers?/1)
  def json_numbers?(_), do: true

  defp generations?(map) when is_map(map),
    do:
      map_size(map) <= 512 and
        Enum.all?(map, fn {key, value} ->
          assignment_id?(key) and generation?(value)
        end)

  defp generations?(_), do: false

  defp timestamp?(s, now) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, value, 0} ->
        value.year >= 2000 and elem(value.microsecond, 1) == 6 and
          DateTime.diff(value, now, :microsecond) <= 2_000_000

      _ ->
        false
    end
  end

  defp timestamp?(_, _), do: false

  defp ordered?(a, b) do
    with {:ok, ta, _} <- DateTime.from_iso8601(a),
         {:ok, tb, _} <- DateTime.from_iso8601(b),
         do: DateTime.compare(ta, tb) != :gt
  end

  # Ecto also casts any raw 16-byte binary, which is not a textual wire UUID.
  defp uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp uuid?(_), do: false
  def assignment_id?(value), do: uuid?(value)
  defp generation?(value), do: is_integer(value) and value in 1..2_147_483_647
  defp positive?(value), do: is_integer(value) and value > 0 and value < 9_223_372_036_854_775_807
  defp text?(nil, _, allow_nil), do: allow_nil
  defp text?(value, max, _) when is_binary(value), do: byte_size(value) <= max
  defp text?(_, _, _), do: false
  defp validate(true), do: :ok
  defp validate(_), do: invalid()

  defp invalid,
    do:
      {:error,
       {:invalid, "Malformed or unsupported protocol payload (v1, bounded fields required)."}}
end

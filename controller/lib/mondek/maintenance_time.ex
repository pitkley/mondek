# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceTime do
  @moduledoc "Explicit civil-time interpretation for one-off maintenance windows."

  @doc "Resolve a local clock reading, requiring a choice when daylight saving repeats it."
  def resolve(local, zone, fold \\ "reject") do
    if fold in ["reject", "earlier", "later"] do
      case inspect_local(local, zone) do
        {:ok, datetime} ->
          resolved(datetime)

        {:ambiguous, first, _second} when fold == "earlier" ->
          resolved(first)

        {:ambiguous, _first, second} when fold == "later" ->
          resolved(second)

        {:ambiguous, first, second} ->
          invalid(
            "This time occurs twice in #{zone}. Choose the earlier occurrence (#{label(first)}) or the later occurrence (#{label(second)})."
          )

        {:gap, before_gap, after_gap} ->
          invalid(
            "This time does not exist in #{zone} because the clock moves forward. Choose a time before #{local_boundary(before_gap)} or at or after #{local_boundary(after_gap)}."
          )

        error ->
          error
      end
    else
      invalid("Choose an earlier or later occurrence only when a local time occurs twice.")
    end
  end

  @doc "Return ambiguity candidates for a form, without silently selecting an offset."
  def choices(local, zone) do
    case inspect_local(local, zone) do
      {:ambiguous, first, second} ->
        [
          %{"value" => "earlier", "label" => "Earlier — #{label(first)}"},
          %{"value" => "later", "label" => "Later — #{label(second)}"}
        ]

      _ ->
        []
    end
  end

  def inspect_local(local, zone)
      when is_binary(local) and byte_size(local) in 16..32 and is_binary(zone) and
             byte_size(zone) in 1..100 do
    local = if byte_size(local) == 16, do: local <> ":00", else: local

    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?$/, local),
         {:ok, naive} <- NaiveDateTime.from_iso8601(local),
         true <- naive.year in 1..9999 do
      case DateTime.from_naive(naive, canonical_zone(zone), Tz.TimeZoneDatabase) do
        {:error, _} -> invalid("Choose a valid IANA timezone, such as Europe/Berlin, or UTC.")
        result -> result
      end
    else
      _ -> invalid("Enter a valid local date and time, with a year from 0001 through 9999.")
    end
  rescue
    ArgumentError -> invalid("Enter a supported date and IANA timezone.")
  end

  def inspect_local(_, _), do: invalid("Enter a local date, time and explicit timezone.")

  @doc "Render a saved instant as the original timezone's local clock reading."
  def local(%DateTime{} = instant, zone) do
    case DateTime.shift_zone(instant, canonical_zone(zone), Tz.TimeZoneDatabase) do
      {:ok, datetime} -> datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
      _ -> nil
    end
  end

  def local(instant, zone) when is_binary(instant) do
    case DateTime.from_iso8601(instant) do
      {:ok, datetime, _} -> local(datetime, zone)
      _ -> nil
    end
  end

  def local(_, _), do: nil

  @doc "Recover the explicit occurrence of a saved instant when reopening an editor."
  def fold(%DateTime{} = instant, zone) do
    case inspect_local(local(instant, zone), zone) do
      {:ambiguous, first, _second} ->
        if DateTime.compare(instant, first) == :eq, do: "earlier", else: "later"

      _ ->
        "reject"
    end
  end

  def version, do: Tz.iana_version()

  defp resolved(datetime) do
    result = utc(datetime)

    if result.year in 1..9999,
      do: {:ok, result},
      else: invalid("The resolved UTC time must have a year from 0001 through 9999.")
  end

  defp utc(datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")
  defp canonical_zone("UTC"), do: "Etc/UTC"
  defp canonical_zone(zone), do: zone

  defp label(datetime),
    do: "#{DateTime.to_iso8601(datetime)} / #{DateTime.to_iso8601(utc(datetime))}"

  defp local_boundary(datetime), do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  defp invalid(message), do: {:error, {:invalid, message}}
end

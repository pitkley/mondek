# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceRecurrence do
  @moduledoc "Bounded weekly civil-time expansion before maintenance authority is saved."
  alias Mondek.MaintenanceTime

  @fields ~w(frequency interval end_mode count until_date)
  @limit 52
  @initial_open_count 8

  @doc "Resolve every proposed window without consulting the clock or changing persistence."
  def expand(proposal, recurrence) when is_map(proposal) and is_map(recurrence) do
    with {:ok, rule} <- normalize(recurrence),
         :ok <- scheduled(proposal),
         {:ok, first_start} <- naive(proposal["starts_local"]),
         {:ok, first_end} <- naive(proposal["ends_local"]),
         {:ok, count} <- count(rule, NaiveDateTime.to_date(first_start)),
         {:ok, windows} <- windows(proposal, rule, count, first_start, first_end) do
      {:ok,
       %{
         "recurrence" => rule,
         "windows" => windows,
         "timezone_version" => MaintenanceTime.version()
       }}
    end
  rescue
    ArgumentError ->
      invalid("Every repeated date and resolved UTC instant must fit years 0001–9999.")
  end

  def expand(_, _), do: invalid("Supply the first window and a bounded weekly repeat rule.")

  @doc "Find the still-relevant part of an open rule and resolve a bounded batch."
  def extend(proposal, next_index, previous_end, at) do
    rule = proposal["recurrence"]
    {:ok, first_start} = naive(proposal["starts_local"])
    {:ok, first_end} = naive(proposal["ends_local"])

    case at |> MaintenanceTime.local(proposal["timezone"]) |> naive() do
      {:ok, local_now} ->
        days = Date.diff(NaiveDateTime.to_date(local_now), NaiveDateTime.to_date(first_start))
        latest_slot = max(1, div(days, 7 * rule["interval"]) + 1)
        first = max(next_index, latest_slot - 1)
        last = latest_slot + @initial_open_count
        generate(first, last, proposal, rule, first_start, first_end, previous_end, at, [])

      _ ->
        {[], next_index, previous_end, "Window #{next_index}: the saved timezone is unavailable."}
    end
  end

  defp generate(index, last, _, _, _, _, previous_end, _, rows) when index > last,
    do: {Enum.reverse(rows), index, previous_end, nil}

  defp generate(index, last, proposal, rule, first_start, first_end, previous_end, at, rows) do
    if index <= last - @initial_open_count and expired?(first_end, rule, index, proposal, at) do
      generate(index + 1, last, proposal, rule, first_start, first_end, previous_end, at, rows)
    else
      generate_window(index, last, proposal, rule, first_start, first_end, previous_end, at, rows)
    end
  end

  defp generate_window(
         index,
         last,
         proposal,
         rule,
         first_start,
         first_end,
         previous_end,
         at,
         rows
       ) do
    case resolve_window(proposal, rule, first_start, first_end, index, previous_end) do
      {:ok, row, ends_at} ->
        rows = if DateTime.after?(ends_at, at), do: [row | rows], else: rows
        generate(index + 1, last, proposal, rule, first_start, first_end, ends_at, at, rows)

      {:error, {:invalid, message}} ->
        {Enum.reverse(rows), index, previous_end, message}
    end
  end

  defp expired?(first_end, rule, index, proposal, at) do
    local_end = shift(first_end, (index - 1) * 7 * rule["interval"])
    fold = proposal["end_fold"]

    case MaintenanceTime.inspect_local(local_end, proposal["timezone"]) do
      {:ok, instant} -> not DateTime.after?(instant, at)
      {:ambiguous, first, _} when fold == "earlier" -> not DateTime.after?(first, at)
      {:ambiguous, _, last} -> not DateTime.after?(last, at)
      {:gap, _, boundary} -> not DateTime.after?(boundary, at)
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp normalize(rule) do
    rule =
      rule
      |> Map.put_new("frequency", "weekly")
      |> Map.put_new("interval", 1)
      |> Map.put_new("end_mode", "count")
      |> Map.put_new("count", nil)
      |> Map.put_new("until_date", nil)

    cond do
      Enum.any?(Map.keys(rule), &(&1 not in @fields)) ->
        invalid("Submit only the weekly repeat fields.")

      rule["frequency"] != "weekly" or not is_integer(rule["interval"]) or
          rule["interval"] not in 1..12 ->
        invalid("Choose a weekly repeat interval from 1 through 12 weeks.")

      rule["end_mode"] == "count" and is_integer(rule["count"]) and
        rule["count"] in 2..@limit and is_nil(rule["until_date"]) ->
        {:ok, rule}

      rule["end_mode"] == "date" and is_nil(rule["count"]) ->
        case end_date(rule["until_date"]) do
          {:ok, _} -> {:ok, rule}
          error -> error
        end

      rule["end_mode"] == "open" and is_nil(rule["count"]) and is_nil(rule["until_date"]) ->
        {:ok, rule}

      true ->
        invalid(
          "End the schedule after 2–#{@limit} windows, on an inclusive last-start date, or when canceled."
        )
    end
  end

  defp scheduled(%{"start_mode" => "scheduled"}), do: :ok
  defp scheduled(_), do: invalid("Choose a scheduled first start for repeating maintenance.")

  defp naive(local) when is_binary(local) and byte_size(local) in 16..32 do
    local = if byte_size(local) == 16, do: local <> ":00", else: local

    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?$/, local),
         {:ok, value} <- NaiveDateTime.from_iso8601(local),
         true <- value.year in 1..9999 do
      {:ok, value}
    else
      _ -> invalid("Enter a valid first-window local date and time within years 0001–9999.")
    end
  end

  defp naive(_), do: invalid("Enter the first window's local start and end date and time.")

  defp end_date(date) when is_binary(date) and byte_size(date) == 10 do
    with {:ok, value} <- Date.from_iso8601(date), true <- value.year in 1..9999 do
      {:ok, value}
    else
      _ -> invalid("Enter a valid inclusive last-start date within years 0001–9999.")
    end
  end

  defp end_date(_), do: invalid("Enter the inclusive last-start date as YYYY-MM-DD.")

  defp count(%{"end_mode" => "count", "count" => count}, _), do: {:ok, count}
  defp count(%{"end_mode" => "open"}, _), do: {:ok, @initial_open_count}

  defp count(rule, first_date) do
    {:ok, until_date} = end_date(rule["until_date"])
    days = Date.diff(until_date, first_date)
    count = if days < 0, do: 0, else: div(days, 7 * rule["interval"]) + 1

    if count in 2..@limit,
      do: {:ok, count},
      else:
        invalid(
          "The inclusive last-start date must produce 2–#{@limit} windows. No dates are silently truncated."
        )
  end

  defp windows(proposal, rule, count, first_start, first_end) do
    Enum.reduce_while(1..count, {:ok, [], nil}, fn index, {:ok, previous, previous_end} ->
      case resolve_window(proposal, rule, first_start, first_end, index, previous_end) do
        {:ok, row, end_at} -> {:cont, {:ok, [row | previous], end_at}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp resolve_window(proposal, rule, first_start, first_end, index, previous_end) do
    # Calendar weeks preserve both local endpoints, including an overnight end.
    days = (index - 1) * 7 * rule["interval"]
    starts = shift(first_start, days)
    ends = shift(first_end, days)

    with {:ok, start_at} <- resolve(starts, proposal, "start_fold", index, "start"),
         {:ok, end_at} <- resolve(ends, proposal, "end_fold", index, "end"),
         :ok <- positive_duration(start_at, end_at, index, starts),
         :ok <- independent_window(start_at, previous_end, index, starts) do
      {:ok,
       %{
         "index" => index,
         "starts_local" => starts,
         "ends_local" => ends,
         "starts_at" => DateTime.to_iso8601(start_at),
         "ends_at" => DateTime.to_iso8601(end_at),
         "elapsed_seconds" => DateTime.diff(end_at, start_at, :microsecond) / 1_000_000,
         "touches_previous" =>
           not is_nil(previous_end) and DateTime.compare(start_at, previous_end) == :eq
       }, end_at}
    end
  rescue
    ArgumentError ->
      invalid("Window #{index}: repeated dates and UTC instants must fit years 0001–9999.")
  end

  defp shift(value, days) do
    date = Date.add(NaiveDateTime.to_date(value), days)

    if date.year not in 1..9999,
      do: raise(ArgumentError, "repeated date exceeds supported year")

    date |> NaiveDateTime.new!(NaiveDateTime.to_time(value)) |> NaiveDateTime.to_iso8601()
  end

  defp resolve(local, proposal, fold, index, endpoint) do
    case MaintenanceTime.resolve(local, proposal["timezone"], proposal[fold]) do
      {:ok, instant} ->
        # Match persisted utc_datetime_usec spelling before the review is signed.
        {:ok, %{instant | microsecond: {elem(instant.microsecond, 0), 6}}}

      {:error, {:invalid, message}} ->
        invalid("Window #{index} #{endpoint} (#{local}): #{message}")
    end
  end

  defp positive_duration(start_at, end_at, index, local) do
    if DateTime.compare(end_at, start_at) == :gt,
      do: :ok,
      else: invalid("Window #{index} (#{local}) must end after its resolved start.")
  end

  defp independent_window(_, nil, _, _), do: :ok

  defp independent_window(start_at, prior_end, index, local) do
    if DateTime.compare(start_at, prior_end) == :lt,
      do:
        invalid(
          "Window #{index} (#{local}) overlaps window #{index - 1}. Shorten each window or increase the repeat interval."
        ),
      else: :ok
  end

  defp invalid(message), do: {:error, {:invalid, message}}
end

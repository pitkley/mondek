# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.OutputSustain do
  @moduledoc "Qualifies severity from newly admitted evidence for one output stream."

  alias Mondek.Monitoring

  def reduce(stream, state, measured?, observation, seconds, freshness, at) do
    cond do
      seconds == 0 and measured? ->
        {%{}, state["health"]}

      seconds == 0 ->
        {state_without_candidates(stream.sustain), nil}

      true ->
        qualify(stream, state, measured?, observation, seconds, freshness, at)
    end
  end

  def public(%{sustain: sustain} = stream, assignment, runner, at) when map_size(sustain) > 0 do
    pending =
      if is_nil(stream.retired_at) and is_nil(assignment.retired_at) and not is_nil(runner) and
           sustain["session_id"] == runner.session_id and
           sustain["generation"] == assignment.authorized_generation and
           unexpired?(sustain["previous"], at) do
        for {key, health} <- [{"warn", "WARN"}, {"crit", "CRIT"}], candidate = sustain[key] do
          %{
            "health" => health,
            "first_observation_id" => candidate["observation_id"],
            "started_at" => candidate["received_at"]
          }
        end
      else
        []
      end

    sustain
    |> Map.take(~w(duration_seconds effective_health effective_observation_id))
    |> Map.put("pending", pending)
  end

  def public(_, _, _, _), do: nil

  defp qualify(stream, state, measured?, observation, seconds, freshness, at) do
    previous = stream.sustain

    qualification =
      if map_size(previous) == 0 do
        current = stream.current
        observation_id = Monitoring.confirmed_evidence(current)["confirmed_observation_id"]

        %{
          "effective_health" => if(observation_id, do: current["health"]),
          "effective_observation_id" => observation_id
        }
      else
        state_without_candidates(previous)
      end

    qualification =
      Map.merge(qualification, %{
        "duration_seconds" => seconds,
        "generation" => observation.generation,
        "session_id" => observation.session_id
      })

    if measured? do
      if Monitoring.severity(state["health"]) <=
           Monitoring.severity(qualification["effective_health"]) or
           state["health"] == "OK" do
        support(qualification, state["health"], observation)
      else
        qualify_failure(previous, qualification, state, observation, freshness, at)
      end
    else
      {qualification, nil}
    end
  end

  defp qualify_failure(previous, qualification, state, observation, freshness, at) do
    source = Monitoring.parse!(state["source_at"])

    sample = %{
      "observation_id" => observation.id,
      "source_at" => Monitoring.iso(source),
      "received_at" => Monitoring.iso(at),
      "expires_at" =>
        source
        |> DateTime.add(ceil(freshness * 1_000_000), :microsecond)
        |> Monitoring.iso()
    }

    continuing? =
      Map.take(previous, ~w(duration_seconds session_id generation)) ==
        Map.take(qualification, ~w(duration_seconds session_id generation)) and
        advances?(previous["previous"], source, at)

    warn =
      if Monitoring.severity(qualification["effective_health"]) < Monitoring.severity("WARN"),
        do: start(previous["warn"], continuing?, sample)

    crit = if state["health"] == "CRIT", do: start(previous["crit"], continuing?, sample)

    duration = qualification["duration_seconds"] * 1_000_000

    cond do
      reached?(crit, source, at, duration) ->
        support(qualification, "CRIT", observation)

      reached?(warn, source, at, duration) ->
        {qualification, health} = support(qualification, "WARN", observation)
        {pending(qualification, nil, crit, sample), health}

      true ->
        {pending(qualification, warn, crit, sample), nil}
    end
  end

  defp advances?(previous, source, at) do
    unexpired?(previous, at) and
      DateTime.after?(source, Monitoring.parse!(previous["source_at"])) and
      not DateTime.before?(at, Monitoring.parse!(previous["received_at"]))
  end

  defp unexpired?(nil, _), do: false
  defp unexpired?(sample, at), do: DateTime.before?(at, Monitoring.parse!(sample["expires_at"]))

  defp start(previous, true, sample), do: previous || sample
  defp start(_, false, sample), do: sample

  defp reached?(nil, _, _, _), do: false

  defp reached?(candidate, source, at, duration) do
    DateTime.diff(source, Monitoring.parse!(candidate["source_at"]), :microsecond) >= duration and
      DateTime.diff(at, Monitoring.parse!(candidate["received_at"]), :microsecond) >= duration
  end

  defp support(qualification, health, observation) do
    {Map.merge(qualification, %{
       "effective_health" => health,
       "effective_observation_id" => observation.id
     }), health}
  end

  defp pending(qualification, nil, nil, _), do: qualification

  defp pending(qualification, warn, crit, sample),
    do: Map.merge(qualification, %{"warn" => warn, "crit" => crit, "previous" => sample})

  defp state_without_candidates(sustain), do: Map.drop(sustain, ~w(warn crit previous))
end

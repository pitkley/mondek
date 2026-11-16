# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.AgentInspection do
  @moduledoc "MCP adapter over the neutral investigation context."
  alias Mondek.{Investigation, Monitoring}

  def call(name, args, at \\ Monitoring.now()) do
    result = Investigation.read(fn -> dispatch(name, args, at) end)

    case result do
      {:ok, data} ->
        {:ok, Map.merge(data, %{"schema_version" => 1, "as_of" => Monitoring.iso(at)})}

      {:error, :not_found} ->
        {:error, "Not found or no longer retained."}

      {:error, _} ->
        {:error, "Investigation unavailable."}
    end
  end

  defp dispatch("list_correlation_candidates", args, at),
    do: Mondek.Correlations.candidates(args, at)

  defp dispatch("list_cases", args, _at), do: Mondek.Correlations.list(args)
  defp dispatch("get_case", args, _at), do: Mondek.Correlations.detail(args["case_id"], args)
  defp dispatch("list_attention", args, at), do: Investigation.attention(args, at)
  defp dispatch("get_check_context", args, at), do: Investigation.assignment(args, at)
  defp dispatch("get_evidence", args, at), do: Investigation.evidence(args, at)
  defp dispatch("get_incident", args, at), do: Investigation.incident(args, at)
end

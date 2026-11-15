# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.IncidentPresentation do
  @moduledoc "Shared plain-text incident identity for HTTP and operator surfaces."
  alias Mondek.Monitoring

  def health(row, at, assignment \\ nil, stream \\ nil) do
    grouped? =
      row["incident_kind"] == "condition" or row["incident_type"] == "condition" or
        Map.has_key?(row, "namespace")

    assignment = assignment || %{}
    stream = stream || %{}

    row
    |> Map.merge(%{
      "check_label" => if(grouped?, do: nil, else: row["check_label"] || assignment["label"]),
      "result_label" => if(grouped?, do: nil, else: row["result_label"] || stream["label"]),
      "environment_label" =>
        stream["environment_label"] || assignment["environment_label"] || row["environment_label"] ||
          row["environment"],
      "runner_label" =>
        if(grouped?,
          do: nil,
          else: row["runner_label"] || stream["runner_label"] || assignment["runner_label"]
        ),
      "runner_id" => if(grouped?, do: nil, else: row["runner_id"] || assignment["runner_id"]),
      "source_id" => row["source_id"] || assignment["source_id"],
      "target" => row["target"] || stream["target"],
      "acknowledgement_active" => Monitoring.acknowledgement_active?(row, at)
    })
    |> with_title()
  end

  def loss(row, at, runner_label \\ nil) do
    row
    |> Map.merge(%{
      "check_label" => nil,
      "result_label" => nil,
      "environment_label" => nil,
      "runner_label" => runner_label,
      "acknowledgement_active" => Monitoring.acknowledgement_active?(row, at)
    })
    |> with_title()
  end

  def title(%{"scope_kind" => "coverage"}), do: "No runner selected"
  def title(%{"scope_kind" => _} = row), do: row["label"] || "Measurements missing"

  def title(row) do
    labels =
      [row["check_label"], row["result_label"]] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

    case labels do
      [] -> row["label"] || "Health incident"
      _ -> Enum.join(labels, " — ")
    end
  end

  defp with_title(row), do: Map.put(row, "display_title", title(row))
end

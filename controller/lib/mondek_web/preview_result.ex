# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewResult do
  @moduledoc "Bounded result evidence shared by preview investigation hosts."
  alias Mondek.{Inspection, Monitoring}

  def load(id, now) do
    if observers = Inspection.overview_observers(id, now) do
      inspection = Monitoring.stream_inspection(id, now)
      stream = inspection["stream"]

      Map.merge(observers, %{
        kind: :result,
        inspection: inspection,
        confirmed_configuration:
          Inspection.confirmed_configuration(
            stream["assignment_id"],
            get_in(stream, ["current", "confirmed_generation"])
          ),
        maintenance_windows: Mondek.Maintenance.for_stream(id, now),
        discovery: Mondek.Discovery.inspect(id, now),
        diagnostic_runner: Mondek.RunnerFleet.detail(observers.selected["runner_id"], now),
        discovery_settings:
          Mondek.DiscoveryConfiguration.context(observers.selected["assignment_id"])
      })
    end
  end
end

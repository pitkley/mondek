# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewResult do
  @moduledoc "Bounded result evidence shared by preview investigation hosts."
  alias Mondek.{Inspection, Monitoring}

  def load(id, now) do
    if observers = Inspection.overview_observers(id, now) do
      Map.merge(observers, %{kind: :result, inspection: Monitoring.stream_inspection(id, now)})
    end
  end
end

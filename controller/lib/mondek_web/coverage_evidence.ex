# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CoverageEvidence do
  @moduledoc "Bounded declared-result and unresolved-declaration evidence for every investigation host."
  alias Mondek.Coverage

  def load("coverage", id, now, page \\ nil) do
    if scope = Coverage.scope(id, now) do
      %{kind: :coverage, scope: scope, observers: Coverage.observers(id, %{"page" => page}, now)}
    end
  end

  def diagnostic(id, now) do
    if item = Coverage.diagnostic(id, now), do: %{kind: :diagnostic, item: item}
  end
end

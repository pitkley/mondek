# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.TargetContextLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}
  @endpoint MondekWeb.Endpoint

  test "composed source environment and target chips keep exact observations independent" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    publish(first, "context.source", [
      check("failing"),
      check("other-env", "staging"),
      check("other-kind", "production", "service")
    ])

    publish(second, "context.source", [check("healthy")])
    publish(Ecto.UUID.generate(), "another.source", [check("other-source")])
    measured("failing", "CRIT")
    measured("healthy", "OK")

    path =
      "/checks?source_id=context.source&environment=production&target_kind=host&target_key=host-a"

    {:ok, view, _} = live(build_conn(), path)
    assert rows(view) == 2
    assert has_element?(view, "#preview-check-results", "Critical")
    assert has_element?(view, "#preview-check-results", "Healthy")
    refute has_element?(view, "#preview-check-results", "other-source")
    refute has_element?(view, "#preview-check-results", "other-env")
    refute has_element?(view, "#preview-check-results", "other-kind")
  end

  test "empty or withdrawn scope never silently selects another result" do
    runner = Ecto.UUID.generate()
    publish(runner, "context.source", [check("removed")])
    publish(Ecto.UUID.generate(), "other.source", [check("other")])

    path =
      "/checks?source_id=context.source&environment=production&target_kind=host&target_key=host-a"

    {:ok, view, _} = live(build_conn(), path)
    assert rows(view) == 1
    publish(runner, "context.source", [], 2)
    send(view.pid, :tick)
    assert rows(view) == 0
    assert has_element?(view, ".preview-empty", "No check results match")
    refute has_element?(view, "#preview-check-results", "other")
  end

  test "invalid compound target input is discarded rather than interpreted as another exact target" do
    assert Mondek.ChecksFilters.params(%{"target_key" => "host-a"}) == %{}
    assert Mondek.ChecksFilters.params(%{"target_kind" => "host"}) == %{}

    assert Mondek.ChecksFilters.params(%{
             "target_kind" => %{"x" => "host"},
             "target_key" => "host-a"
           }) == %{}

    refute MondekWeb.BrowserNavigation.return_path("https://other.invalid/checks")

    path =
      "/checks?source_id=context.source&target_kind=host&target_key=host-a&return_to=%2Fchecks"

    assert MondekWeb.BrowserNavigation.return_path(path) ==
             "/checks?return_to=%2Fchecks&source_id=context.source&target_key=host-a&target_kind=host"
  end

  test "an unscoped direct result does not invent a filtered origin" do
    publish(Ecto.UUID.generate(), "context.source", [check("one")])

    stream =
      Repo.one!(
        from s in ResultStream,
          join: a in Assignment,
          on: a.id == s.assignment_id,
          where: a.source_id == "context.source"
      )

    {:ok, view, _} = live(build_conn(), "/results/#{stream.id}/full")
    assert has_element?(view, "#full-result-heading", "one")
    assert has_element?(view, "a[href='/']")
    refute has_element?(view, ".preview-filter-chip")
  end

  defp rows(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#preview-check-results tbody > tr")
      |> Enum.count()

  defp measured(key, health) do
    assignment =
      Repo.one!(
        from a in Assignment, where: a.source_id == "context.source" and a.source_key == ^key
      )

    stream = Repo.one!(from s in ResultStream, where: s.assignment_id == ^assignment.id)
    runner = Repo.get!(Mondek.Runner, assignment.runner_id)

    current = %{
      "health" => health,
      "knowledge" => "fresh",
      "summary" => key,
      "generation" => 1,
      "session_id" => runner.session_id,
      "source_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "confirmed_observation_id" => Ecto.UUID.generate(),
      "confirmed_generation" => 1
    }

    Repo.update_all(from(s in ResultStream, where: s.id == ^stream.id), set: [current: current])
  end

  defp publish(runner, source, checks, revision \\ 1) do
    existing = Repo.get(Mondek.Runner, runner)
    session = if existing, do: existing.session_id, else: Ecto.UUID.generate()

    assert {:ok, _} =
             Inventory.reconcile(
               control(%{
                 "installation_id" => runner,
                 "session_id" => session,
                 "runner_label" => "Context observer",
                 "source_id" => source,
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => revision,
                 "complete" => true,
                 "checks" => checks
               }),
               DateTime.utc_now()
             )
  end

  defp check(key, environment \\ "production", kind \\ "host") do
    %{
      "key" => key,
      "label" => key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => environment,
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" => [
        %{
          "key" => key,
          "label" => key <> " result",
          "target" => %{"key" => "host-a", "kind" => kind, "label" => "Same label"}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60
    }
  end
end

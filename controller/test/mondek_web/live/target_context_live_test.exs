# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.TargetContextLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}
  alias MondekWeb.CheckInventory
  @endpoint MondekWeb.Endpoint

  test "a filtered problem expands exact target observations and preserves its investigation" do
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

    filters =
      CheckInventory.normalize(%{
        "search" => "failing",
        "runner_id" => first,
        "tab" => "critical",
        "view" => "list",
        "critical_view" => "list",
        "page_size" => "10",
        "page" => "1",
        "target_page" => "2",
        "return_to" => "/runners/" <> first
      })

    original = CheckInventory.path(filters)
    {:ok, view, _} = live(build_conn(), original)
    assert count(view, ".checks-result-link") == 1
    view |> element(".target-context-link") |> render_click()
    context = assert_patch(view)
    assert has_element?(view, "#checks-target-context", "same source")
    assert has_element?(view, "#checks-investigation-return[href='#{original}']")
    assert count(view, ".checks-result-link") == 2
    assert has_element?(view, ".badge.crit")
    assert has_element?(view, ".badge.ok")
    refute has_element?(view, ".checks-result-link", "other-env")
    refute has_element?(view, ".checks-result-link", "other-kind")
    refute has_element?(view, ".checks-result-link", "other-source")
    {:ok, reloaded, _} = live(build_conn(), context)
    assert has_element?(reloaded, "#checks-investigation-return[href='#{original}']")
    detail_navigation = reloaded |> element(".checks-result-link", "failing") |> render_click()
    {:ok, detail, _} = follow_redirect(detail_navigation, build_conn())
    assert has_element?(detail, ".back[href='#{context}']")
    assert has_element?(detail, "#result-target-context")

    {:ok, reloaded, _} = live(build_conn(), context)

    reloaded
    |> element("button[phx-click='checks_view'][phx-value-view='targets']")
    |> render_click()

    assert has_element?(reloaded, "#checks-target-context")
    assert count(reloaded, ".checks-result-link") == 2
    reloaded |> element("#inventory-tab-critical") |> render_click()
    assert count(reloaded, ".checks-result-link") == 1
    assert has_element?(reloaded, "#checks-investigation-return[href='#{original}']")
  end

  test "empty and withdrawn target context never falls back to another target" do
    runner = Ecto.UUID.generate()

    publish(runner, "context.source", [
      check("one"),
      put_in(check("unrelated"), ["outputs", Access.at(0), "target", "key"], "other")
    ])

    group = Monitoring.list_grouped_streams(%{"search" => "one"})[:groups] |> hd()

    path =
      CheckInventory.target_context_path(
        group["id"],
        CheckInventory.normalize(%{"search" => "one"})
      )

    {:ok, view, _} = live(build_conn(), path)
    view |> form("#inventory-filters", search: "not-found") |> render_change()
    assert has_element?(view, "#checks-target-context", "Same label")
    assert has_element?(view, "#checks-target-context", "Host ID host-a")
    assert has_element?(view, "#check-inventory", "No matching results")
    assert count(view, ".checks-result-link") == 0
    view |> element("button[phx-click='clear_checks_all']") |> render_click()
    assert count(view, ".checks-result-link") == 1

    publish(
      runner,
      "context.source",
      [put_in(check("unrelated"), ["outputs", Access.at(0), "target", "key"], "other")],
      2
    )

    send(view.pid, :tick)
    assert has_element?(view, "#checks-target-context", "No results match")
    assert count(view, ".checks-result-link") == 0
  end

  test "context return is bounded local and nonrecursive while malformed scope stays scoped" do
    assert CheckInventory.investigation_return("https://evil.example/checks") == nil
    assert CheckInventory.investigation_return("//evil.example/checks") == nil
    assert CheckInventory.investigation_return("/checks?investigation_return=%2Fchecks") == nil
    assert CheckInventory.investigation_return("/checks?target_scope=target-invalid") == nil

    assert CheckInventory.investigation_return("/checks?search=" <> String.duplicate("x", 4096)) ==
             nil

    scope = String.duplicate("x", 300)

    {:ok, view, _} =
      live(
        build_conn(),
        "/checks?target_scope=" <>
          scope <> "&investigation_return=https%3A%2F%2Fevil.example%2Fchecks"
      )

    assert has_element?(view, "#checks-target-context")
    refute has_element?(view, "#checks-investigation-return")
    assert count(view, ".checks-result-link") == 0
  end

  test "detail outside inventory does not invent a filtered investigation origin" do
    publish(Ecto.UUID.generate(), "context.source", [check("direct")])

    stream =
      Repo.one!(
        from s in ResultStream,
          join: a in Assignment,
          on: a.id == s.assignment_id,
          where: a.source_id == "context.source"
      )

    {:ok, detail, _} = live(build_conn(), "/checks/#{stream.id}?return_to=%2F")
    navigation = detail |> element("#result-target-context") |> render_click()
    {:ok, context, _} = follow_redirect(navigation, build_conn())
    assert has_element?(context, "#checks-target-context", "Same label")
    refute has_element?(context, "#checks-investigation-return")
    assert has_element?(context, "#checks-leave-target")
    {:ok, unscoped, _} = live(build_conn(), "/checks?target_scope=")
    refute has_element?(unscoped, "#checks-target-context")
  end

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

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

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GroupedInventoryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "exact target filtering distinguishes environment kind and source across observers" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    publish(first, "grouped.source", [
      check("local", "host-a"),
      check("different-host", "host-b"),
      check("different-env", "host-a", "staging"),
      check("website", "host-a", "production", "website")
    ])

    publish(second, "grouped.source", [check("remote", "host-a")])
    publish(Ecto.UUID.generate(), "other.source", [check("different-source", "host-a")])
    {:ok, view, _} = live(build_conn(), scoped())

    assert rows(view) |> Enum.sort() ==
             Enum.map(["local", "remote"], &("result-row-" <> stream(&1).id)) |> Enum.sort()

    assert has_element?(view, "#preview-check-results", "Not measured")

    for runner <- [first, second] do
      assert has_element?(view, ".preview-result-context", runner)
    end
  end

  test "complete matching set is paged before rendering and panel return keeps that page" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..67, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} = live(build_conn(), scoped())
    assert length(rows(view)) == 30
    assert has_element?(view, "nav[aria-label='Check results']", "67")
    view |> element("nav[aria-label='Check results'] a[aria-label='Page 2']") |> render_click()
    page = assert_patch(view)
    assert length(rows(view)) == 30

    view
    |> element("#preview-check-results tbody tr:first-child a[data-overview-open]")
    |> render_click()

    panel = assert_patch(view)
    assert has_element?(view, "#overview-panel")
    {:ok, reopened, _} = live(build_conn(), panel)
    assert rows(reopened) == rows(view)
    assert URI.decode_query(URI.parse(page).query)["page"] == "2"
  end

  test "visible runners remain distinct beyond the bounded picker choices" do
    for _ <- 1..100 do
      Repo.insert!(%Mondek.Runner{
        id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        boot: 1,
        last_seen_at: DateTime.utc_now(),
        label: "A prior observer"
      })
    end

    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    publish(first, "grouped.source", [check("local", "host-a")])
    publish(second, "grouped.source", [check("remote", "host-a")])
    {:ok, view, _} = live(build_conn(), scoped())

    for runner <- [first, second],
        do: assert(has_element?(view, ".preview-result-context", runner))

    assert length(Mondek.ChecksFilters.options("runner_id", "")) <= 20
  end

  test "equivalent search recovery and ticks preserve a bookmarked result page" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..67, do: check(padded(index), "host-a"))
    )

    path = scoped() <> "&page=2&search=grouped-"
    {:ok, view, _} = live(build_conn(), path)
    before = rows(view)
    render_change(view, "search", %{"search" => "grouped-"})
    refute_patched(view)
    send(view.pid, :tick)
    assert rows(view) == before
    {:ok, recovered, _} = live(build_conn(), path)
    assert rows(recovered) == before
  end

  test "a real chip change resets paging while preserving the other exact scope chips" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..67, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} = live(build_conn(), scoped() <> "&page=2")
    render_click(view, "filter_open", %{"field" => "freshness"})
    render_click(view, "filter_select", %{"key" => "awaiting", "kind" => ""})
    query = assert_patch(view) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    refute query["page"]
    assert query["target_key"] == "host-a"
    assert query["source_id"] == "grouped.source"
    assert length(rows(view)) == 30
  end

  test "priority puts measured failures ahead of healthy rows without renewing old evidence" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(key <- ["healthy", "critical", "missing", "warning"], do: check(key, "host-a"))
    )

    measure("healthy", "OK", "fresh", "Healthy explanation")
    measure("critical", "CRIT", "stale", "First line\nSecond line")
    measure("warning", "WARN", "fresh", "Warning explanation")
    {:ok, view, _} = live(build_conn(), scoped())
    order = rows(view)

    assert Enum.find_index(order, &(&1 == "result-row-" <> stream("critical").id)) <
             Enum.find_index(order, &(&1 == "result-row-" <> stream("healthy").id))

    assert has_element?(view, "#result-row-#{stream("critical").id}", "Critical")
    assert has_element?(view, "#result-row-#{stream("critical").id}", "Overdue")

    assert has_element?(
             view,
             "#result-row-#{stream("critical").id} .preview-measurement-summary",
             "Second line"
           )

    assert has_element?(view, "#result-row-#{stream("missing").id}", "Not measured")
  end

  test "retired membership keeps historical verdict separate and is explicitly selectable" do
    runner = Ecto.UUID.generate()
    definitions = [check("removed", "host-a"), check("retained", "host-a")]
    publish(runner, "grouped.source", definitions)
    measure("removed", "CRIT", "fresh", "Historical failure")
    publish(runner, "grouped.source", [List.last(definitions)], 2)
    path = scoped() <> "&status=retired"
    {:ok, view, _} = live(build_conn(), path)
    assert rows(view) == ["result-row-" <> stream("removed").id]
    assert has_element?(view, "#preview-check-results", "Retired")
    assert has_element?(view, "#preview-check-results", "Critical")
    {:ok, reopened, _} = live(build_conn(), path)
    assert rows(reopened) == rows(view)
  end

  test "numbered pagination clamps oversized pages and keeps bounded rendering" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..67, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} = live(build_conn(), scoped() <> "&page=99999")
    assert length(rows(view)) == 7
    assert has_element?(view, "nav[aria-label='Check results'] [aria-current=page]", "3")
    assert has_element?(view, "nav[aria-label='Check results'] span[aria-disabled=true]", "Next")
  end

  test "fixed UI density does not change the independently bounded domain API page size" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..67, do: check(padded(index), "host-a"))
    )

    for size <- ["0", "8", "100", "all", "-1"] do
      {:ok, view, _} = live(build_conn(), scoped() <> "&page_size=" <> size)
      assert length(rows(view)) == 30
      GenServer.stop(view.pid)
    end

    assert Monitoring.list_grouped_streams(%{"search" => "grouped-", "page_size" => 8}).page_size ==
             8
  end

  test "empty search and clearing text preserve exact scope rather than introducing other sources" do
    publish(Ecto.UUID.generate(), "grouped.source", [check("one", "host-a")])
    publish(Ecto.UUID.generate(), "other.source", [check("other", "host-a")])
    {:ok, view, _} = live(build_conn(), scoped())
    render_change(view, "search", %{"search" => "absent"})
    assert rows(view) == []
    render_change(view, "search", %{"search" => ""})
    assert rows(view) == ["result-row-" <> stream("one").id]
  end

  defp scoped,
    do:
      "/checks?source_id=grouped.source&environment=production&target_kind=host&target_key=host-a"

  defp elements(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

  defp rows(view),
    do:
      view
      |> elements("#preview-check-results tbody > tr")
      |> Enum.map(&(LazyHTML.attribute(&1, "id") |> hd()))

  defp stream(key) do
    Repo.one!(from s in ResultStream, where: s.result_key == ^key)
  end

  defp measure(key, health, knowledge, summary) do
    stream = stream(key)
    assignment = Repo.get!(Assignment, stream.assignment_id)
    runner = Repo.get!(Mondek.Runner, assignment.runner_id)

    now =
      if knowledge == "stale",
        do: DateTime.add(DateTime.utc_now(), -120),
        else: DateTime.utc_now()

    iso = DateTime.to_iso8601(now)
    observation_id = Ecto.UUID.generate()
    Monitoring.change(assignment, %{authorized_generation: 1})

    payload =
      measurement(health, 1, %{
        "id" => observation_id,
        "assignment_id" => assignment.id,
        "installation_id" => runner.id,
        "session_id" => runner.session_id,
        "started_at" => iso,
        "evaluated_at" => iso
      })
      |> put_in(["results", Access.at(0), "key"], key)
      |> put_in(["results", Access.at(0), "source_at"], iso)
      |> put_in(["results", Access.at(0), "summary"], summary)

    Repo.insert!(%Observation{
      id: observation_id,
      assignment_id: assignment.id,
      installation_id: runner.id,
      session_id: runner.session_id,
      generation: 1,
      sequence: 1,
      started_at: now,
      evaluated_at: now,
      received_at: now,
      payload: payload,
      disposition: "current"
    })

    current = %{
      "health" => health,
      "knowledge" => knowledge,
      "summary" => summary,
      "generation" => 1,
      "session_id" => runner.session_id,
      "source_at" => iso,
      "confirmed_observation_id" => observation_id,
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
                 "runner_label" => "Shared services",
                 "source_id" => source,
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => revision,
                 "complete" => true,
                 "checks" => checks
               }),
               DateTime.utc_now()
             )
  end

  defp check(key, target, environment \\ "production", kind \\ "host") do
    %{
      "key" => key,
      "label" => "grouped-" <> key,
      "definition_revision" => String.duplicate("b", 64),
      "environment" => environment,
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" => [
        %{
          "key" => key,
          "label" => "grouped-" <> key <> " result",
          "target" => %{"key" => target, "kind" => kind, "label" => "Shared target name"}
        }
      ],
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 60
    }
  end

  defp padded(index), do: "check-" <> String.pad_leading(to_string(index), 3, "0")
end

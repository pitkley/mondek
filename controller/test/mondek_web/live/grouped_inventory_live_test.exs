# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.GroupedInventoryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "groups exact monitored targets across observers and keeps same-named identities distinct" do
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    publish(first, "grouped.source", [
      check("node-local", "host-a"),
      check("different-host", "host-b"),
      check("different-environment", "host-a", "staging"),
      check("website", "public-site", "production", "website")
    ])

    publish(second, "grouped.source", [check("remote-observer", "host-a")])
    publish(Ecto.UUID.generate(), "other.source", [check("different-source", "host-a")])

    {:ok, view, _} = live(build_conn(), list_path("/checks?search=grouped-"))
    assert length(elements(view, ".target-group")) == 5
    group = group_id("node-local")

    assert has_element?(view, "#{group} h3", "Shared target name")
    assert has_element?(view, "#{group} .target-group-context", "production")
    assert has_element?(view, "#{group} .target-group-context", "grouped.source")
    assert has_element?(view, "#{group} .target-group-context", "host-a")
    assert has_element?(view, "#{group} .target-group-size", "2 matching results")
    assert has_element?(view, "#{group} .target-group-size", "2 runners")
    assert length(elements(view, "#{group} .badge.not_measured")) == 2
    assert length(elements(view, "#{group} .badge.awaiting")) == 2

    for id <- [first, second] do
      assert has_element?(view, "#{group} .target-result-observer", "Shared services (#{id})")
    end

    refute has_element?(view, "#{group}", "different-host")
    refute has_element?(view, "#{group}", "different-environment")
    refute has_element?(view, "#{group}", "different-source")
    assert has_element?(view, "#{group_id("website")} .target-kind", "Website")
    refute has_element?(view, "#{group_id("website")} .target-group-counts")
  end

  test "keeps full filtered group summaries and explicit continuation across bounded pages" do
    runner = Ecto.UUID.generate()

    publish(runner, "grouped.source", for(index <- 1..55, do: check(padded(index), "host-a")))

    {:ok, view, _} =
      live(build_conn(), list_path("/checks?environment=production&search=grouped-"))

    assert length(elements(view, ".target-group")) == 1
    assert length(elements(view, "#check-inventory tbody tr")) == 50
    assert has_element?(view, ".target-group-size", "55 matching results")
    assert has_element?(view, ".target-group-range", "Showing results 1–50 of 55")
    assert has_element?(view, ".target-group-range", "Continues on the next page")
    refute has_element?(view, ".target-group-range", "Continued from the previous page")
    group = view |> elements(".target-group") |> hd() |> LazyHTML.attribute("id") |> hd()

    view |> element("#inventory-pagination-bottom a", "Next") |> render_click()
    assert has_element?(view, "##{group}")
    assert length(elements(view, "#check-inventory tbody tr")) == 5
    assert has_element?(view, ".target-group-range", "Showing results 51–55 of 55")
    assert has_element?(view, ".target-group-range", "Continued from the previous page")
    refute has_element?(view, ".target-group-range", "Continues on the next page")
    assert has_element?(view, ".target-group-size", "55 matching results")

    navigation = view |> element("tbody tr:first-child .checks-result-link") |> render_click()
    {:ok, detail, _} = follow_redirect(navigation, build_conn())

    return_path = list_path("/checks?environment=production&page=2&search=grouped-")
    assert has_element?(detail, ".back[href='#{return_path}']")

    {:ok, view, _} =
      live(build_conn(), list_path("/checks?environment=production&search=grouped-"))

    view
    |> form("#inventory-filters", search: "grouped-check-055", environment: "production")
    |> render_change()

    assert has_element?(view, "#check-inventory", "1 matching")
    assert has_element?(view, "##{group}")
    assert length(elements(view, "#check-inventory tbody tr")) == 1
    refute has_element?(view, ".target-group-range")
    refute has_element?(view, ".target-group-counts")
  end

  test "visible collectors beyond the runner facet limit retain distinct identities" do
    for _ <- 1..100 do
      Repo.insert!(%Mondek.Runner{
        id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        boot: 1,
        last_seen_at: at(),
        label: "A pre-existing observer"
      })
    end

    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    unique = Ecto.UUID.generate()
    publish(first, "grouped.source", [check("node-local", "host-a")])
    publish(second, "grouped.source", [check("remote-observer", "host-a")])
    publish(unique, "grouped.source", [check("unique-observer", "host-b")])
    Monitoring.change(Repo.get!(Mondek.Runner, unique), %{label: "Unique observer"})

    {:ok, view, _} = live(build_conn(), list_path("/checks?search=grouped-"))

    for id <- [first, second] do
      assert has_element?(view, ".target-result-observer", "Shared services (#{id})")
      refute has_element?(view, "#inventory-runner option[value='#{id}']")
    end

    assert has_element?(view, ".target-result-observer", "Unique observer (#{unique})")
  end

  test "equivalent recovered controls preserve page two for results, configuration and incidents" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    for stream <- Repo.all(from s in ResultStream, where: like(s.label, "grouped-%")) do
      Repo.insert!(%Incident{
        assignment_id: stream.assignment_id,
        result_key: stream.result_key,
        stream_id: stream.id,
        environment: "production",
        health: "CRIT",
        opening_generation: 1,
        opened_at: at()
      })
    end

    for {path, status, additional} <- [
          {"/checks", "active", %{"health" => "", "freshness" => ""}},
          {"/configuration", "active", %{"configuration_stage" => ""}},
          {"/incidents", "open", %{}}
        ] do
      url = path <> "?environment=production&page=2&search=grouped-"
      url = if path == "/checks", do: list_path(url), else: url
      {:ok, view, _} = live(build_conn(), url)
      assert has_element?(view, "#inventory-filters[phx-auto-recover='recover_filters']")
      assert has_element?(view, ".pagination", "Page 2 of 2")

      recovered =
        Map.merge(
          %{
            "search" => "grouped-",
            "runner_id" => "",
            "environment" => "production",
            "status" => status,
            "_target" => ["search"]
          },
          additional
        )

      render_change(view, "recover_filters", recovered)
      refute_patched(view)
      assert has_element?(view, ".pagination", "Page 2 of 2")
      assert has_element?(view, "#inventory-search[value='grouped-']")
      send(view.pid, :tick)
      assert has_element?(view, ".pagination", "Page 2 of 2")

      render_change(view, "recover_filters", Map.put(recovered, "search", "grouped-check-055"))

      expected = path <> "?environment=production&search=grouped-check-055"
      # Result search edits no longer replay the form's incidental default status.
      expected =
        if path == "/checks", do: list_path(expected), else: expected <> "&status=" <> status

      assert_patch(view, expected)

      if path == "/checks" do
        refute has_element?(view, ".pagination")
      else
        assert has_element?(view, ".pagination", "Page 1 of 1")
      end

      assert has_element?(view, "#inventory-search[value='grouped-check-055']")
    end
  end

  test "a genuine filter edit still resets the current result page" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} =
      live(build_conn(), list_path("/checks?environment=production&page=2&search=grouped-"))

    view |> form("#inventory-filters", freshness: "awaiting") |> render_change()

    assert_patch(
      view,
      list_path("/checks?environment=production&freshness=awaiting&search=grouped-&status=active")
    )

    assert has_element?(view, ".pagination", "Page 1 of 2")
    assert has_element?(view, ".target-group-range", "Showing results 1–50 of 55")
  end

  test "shows problems before healthy results without turning stale health into fresh evidence" do
    runner = Ecto.UUID.generate()

    publish(runner, "grouped.source", [
      check("healthy", "host-a"),
      check("critical", "host-a"),
      check("missing", "host-a"),
      check("warning", "host-a")
    ])

    measure("healthy", "OK", "fresh", "Healthy complete explanation")
    measure("critical", "CRIT", "stale", "First line of explanation\nSecond line remains visible")
    measure("warning", "WARN", "fresh", "Warning explanation")

    {:ok, view, _} = live(build_conn(), list_path("/checks?search=grouped-"))
    critical = stream("critical")
    warning = stream("warning")
    missing = stream("missing")
    healthy = stream("healthy")

    assert view
           |> elements("#check-inventory tbody tr")
           |> Enum.map(&LazyHTML.attribute(&1, "id")) ==
             Enum.map([critical, warning, missing, healthy], &["result-" <> &1.id])

    assert has_element?(view, "#result-#{healthy.id} .badge.ok", "Healthy")
    assert has_element?(view, "#result-#{missing.id} .badge.not_measured", "Not measured")
    assert has_element?(view, "#result-#{missing.id} .badge.awaiting", "Awaiting measurement")
    assert has_element?(view, "#result-#{warning.id} .badge.warn", "Warning")
    assert has_element?(view, "#result-#{critical.id} .badge.crit", "Critical")
    assert has_element?(view, "#result-#{critical.id} .badge.stale", "Stale")

    assert has_element?(
             view,
             "#result-#{critical.id} .target-result-summary",
             "Second line remains visible"
           )

    refute has_element?(view, "#result-#{critical.id} details")

    view |> form("#inventory-filters", health: "OK", search: "grouped-") |> render_change()
    assert has_element?(view, "#check-inventory", "1 matching")
    refute has_element?(view, "#result-#{critical.id}")
    assert has_element?(view, "#result-#{healthy.id}")
  end

  test "retired membership remains separate from last measured health and reconnect keeps filters" do
    runner = Ecto.UUID.generate()
    definitions = [check("removed", "host-a"), check("retained", "host-a")]
    publish(runner, "grouped.source", definitions)
    measure("removed", "CRIT", "fresh", "Retained critical evidence")
    publish(runner, "grouped.source", [List.last(definitions)], 2)

    path = list_path("/checks?search=grouped-&status=retired")
    {:ok, view, _} = live(build_conn(), path)
    removed = stream("removed")
    assert has_element?(view, "#result-#{removed.id} .badge.crit", "Critical")
    assert has_element?(view, "#result-#{removed.id} .badge.retired", "Retired")
    refute has_element?(view, "#check-inventory", "grouped-retained result")
    send(view.pid, :tick)
    assert has_element?(view, "#inventory-status option[selected][value='retired']")
    {:ok, reconnected, _} = live(build_conn(), path)
    assert has_element?(reconnected, "#result-#{removed.id} .badge.retired", "Retired")
    assert has_element?(reconnected, "#inventory-search[value='grouped-']")
  end

  test "a first collection failure is Not measured on both lists and overview, then preserves confirmed health" do
    connect()

    failed =
      measurement("UNKNOWN", 1, %{"complete" => false})
      |> put_in(["results", Access.at(0), "source_at"], nil)

    assert disposition(ingest(failed)) == "current"
    stream = Repo.get_by!(ResultStream, assignment_id: "10000000-0000-4000-8000-000000000001")

    for path <- [list_path("/checks"), "/"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#result-#{stream.id} .badge.not_measured", "Not measured")
      assert has_element?(view, "#result-#{stream.id} .badge.unavailable", "Unavailable")
      refute has_element?(view, "#result-#{stream.id} .badge.unknown")
    end

    {:ok, filtered, _} = live(build_conn(), list_path("/checks?health=not_measured"))
    assert has_element?(filtered, "#result-#{stream.id}")

    assert has_element?(
             filtered,
             "#inventory-health option[value='not_measured'][selected]",
             "Not measured"
           )

    refute has_element?(filtered, "#inventory-health option[value='UNKNOWN']")

    {:ok, unsupported, _} = live(build_conn(), list_path("/checks?health=UNKNOWN"))
    refute has_element?(unsupported, "#inventory-health option[value='UNKNOWN']")
    assert has_element?(unsupported, "#inventory-health option[value='']")

    confirmed = measurement("CRIT", 2)
    assert disposition(ingest(confirmed)) == "current"

    assert disposition(
             ingest(Map.merge(failed, %{"id" => Ecto.UUID.generate(), "sequence" => 3}))
           ) == "current"

    for path <- [list_path("/checks"), "/"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#result-#{stream.id} .badge.crit", "Critical")
      assert has_element?(view, "#result-#{stream.id} .badge.unavailable", "Unavailable")
      refute has_element?(view, "#result-#{stream.id} .badge.not_measured")
    end

    {:ok, unmeasured, _} = live(build_conn(), list_path("/checks?health=not_measured"))
    refute has_element?(unmeasured, "#result-#{stream.id}")

    assert Repo.get!(ResultStream, stream.id).current["confirmed_observation_id"] ==
             confirmed["id"]
  end

  test "page size changes preserve complete group scope and reset only the result page" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} =
      live(build_conn(), list_path("/checks?environment=production&page=2&search=grouped-"))

    assert has_element?(
             view,
             "#inventory-pagination-top[aria-label='Result pages, top']",
             "Page 2 of 2"
           )

    assert has_element?(
             view,
             "#inventory-pagination-bottom[aria-label='Result pages, bottom']",
             "Page 2 of 2"
           )

    assert length(elements(view, "#check-inventory [role='status']")) == 1

    assert has_element?(
             view,
             "#check-inventory[tabindex='-1'][aria-labelledby='check-inventory-heading']"
           )

    view |> form("#inventory-page-size-form", page_size: "10") |> render_change()
    assert_patch(view, list_path("/checks?environment=production&page_size=10&search=grouped-"))
    assert length(elements(view, "#check-inventory tbody tr")) == 10
    assert has_element?(view, ".target-group-size", "55 matching results")
    assert has_element?(view, ".target-group-range", "1–10 of 55")
    assert has_element?(view, "#inventory-pagination-top", "Page 1 of 6")
    view |> element("#inventory-pagination-bottom a", "Next") |> render_click()

    assert_patch(
      view,
      list_path("/checks?environment=production&page=2&page_size=10&search=grouped-")
    )

    assert has_element?(view, ".target-group-range", "11–20 of 55")

    view |> form("#inventory-page-size-form", page_size: "25") |> render_change()
    assert_patch(view, list_path("/checks?environment=production&page_size=25&search=grouped-"))
    assert length(elements(view, "#check-inventory tbody tr")) == 25
    assert has_element?(view, ".target-group-range", "1–25 of 55")
    view |> form("#inventory-page-size-form", page_size: "100") |> render_change()
    assert_patch(view, list_path("/checks?environment=production&page_size=100&search=grouped-"))
    assert length(elements(view, "#check-inventory tbody tr")) == 55
    refute has_element?(view, "#inventory-pagination-top a")
    assert has_element?(view, ".target-group-size", "55 matching results")
  end

  test "independent size and filter recovery preserve explicit and omitted-default page sizes" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    for {size, suffix, expected} <- [
          {"50", "", "Page 2 of 2"},
          {"50", "&page_size=50", "Page 2 of 2"},
          {"10", "&page_size=10", "Page 2 of 6"},
          {"25", "&page_size=25", "Page 2 of 3"}
        ] do
      {:ok, view, _} =
        live(
          build_conn(),
          list_path("/checks?environment=production&page=2&search=grouped-" <> suffix)
        )

      before =
        elements(view, "#check-inventory tbody tr") |> Enum.map(&LazyHTML.attribute(&1, "id"))

      render_change(view, "recover_page_size", %{"page_size" => size})

      render_change(view, "recover_filters", %{
        "search" => "grouped-",
        "environment" => "production",
        "runner_id" => "",
        "health" => "",
        "freshness" => "",
        "status" => "active"
      })

      refute_patched(view)
      send(view.pid, :tick)
      assert has_element?(view, "#inventory-pagination-top", expected)
      assert has_element?(view, "#inventory-page-size option[value='#{size}'][selected]")

      assert elements(view, "#check-inventory tbody tr")
             |> Enum.map(&LazyHTML.attribute(&1, "id")) == before
    end
  end

  test "filter edits and clearing filters keep the chosen page size including empty results" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    {:ok, view, _} =
      live(
        build_conn(),
        list_path("/checks?environment=production&page=2&page_size=10&search=grouped-")
      )

    view |> form("#inventory-filters", search: "absent-group") |> render_change()

    assert_patch(
      view,
      list_path("/checks?environment=production&page_size=10&search=absent-group&status=active")
    )

    assert has_element?(view, "#check-inventory", "No matching results")
    refute has_element?(view, "#inventory-pagination-top")
    view |> element("#inventory-clear-scope") |> render_click()
    assert_patch(view, list_path("/checks?page_size=10&status=active"))
    assert has_element?(view, "#inventory-page-size option[value='10'][selected]")
    assert length(elements(view, "#check-inventory tbody tr")) == 10
  end

  test "result and configuration return links retain the chosen page and size" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    path = list_path("/checks?environment=production&page=2&page_size=10&search=grouped-")
    {:ok, view, _} = live(build_conn(), path)
    result_link = view |> element("tbody tr:first-child .checks-result-link") |> render_click()
    {:ok, result, _} = follow_redirect(result_link, build_conn())
    assert has_element?(result, ".back[href='#{path}']")
    config_link = result |> element("a", "Review configuration") |> render_click()
    {:ok, config, _} = follow_redirect(config_link, build_conn())
    assert has_element?(config, ".back", "Back to result")
    back = config |> element(".back") |> render_click()
    {:ok, returned, _} = follow_redirect(back, build_conn())
    assert has_element?(returned, ".back[href='#{path}']")

    {:ok, returned, _} =
      returned |> element(".back") |> render_click() |> follow_redirect(build_conn())

    assert has_element?(returned, "#inventory-page-size option[value='10'][selected]")
    assert has_element?(returned, ".target-group-range", "11–20 of 55")
  end

  test "UI sizes are bounded without changing shared API or configuration pagination" do
    publish(
      Ecto.UUID.generate(),
      "grouped.source",
      for(index <- 1..55, do: check(padded(index), "host-a"))
    )

    for size <- ["0", "8", "999", "all", "-1"] do
      {:ok, view, _} = live(build_conn(), list_path("/checks?search=grouped-&page_size=" <> size))
      assert length(elements(view, "#check-inventory tbody tr")) == 50
      assert has_element?(view, "#inventory-page-size option[value='50'][selected]")
      refute has_element?(view, "#inventory-pagination-top a[href*='page_size=']")
    end

    assert Monitoring.list_grouped_streams(%{"search" => "grouped-", "page_size" => 8}).page_size ==
             8

    {:ok, config, _} = live(build_conn(), "/configuration?search=grouped-&page_size=10")
    assert length(elements(config, "#check-inventory tbody tr")) == 50
    assert length(elements(config, "nav.pagination")) == 1
    refute has_element?(config, "#inventory-page-size-form")
    {:ok, incidents, _} = live(build_conn(), "/incidents?page_size=10")
    assert length(elements(incidents, "nav.pagination")) == 1
    refute has_element?(incidents, "#inventory-page-size-form")
  end

  defp elements(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.to_list()

  defp list_path(path) do
    uri = URI.parse(path)
    params = URI.decode_query(uri.query || "")

    tab =
      if Enum.any?(~w(health freshness), &(params[&1] not in [nil, ""])),
        do: "custom",
        else: "all"

    query =
      params |> Map.merge(%{"tab" => tab, "view" => "list"}) |> Enum.sort() |> URI.encode_query()

    uri.path <> "?" <> query
  end

  defp stream(key) do
    Repo.one!(from s in ResultStream, where: s.result_key == ^key)
  end

  defp group_id(key) do
    id = stream(key).id

    group =
      Enum.find(Monitoring.list_grouped_streams(%{"search" => "grouped-"}).groups, fn group ->
        Enum.any?(group["items"], &(&1["id"] == id))
      end)

    "#target-group-" <> group["id"]
  end

  defp measure(key, health, knowledge, summary) do
    stream = stream(key)
    assignment = Repo.get!(Assignment, stream.assignment_id)
    runner = Repo.get!(Mondek.Runner, assignment.runner_id)
    now = DateTime.utc_now()
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

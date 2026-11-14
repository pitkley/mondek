# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnersLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Runner, SourceInventory}
  alias MondekWeb.{InvestigationTrail, RunnersLive}
  @endpoint MondekWeb.Endpoint

  setup do
    Repo.query!("TRUNCATE runners, assignments RESTART IDENTITY CASCADE")
    :ok
  end

  test "empty fleet provides setup without mixing in delivery history" do
    {:ok, view, _} = live(build_conn(), "/runners")
    assert has_element?(view, "h1", "Runners")
    assert has_element?(view, "#runner-list-empty", "No runners registered")
    assert has_element?(view, "#runner-list-empty a[href='/guide']", "Set up your first runner")
    assert has_element?(view, "a[href='/notifications']", "Notifications")
    refute has_element?(view, "#notifications")
    {:ok, missing, _} = live(build_conn(), "/runners/not-a-runner")
    assert has_element?(missing, "h1", "Runner not found")
  end

  test "complete fleet is paged before rendering and pages retain filters" do
    records = for _ <- 1..50, do: runner("Shared observer")
    {:ok, view, _} = live(build_conn(), "/runners?search=Shared&sort=name")
    assert row_count(view) == 25
    assert has_element?(view, "#runner-fleet-summary", "50")
    assert has_element?(view, "#runner-pagination", "1–25 of 50")
    assert has_element?(view, "#runner-list .fleet-identity")
    first_ids = row_ids(view)
    view |> element("#runner-pagination a", "Next") |> render_click()
    assert_patch(view, "/runners?page=2&search=Shared&sort=name")
    assert row_count(view) == 25
    second_ids = row_ids(view)
    view |> form("#runner-sort-form", %{sort: "name"}) |> render_change()
    assert row_ids(view) == second_ids
    assert has_element?(view, "#runner-pagination [aria-current=page][aria-label='Page 2']")
    assert MapSet.new(first_ids ++ second_ids) == MapSet.new(Enum.map(records, & &1.id))
    assert length(Enum.uniq(first_ids ++ second_ids)) == 50

    id = hd(second_ids)
    view |> element("#runner-row-#{id} a[data-overview-open]") |> render_click()
    assert has_element?(view, "#overview-panel #runner-detail", id)
    assert has_element?(view, "#overview-panel a[data-overview-close][href*='page=2']")

    api_page =
      build_conn()
      |> get("/api/v1/runners", %{search: "Shared", sort: "name", page: 2})
      |> json_response(200)

    assert api_page["total"] == 50
    assert api_page["counts"]["total"] == 50
    assert Enum.map(api_page["items"], & &1["id"]) == second_ids
    assert get(build_conn(), "/api/v1/runners/#{id}") |> json_response(200) |> Map.get("id") == id
    assert get(build_conn(), "/api/v1/runners/invalid") |> json_response(404)
  end

  test "chip drafts survive ticks and combined text/contact/collection filters survive reload" do
    runner("East node")
    runner("West node")
    {:ok, view, _} = live(build_conn(), "/runners?sort=name")
    view |> form("#overview-search", %{search: "West"}) |> render_submit()
    assert_patch(view, "/runners?search=West&sort=name")
    assert row_count(view) == 1
    render_click(view, "filter_open", %{"field" => "contact"})
    render_click(view, "filter_query", %{"search" => "Recent"})
    send(view.pid, :tick)
    assert has_element?(view, "#preview-search[value='Recent']")
    render_click(view, "filter_select", %{"key" => "recent"})
    assert_patch(view, "/runners?contact=recent&search=West&sort=name")
    render_click(view, "filter_open", %{"field" => "collection"})
    render_click(view, "filter_select", %{"key" => "empty"})
    expected = "/runners?collection=empty&contact=recent&search=West&sort=name"
    assert_patch(view, expected)
    assert has_element?(view, "#runner-list", "West node")
    refute has_element?(view, "#runner-list", "East node")
    {:ok, reload, _} = live(build_conn(), expected)
    assert has_element?(reload, "#preview-chip-contact", "Recent contact")
    assert has_element?(reload, "#preview-chip-collection", "No active results")
    assert has_element?(reload, ".preview-search-token", "West")
    assert row_count(reload) == 1
  end

  test "source suggestions search the complete fleet and literal source names" do
    for index <- 1..30 do
      publication(runner("Source #{index}"), "source-#{index}", %{})
    end

    special = runner("Special")
    publication(special, "literal_%_source", %{})
    {:ok, view, _} = live(build_conn(), "/runners")
    render_click(view, "filter_open", %{"field" => "source_id"})
    render_click(view, "filter_query", %{"search" => "literal_%"})
    assert has_element?(view, "#overview-filter-options", "literal_%_source")
    render_click(view, "filter_select", %{"key" => "literal_%_source"})
    assert row_count(view) == 1
    assert has_element?(view, "#runner-list", "Special")
    render_click(view, "filter_open", %{"field" => "source_id"})
    render_click(view, "filter_remove_edit", %{})
    assert_patch(view, "/runners")
    assert row_count(view) == 25
  end

  test "page and fly-over share reported telemetry, provenance, sources and safe agent prompts" do
    r =
      runner("Observer",
        status: %{
          "queue_count" => 0,
          "queue_bytes" => 2048,
          "dropped" => 5,
          "diagnostic" => %{"error" => "Earlier timeout"},
          "scheduler" => %{
            "running_checks" => "bad",
            "due_waiting_checks" => 0,
            "max_concurrency" => 3
          },
          "unknown_field" => "private-value-not-rendered"
        }
      )

    publication(r, "private-monitoring", %{
      "id" => "central",
      "label" => "Shared service observer",
      "local_environment" => "services"
    })

    for path <- [InvestigationTrail.path("/runners", [{"runner", r.id}]), "/runners/#{r.id}/full"] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "#runner-detail", "Observer")
      assert has_element?(view, "#runner-measurements", "No active published results")
      assert has_element?(view, "#runner-contact", "Recent contact")
      assert has_element?(view, "#runner-last-report", "may predate the latest contact")
      assert has_element?(view, "#runner-last-report", "Not reported")
      assert has_element?(view, "#runner-last-report", "2.0 KiB")

      assert has_element?(
               view,
               "#runner-last-report",
               "cumulative count records past evidence loss"
             )

      assert has_element?(view, "#runner-diagnostic", "may describe an earlier problem")
      assert html =~ "Earlier timeout"
      refute html =~ "private-value-not-rendered"
      refute html =~ "consumer-secret"
      prompt = view |> element("#runner-agent-prompts-collection-text") |> render()
      assert prompt =~ r.id
      refute prompt =~ "Earlier timeout"
      assert has_element?(view, "#runner-publications", "Shared service observer · services")

      assert has_element?(
               view,
               "#runner-publications",
               "Monitored environments belong to each result"
             )

      assert has_element?(
               view,
               "#runner-publications a[href^='/coverage?']",
               "Inspect declarations and placement"
             )

      assert has_element?(view, "a[href^='/checks?']", "Inspect all results")
      assert has_element?(view, "a[href^='/configuration?'][href*='runner_id=#{r.id}']")
    end

    {:ok, fleet, _} = live(build_conn(), "/runners?search=central")
    assert has_element?(fleet, "#runner-list", "Observer")
    assert has_element?(fleet, "#runner-list", "Shared service observer · services")
  end

  test "incomplete page presentation parameters keep the fleet visible" do
    r = runner("Still visible")

    for suffix <- [
          "?surface=page",
          "?surface=page&page_entity=runner:invalid",
          "?surface=page&inspect=garbage"
        ] do
      {:ok, view, _} = live(build_conn(), "/runners" <> suffix)
      assert has_element?(view, "#runner-row-#{r.id}", "Still visible")
    end
  end

  test "restored publications awaiting inventory remain explicit in both detail surfaces" do
    r = runner("Restored observer")
    publication = publication(r, "restored-source", %{})

    Repo.update_all(from(p in SourceInventory, where: p.id == ^publication.id),
      set: [resume_after_revision: 1]
    )

    for path <- [InvestigationTrail.path("/runners", [{"runner", r.id}]), "/runners/#{r.id}/full"] do
      {:ok, view, _} = live(build_conn(), path)
      assert has_element?(view, "#runner-publications tr", "Awaiting inventory")
      refute has_element?(view, "#runner-publications td[data-label=State]", "Active")
    end
  end

  test "runner destinations reject external and oversized returns while preserving bounded local origins" do
    r = runner("Navigation")
    assert RunnersLive.return_path("https://example.test/runners") == nil
    assert RunnersLive.return_path("//example.test/runners") == nil
    assert RunnersLive.return_path("/runners#status") == nil
    assert RunnersLive.return_path("/runners/invalid") == nil
    assert RunnersLive.return_path("/runners?search=" <> String.duplicate("x", 9000)) == nil

    returned = RunnersLive.return_path("/runners?page=-1&contact=invalid&unexpected=value")
    assert returned == "/runners?contact=invalid&page=-1"

    normalized =
      returned
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Mondek.RunnerFleet.normalize()

    assert normalized["page"] == 1
    assert normalized["contact"] == "all"

    recursive = RunnersLive.detail_path(r.id, RunnersLive.detail_path(r.id, "/runners"))
    assert RunnersLive.return_path(recursive) == recursive
  end

  defp runner(label, extra \\ []),
    do:
      Repo.insert!(
        struct(
          Runner,
          Keyword.merge(
            [
              id: Ecto.UUID.generate(),
              session_id: Ecto.UUID.generate(),
              boot: 1,
              label: label,
              last_seen_at: Monitoring.now()
            ],
            extra
          )
        )
      )

  defp publication(runner, source, context) do
    Repo.insert!(%SourceInventory{
      runner_id: runner.id,
      source_id: source,
      revision: 1,
      source_revision: String.duplicate("a", 64),
      payload: %{"secret" => "consumer-secret"},
      received_at: Monitoring.now(),
      coverage_context: context,
      coverage_version: 1,
      coverage_revision: 1,
      coverage_received_at: Monitoring.now(),
      coverage_source_revision: String.duplicate("a", 64),
      coverage_code_revision: String.duplicate("a", 64),
      coverage_runtime_revision: String.duplicate("a", 64),
      coverage_confirmed: true
    })
  end

  defp row_ids(view),
    do:
      view
      |> element("#runner-list")
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("tbody tr")
      |> LazyHTML.attribute("id")
      |> Enum.map(&String.replace_prefix(&1, "runner-row-", ""))

  defp row_count(view), do: length(row_ids(view))
end

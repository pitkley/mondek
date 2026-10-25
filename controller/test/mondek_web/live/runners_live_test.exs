# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RunnersLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Runner, SourceInventory}
  alias MondekWeb.RunnersLive
  @endpoint MondekWeb.Endpoint

  setup do
    Repo.query!("TRUNCATE runners, assignments RESTART IDENTITY CASCADE")
    :ok
  end

  test "empty fleet gives a setup path and keeps notification delivery separate" do
    {:ok, view, _} = live(build_conn(), "/runners")
    assert has_element?(view, "h1", "Runners")
    assert has_element?(view, "#runner-list-empty", "No runners registered")
    assert has_element?(view, "#runner-list-empty a[href='/guide']", "Set up your first runner")
    assert has_element?(view, "a[href='/notifications']", "Notifications")
    refute has_element?(view, "#notifications")
    {:ok, missing, _} = live(build_conn(), "/runners/not-a-runner")
    assert has_element?(missing, "h1", "Runner not found")
  end

  test "fifty runner fleet is bounded, page links retain filters and duplicate labels have identities" do
    records = for _ <- 1..50, do: runner("Shared observer")
    {:ok, view, _} = live(build_conn(), "/runners?search=Shared&sort=name")
    assert row_count(view) == 25
    assert has_element?(view, "#runner-fleet-summary", "50")
    assert has_element?(view, "#runner-pagination", "Page 1 of 2")
    assert has_element?(view, "#runner-list .fleet-identity")
    first_ids = row_ids(view)
    view |> element("#runner-pagination a", "Next") |> render_click()
    assert_patch(view, "/runners?page=2&search=Shared&sort=name")
    assert row_count(view) == 25
    second_ids = row_ids(view)
    assert MapSet.new(first_ids ++ second_ids) == MapSet.new(Enum.map(records, & &1.id))
    assert length(Enum.uniq(first_ids ++ second_ids)) == 50

    id = hd(second_ids)

    {:ok, detail, _} =
      live(build_conn(), RunnersLive.detail_path(id, "/runners?page=2&search=Shared&sort=name"))

    assert has_element?(detail, ".back[href='/runners?page=2&search=Shared&sort=name']")
    assert has_element?(detail, "#runner-detail", id)
    assert has_element?(detail, "#runner-contact", "communication, not a successful measurement")

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

  test "unsent filter drafts survive live refresh while applied filters survive reload" do
    runner("East node")
    runner("West node")
    {:ok, view, _} = live(build_conn(), "/runners?sort=name")
    view |> form("#runner-filters", %{search: "West"}) |> render_change()
    send(view.pid, :tick)
    assert has_element?(view, "#runner-search[value='West']")
    assert row_count(view) == 2

    view
    |> form("#runner-filters", %{
      search: "West",
      contact: "recent",
      collection: "empty",
      sort: "name"
    })
    |> render_submit()

    expected = "/runners?collection=empty&contact=recent&search=West&sort=name"
    assert_patch(view, expected)
    assert row_count(view) == 1
    assert has_element?(view, "#runner-list", "West node")
    refute has_element?(view, "#runner-list", "East node")
    {:ok, reload, _} = live(build_conn(), expected)
    assert has_element?(reload, "#runner-search[value='West']")
    assert has_element?(reload, "#runner-contact-filter option[value='recent'][selected]")
    assert row_count(reload) == 1
  end

  test "detail distinguishes current collection from historical diagnostics and malformed telemetry" do
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

    {:ok, view, html} = live(build_conn(), "/runners/#{r.id}")
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
    prompt = view |> element("#runner-agent-prompts-collection-text") |> render()
    assert prompt =~ r.id
    refute prompt =~ "Earlier timeout"
    assert has_element?(view, "a[href^='/checks?']", "Inspect all results")

    assert has_element?(
             view,
             "a[href^='/monitoring-incidents?'][href*='runner_id=#{r.id}'][href*='return_to=']"
           )
  end

  test "published execution contexts are separate from monitored environments and payload stays private" do
    r = runner("Shared services")

    publication(r, "private-monitoring", %{
      "id" => "central",
      "label" => "Shared service observer",
      "local_environment" => "services"
    })

    {:ok, view, html} = live(build_conn(), "/runners/#{r.id}")
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

    refute html =~ "consumer-secret"
    {:ok, fleet, _} = live(build_conn(), "/runners?search=central")
    assert has_element?(fleet, "#runner-list", "Shared services")
    assert has_element?(fleet, "#runner-list", "Shared service observer · services")
  end

  test "legacy runner and delivery query links redirect to distinct destinations" do
    r = runner("Legacy observer")

    assert {:error, {:live_redirect, %{to: destination}}} =
             live(build_conn(), "/runners?runner_id=#{r.id}")

    assert destination == "/runners/#{r.id}"

    assert {:error, {:live_redirect, %{to: notification}}} =
             live(
               build_conn(),
               "/runners?runner_id=#{r.id}&notification_status=exhausted&notification_page=2"
             )

    assert notification == "/notifications?notification_page=2&notification_status=exhausted"

    assert {:error, {:live_redirect, %{to: "/notifications"}}} =
             live(build_conn(), "/runners?notification_page[invalid]=1")
  end

  test "runner return navigation rejects external, unbounded and recursive destinations" do
    r = runner("Navigation")
    assert RunnersLive.return_path("https://example.test/runners") == nil
    assert RunnersLive.return_path("//example.test/runners") == nil
    assert RunnersLive.return_path("/runners#status") == nil
    assert RunnersLive.return_path("/runners/invalid") == nil
    assert RunnersLive.return_path("/runners?search=" <> String.duplicate("x", 9000)) == nil

    assert RunnersLive.return_path("/runners?page=-1&contact=invalid&unexpected=value") ==
             "/runners"

    recursive = RunnersLive.detail_path(r.id, RunnersLive.detail_path(r.id, "/runners"))
    assert RunnersLive.return_path(recursive) == "/runners/#{r.id}"
    {:ok, view, _} = live(build_conn(), RunnersLive.detail_path(r.id, "https://example.test/"))
    assert has_element?(view, ".back[href='/runners']")

    {:ok, diagnostics, _} =
      live(
        build_conn(),
        RunnersLive.detail_path(
          r.id,
          "/resources/10000000-0000-4000-8000-000000000001/diagnostics"
        )
      )

    assert has_element?(
             diagnostics,
             ".back[href='/resources/10000000-0000-4000-8000-000000000001/diagnostics']",
             "Back to measurement investigation"
           )

    inventory =
      MondekWeb.CheckInventory.path(
        MondekWeb.CheckInventory.normalize(%{
          "runner_id" => r.id,
          "freshness" => "unavailable"
        })
      )

    investigation =
      "/resources/10000000-0000-4000-8000-000000000001/diagnostics?" <>
        URI.encode_query(%{"return_to" => inventory})

    {:ok, nested, _} = live(build_conn(), RunnersLive.detail_path(r.id, investigation))

    assert has_element?(
             nested,
             ".back[href='#{investigation}']",
             "Back to measurement investigation"
           )

    unsafe_investigation =
      "/resources/10000000-0000-4000-8000-000000000001/diagnostics?" <>
        URI.encode_query(%{"return_to" => "https://example.test/"})

    {:ok, safe, _} = live(build_conn(), RunnersLive.detail_path(r.id, unsafe_investigation))

    assert has_element?(
             safe,
             ".back[href='/resources/10000000-0000-4000-8000-000000000001/diagnostics']"
           )
  end

  defp runner(label, extra \\ []) do
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
  end

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

  defp row_ids(view) do
    view
    |> element("#runner-list")
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("tbody tr")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "runner-row-", ""))
  end

  defp row_count(view), do: length(row_ids(view))
end

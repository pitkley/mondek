# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceSeriesLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Maintenance, MaintenanceSchedules, MaintenanceTime, MaintenanceWindow}

  @endpoint MondekWeb.Endpoint

  test "single-check series identify the check and observer in inventory and saved scope" do
    alias Mondek.CoverageFixtures, as: F

    series =
      for {label, observer} <- [
            {"Node A root disk", "Node A observer"},
            {"Node B root disk", "Node B observer"}
          ] do
        definition = F.check("disk") |> Map.put("label", label)
        publication = F.publication([F.candidate(definition)], %{"runner_label" => observer})
        assert {:ok, _} = Monitoring.inventory(publication)
        [assignment] = F.assignments(publication)
        {:ok, seed} = Maintenance.seed(assignment.id)

        proposal =
          seed["proposal"]
          |> Map.merge(values())
          |> Map.put(
            "recurrence",
            %{"frequency" => "weekly", "interval" => 1, "end_mode" => "count", "count" => 2}
          )

        {:ok, review} = MaintenanceSchedules.preview(proposal)
        {:ok, saved} = MaintenanceSchedules.apply(review["review_token"], review["proposal"])
        {saved, label, observer}
      end

    {:ok, index, _} = live(build_conn(), "/maintenance")

    for {saved, label, observer} <- series do
      assert has_element?(index, "#maintenance-window-#{saved["id"]}", label)
      assert has_element?(index, "#maintenance-window-#{saved["id"]}", observer)
      {:ok, detail, _} = live(build_conn(), "/maintenance/series/" <> saved["id"])
      assert has_element?(detail, "#maintenance-series-saved", label)
      assert has_element?(detail, "#maintenance-series-saved", observer)

      assert has_element?(
               detail,
               "#maintenance-series-membership-help",
               "same scheduled check instance"
             )

      assert has_element?(
               detail,
               "#maintenance-series-membership-help",
               "Replacement check instances are independent"
             )

      refute has_element?(detail, "#maintenance-series-membership-help", "across observers")
    end
  end

  test "composite recurring scope keeps result and date pages independent through save and copy" do
    alias Mondek.CoverageFixtures, as: F
    publication = F.publication(for n <- 1..26, do: F.candidate(F.check("check-#{n}")))
    assert {:ok, _} = Monitoring.inventory(publication)
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    view
    |> form("#maintenance-selection-form", filters: %{source_id: "coverage-test"})
    |> render_change()

    view |> element("#maintenance-select-matching") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "26 selections")
    view |> form("#maintenance-form", repeat: "weekly") |> render_change()

    view
    |> form("#maintenance-form", window: values(), recurrence: %{count: "26"})
    |> render_submit()

    assert has_element?(view, "#maintenance-preview-summary", "26 results")

    view
    |> element("nav[aria-label='Reviewed maintenance dates'] button", "Next dates")
    |> render_click()

    view |> element("nav[aria-label='Affected result pages'] button", "Next") |> render_click()
    assert has_element?(view, "nav[aria-label='Reviewed maintenance dates']", "Page 2 of 2")
    assert has_element?(view, "nav[aria-label='Affected result pages']", "Page 2 of 2")
    saved = save(view)

    assert has_element?(
             saved,
             "#maintenance-series-membership-help",
             "Each selected check stays with its scheduled instance"
           )

    assert has_element?(
             saved,
             "#maintenance-series-membership-help",
             "Each selected target follows exact matches"
           )

    saved
    |> element("nav[aria-label='Saved maintenance dates'] a", "Next dates")
    |> render_click()

    saved
    |> element("nav[aria-label='Series current result pages'] a", "Next results")
    |> render_click()

    assert has_element?(saved, "nav[aria-label='Saved maintenance dates']", "Page 2 of 2")
    assert has_element?(saved, "nav[aria-label='Series current result pages']", "Page 2 of 2")
    saved |> element("#maintenance-series-cancel") |> render_click()

    saved
    |> form("#maintenance-series-cancel-form", reason: "Keep paging after cancellation")
    |> render_submit()

    saved |> form("#maintenance-series-cancel-form") |> render_submit()
    assert has_element?(saved, "nav[aria-label='Saved maintenance dates']", "Page 2 of 2")
    assert has_element?(saved, "nav[aria-label='Series current result pages']", "Page 2 of 2")

    assert has_element?(
             saved,
             "#maintenance-series-windows [data-window-index='26']",
             "Cancelled"
           )

    assert has_element?(
             saved,
             "#maintenance-series-windows [data-window-index='26'] a",
             "Inspect this window"
           )

    refute has_element?(saved, "#maintenance-series-windows a", "Inspect or change")

    assert has_element?(
             saved,
             "#maintenance-series-window-help",
             "All windows have ended or been cancelled"
           )

    assert has_element?(
             saved,
             "#maintenance-series-membership-help",
             "no notification hold remains"
           )

    refute has_element?(saved, "#maintenance-series-membership-help", "future results")

    assert has_element?(
             saved,
             "#maintenance-series-copy-help",
             "Copying leaves this series unchanged"
           )

    assert has_element?(saved, "#maintenance-series-copy-help", "remaining upcoming windows")

    send(saved.pid, :tick)
    assert has_element?(saved, "nav[aria-label='Saved maintenance dates']", "Page 2 of 2")
    assert has_element?(saved, "nav[aria-label='Series current result pages']", "Page 2 of 2")
    navigation = saved |> element("#maintenance-series-copy") |> render_click()
    {:ok, copied, _} = follow_redirect(navigation, build_conn())
    assert has_element?(copied, "#maintenance-selected-count", "26 selections")
    assert has_element?(copied, "#maintenance-repeat-count[value='26']")
  end

  test "bounded count series reviews every date and lists once with individual window navigation" do
    {:ok, view, _} =
      live(build_conn(), "/maintenance/new?check_id=10000000-0000-4000-8000-000000000001")

    view |> form("#maintenance-form", repeat: "weekly") |> render_change()
    assert has_element?(view, "#maintenance-repeat-start-fold")
    refute has_element?(view, "#maintenance-start-mode option[value='now']")

    view
    |> form("#maintenance-form", window: values(), recurrence: %{count: "26"})
    |> render_submit()

    assert has_element?(view, "#maintenance-series-preview-summary", "26 windows")
    assert length(rows(view, "#maintenance-series-preview [data-window-index]")) == 25
    view |> element("button", "Back to editing") |> render_click()
    render_click(view, "occurrence_preview_page", %{"page" => "2"})
    refute has_element?(view, "#maintenance-save")
    assert has_element?(view, "#maintenance-error", "no longer valid")
    view |> form("#maintenance-form") |> render_submit()
    token = hidden(view, "_review_token")

    view
    |> element("nav[aria-label='Reviewed maintenance dates'] button", "Next dates")
    |> render_click()

    assert has_element?(view, "#maintenance-series-preview [data-window-index='26']")
    assert hidden(view, "_review_token") == token
    saved = save(view)
    assert has_element?(saved, "#maintenance-series-saved", "No window active now")
    assert has_element?(saved, "#maintenance-series-saved", "26 upcoming windows")
    assert has_element?(saved, "#maintenance-series-windows a", "Inspect or change this window")

    assert has_element?(
             saved,
             "#maintenance-series-window-help",
             "Only active or upcoming windows"
           )

    assert length(Repo.all(MaintenanceWindow)) == 26
    [entry] = Maintenance.list()["windows"]
    assert entry["kind"] == "series"

    for query <- ["result_page[x]=1&occurrence_page[]=2", "result_page[]=1&occurrence_page[x]=2"] do
      {:ok, malformed, _} = live(build_conn(), "/maintenance/series/#{entry["id"]}?" <> query)
      assert has_element?(malformed, "nav[aria-label='Saved maintenance dates']", "Page 1 of 2")

      malformed
      |> element("nav[aria-label='Saved maintenance dates'] a", "Next dates")
      |> render_click()

      assert has_element?(malformed, "#maintenance-series-windows [data-window-index='26']")
    end

    {:ok, index, _} = live(build_conn(), "/maintenance")
    assert length(rows(index, "#maintenance-list article")) == 1
    assert has_element?(index, "a[href='/maintenance/series/#{entry["id"]}']")
    {:ok, series} = MaintenanceSchedules.get(entry["id"])
    first = hd(series["occurrences"])
    {:ok, child, _} = live(build_conn(), "/maintenance/" <> first["id"])
    assert has_element?(child, "#maintenance-series-membership", "changes only this window")
    refute has_element?(child, "#maintenance-repeat")

    saved
    |> element("nav[aria-label='Saved maintenance dates'] a", "Next dates")
    |> render_click()

    assert has_element?(saved, "#maintenance-series-windows [data-window-index='26']")
    assert has_element?(saved, "#maintenance-series-windows", "Page 2 of 2")
  end

  test "later DST ambiguity and gaps are actionable before saving" do
    {:ok, view, _} =
      live(build_conn(), "/maintenance/new?check_id=10000000-0000-4000-8000-000000000001")

    view |> form("#maintenance-form", repeat: "weekly") |> render_change()
    year = Monitoring.now().year + 1
    autumn = last_sunday(year, 10)
    first = Date.add(autumn, -7)

    clocks =
      Map.merge(values(), %{
        "timezone" => "Europe/Berlin",
        "starts_local" => "#{first}T02:10:00",
        "ends_local" => "#{first}T02:50:00"
      })

    view
    |> form("#maintenance-form", window: clocks, recurrence: %{count: "2"})
    |> render_submit()

    assert has_element?(view, "#maintenance-error", "Window 2")
    assert has_element?(view, "#maintenance-error", "occurs twice")
    refute has_element?(view, "#maintenance-save")

    view
    |> form("#maintenance-form", window: %{start_fold: "earlier", end_fold: "later"})
    |> render_submit()

    assert has_element?(
             view,
             "#maintenance-series-preview [data-window-index='2']",
             "1 hour, 40 minutes"
           )

    view |> element("button", "Back to editing") |> render_click()
    spring = last_sunday(year, 3) |> Date.add(-7)

    clocks =
      Map.merge(clocks, %{
        "starts_local" => "#{spring}T02:10:00",
        "ends_local" => "#{spring}T02:50:00"
      })

    view |> form("#maintenance-form", window: clocks) |> render_submit()
    assert has_element?(view, "#maintenance-error", "does not exist")
    assert has_element?(view, "#maintenance-repeat-start-fold")
    assert Repo.all(MaintenanceWindow) == []
  end

  test "recurrence and unsent date ending recover without reauthorizing a preview" do
    {:ok, view, _} =
      live(build_conn(), "/maintenance/new?check_id=10000000-0000-4000-8000-000000000001")

    view |> form("#maintenance-form", repeat: "weekly") |> render_change()
    view |> form("#maintenance-form", window: values()) |> render_change()
    captured = hidden(view, "_proposal")
    last = Monitoring.now() |> DateTime.to_date() |> Date.add(22) |> Date.to_iso8601()

    {:ok, recovered, _} =
      live(build_conn(), "/maintenance/new?check_id=10000000-0000-4000-8000-000000000001")

    render_change(recovered, "recover", %{
      "_proposal" => captured,
      "repeat" => "weekly",
      "window" => %{"reason" => "Unsent recurring work"},
      "recurrence" => %{"end_mode" => "date", "until_date" => last, "interval" => "1"}
    })

    assert has_element?(recovered, "#maintenance-repeat option[value='weekly'][selected]")
    assert has_element?(recovered, "#maintenance-repeat-until[value='#{last}']")
    assert has_element?(recovered, "#maintenance-reason", "Unsent recurring work")
    refute has_element?(recovered, "#maintenance-save")
    recovered |> form("#maintenance-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-series-preview-summary", "4 windows")
    save(recovered)
  end

  test "upcoming cancellation preserves draft across recovery and rejects an edited child" do
    series = series(3)
    path = "/maintenance/series/" <> series["id"]
    {:ok, view, _} = live(build_conn(), path)
    view |> element("#maintenance-series-cancel") |> render_click()

    view
    |> form("#maintenance-series-cancel-form", reason: "Postpone future work")
    |> render_change()

    {:ok, recovered, _} = live(build_conn(), path)

    render_change(recovered, "series_cancel_edit", %{
      "_id" => series["id"],
      "revision" => to_string(series["revision"]),
      "reason" => "Postpone future work"
    })

    assert has_element?(recovered, "#maintenance-series-cancel-reason", "Postpone future work")
    refute has_element?(recovered, "#maintenance-series-cancel-preview")
    recovered |> form("#maintenance-series-cancel-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-series-cancel-summary", "3 upcoming windows")
    assert length(rows(recovered, "[data-window-index='1']")) == 2

    ids =
      recovered
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("[id]")
      |> LazyHTML.attribute("id")

    assert length(ids) == length(Enum.uniq(ids))
    child = Enum.at(series["occurrences"], 1)
    {:ok, saved} = Maintenance.get(child["id"])
    {:ok, review} = Maintenance.preview(Map.put(saved["proposal"], "reason", "Changed one date"))
    {:ok, _} = Maintenance.apply(review["review_token"], review["proposal"])
    recovered |> form("#maintenance-series-cancel-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-error", "changed")
    assert Enum.all?(Repo.all(MaintenanceWindow), &is_nil(&1.cancelled_at))
    send(recovered.pid, :tick)
    assert has_element?(recovered, "#maintenance-series-cancel-current")
    recovered |> element("#maintenance-series-cancel-current") |> render_click()
    recovered |> form("#maintenance-series-cancel-form") |> render_submit()
    recovered |> form("#maintenance-series-cancel-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-notice", "Active windows")
    assert Enum.all?(Repo.all(MaintenanceWindow), & &1.cancelled_at)
    assert has_element?(recovered, "#maintenance-series-history", "Individual window changed")

    assert has_element?(
             recovered,
             "#maintenance-series-history a[href='/maintenance/#{child["id"]}']",
             "Window 2"
           )

    assert has_element?(recovered, "#maintenance-series-history", "3 windows")
  end

  test "copying a series creates an independent draft and malformed recovery cannot inject recurrence" do
    series = series(2)
    {:ok, view, _} = live(build_conn(), "/maintenance/new?copy_series=" <> series["id"])
    assert has_element?(view, "#maintenance-repeat option[value='weekly'][selected]")
    assert has_element?(view, "#maintenance-notice", "Existing windows are unchanged")
    assert Jason.decode!(hidden(view, "_proposal"))["id"] == nil

    corrupt =
      Jason.decode!(hidden(view, "_proposal"))
      |> Map.put("recurrence", %{"count" => []})
      |> Jason.encode!()

    render_change(view, "recover", %{"_proposal" => corrupt})
    assert has_element?(view, "#maintenance-error", "does not belong")
    assert length(Repo.all(MaintenanceWindow)) == 2
    {:ok, missing, _} = live(build_conn(), "/maintenance/series/" <> Ecto.UUID.generate())
    assert has_element?(missing, "#maintenance-error")
    refute has_element?(missing, "#maintenance-series-saved")
  end

  test "series cancellation leaves an active window inspectable with its explicit end action" do
    now = Monitoring.now()
    created = DateTime.add(now, -7200)
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001", nil, created)

    proposal =
      seed["proposal"]
      |> Map.merge(values())
      |> Map.merge(%{
        "starts_local" => MaintenanceTime.local(DateTime.add(now, -60), "UTC"),
        "ends_local" => MaintenanceTime.local(DateTime.add(now, 600), "UTC"),
        "recurrence" => %{
          "frequency" => "weekly",
          "interval" => 1,
          "end_mode" => "count",
          "count" => 2
        }
      })

    {:ok, review} = MaintenanceSchedules.preview(proposal, 1, 1, created)

    {:ok, series} =
      MaintenanceSchedules.apply(review["review_token"], review["proposal"], created)

    first = hd(series["occurrences"])
    {:ok, view, _} = live(build_conn(), "/maintenance/series/" <> series["id"])
    assert has_element?(view, "#maintenance-series-saved", "1 window active now")
    view |> element("#maintenance-series-cancel") |> render_click()

    view
    |> form("#maintenance-series-cancel-form", reason: "Cancel future work only")
    |> render_submit()

    assert has_element?(
             view,
             "#maintenance-series-cancel-summary",
             "Keep 1 active window unchanged"
           )

    view |> form("#maintenance-series-cancel-form") |> render_submit()
    assert is_nil(Repo.get!(MaintenanceWindow, first["id"]).cancelled_at)

    assert has_element?(
             view,
             "#maintenance-series-windows [data-window-index='1'] a",
             "Inspect or change this window"
           )

    assert has_element?(
             view,
             "#maintenance-series-windows [data-window-index='2'] a",
             "Inspect this window"
           )

    assert has_element?(
             view,
             "#maintenance-series-membership-help",
             "same scheduled check instance"
           )

    {:ok, active, _} = live(build_conn(), "/maintenance/" <> first["id"])
    assert has_element?(active, "#maintenance-cancel", "End maintenance now")
  end

  defp values do
    now = Monitoring.now() |> DateTime.truncate(:second)

    %{
      "name" => "Weekly storage work",
      "reason" => "Planned volume maintenance",
      "timezone" => "UTC",
      "start_mode" => "scheduled",
      "starts_local" => MaintenanceTime.local(DateTime.add(now, 3600), "UTC"),
      "ends_local" => MaintenanceTime.local(DateTime.add(now, 7200), "UTC")
    }
  end

  defp series(count) do
    {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")

    proposal =
      seed["proposal"]
      |> Map.merge(values())
      |> Map.put(
        "recurrence",
        %{
          "frequency" => "weekly",
          "interval" => 1,
          "end_mode" => "count",
          "count" => count,
          "until_date" => nil
        }
      )

    {:ok, review} = MaintenanceSchedules.preview(proposal)
    {:ok, series} = MaintenanceSchedules.apply(review["review_token"], review["proposal"])
    series
  end

  defp last_sunday(year, month) do
    last = Date.new!(year, month, 1) |> Date.end_of_month()
    Date.add(last, -rem(Date.day_of_week(last), 7))
  end

  defp save(view) do
    navigation = view |> form("#maintenance-form") |> render_submit()
    {:ok, saved, _} = follow_redirect(navigation, build_conn())
    saved
  end

  defp rows(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_tree()

  defp hidden(view, name),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("input[name='#{name}']")
      |> LazyHTML.attribute("value")
      |> hd()
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{Inventory, Maintenance, MaintenanceTime, MaintenanceWindow, ResultStream}

  @endpoint MondekWeb.Endpoint

  test "global creation searches checks and check pages lead to reviewed maintenance" do
    {:ok, chooser, _} = live(build_conn(), "/maintenance/new")
    assert has_element?(chooser, "#maintenance-check-chooser")

    chooser
    |> form("#maintenance-selection-form",
      filters: %{search: "10000000-0000-4000-8000-000000000001"}
    )
    |> render_change()

    assert has_element?(
             chooser,
             "a[href='/maintenance/new?check_id=10000000-0000-4000-8000-000000000001']"
           )

    assert has_element?(chooser, "#maintenance-settings[style='display: none']")
    {:ok, check, _} = live(build_conn(), "/resources/10000000-0000-4000-8000-000000000001")

    assert has_element?(
             check,
             "#schedule-maintenance[href='/maintenance/new?check_id=10000000-0000-4000-8000-000000000001']"
           )

    refute has_element?(check, "#maintenance-form-10000000-0000-4000-8000-000000000001")
  end

  test "selection spans pages and filters while settings and explicit removals survive" do
    publish_many(60)
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    view
    |> form("#maintenance-selection-form", filters: %{source_id: "maintenance.consumer"})
    |> render_change()

    assert length(elements(view, ".maintenance-picker-rows li")) == 25
    view |> element("#maintenance-select-page") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "25 selections")
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_change()

    view
    |> element("nav[aria-label='Maintenance selection pages'] button", "Next")
    |> render_click()

    [next_key | _] = choice_keys(view)
    view |> form("#maintenance-selection-form", selected_keys: [next_key]) |> render_change()
    assert has_element?(view, "nav[aria-label='Maintenance selection pages']", "Page 2 of 3")
    assert has_element?(view, "#maintenance-selected-count", "26 selections")

    view
    |> form("#maintenance-selection-form", filters: %{search: "Bulk check 059"})
    |> render_change()

    assert has_element?(view, "#maintenance-selected-count", "26 selections")
    assert has_element?(view, "#maintenance-name[value='Sunday storage work']")
    view |> element("#maintenance-review-selected") |> render_click()
    assert length(elements(view, ".maintenance-picker-rows li")) == 25

    view
    |> element("nav[aria-label='Maintenance selection pages'] button", "Next")
    |> render_click()

    assert length(elements(view, ".maintenance-picker-rows li")) == 1
    view |> element(".maintenance-picker-rows button", "Remove") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "25 selections")
    view |> element("#maintenance-clear-selection") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "0 selections")
    assert has_element?(view, "#maintenance-settings[style='display: none']")
    assert has_element?(view, "#maintenance-name[value='Sunday storage work']")
  end

  test "all matching choices make one reviewed window with bounded inspectable selections" do
    publish_many(60)
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    view
    |> form("#maintenance-selection-form", filters: %{source_id: "maintenance.consumer"})
    |> render_change()

    view |> element("#maintenance-select-matching") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "60 selections")
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_submit()

    assert has_element?(
             view,
             "#maintenance-preview-summary",
             "60 results across 60 scheduled checks"
           )

    assert length(elements(view, "#maintenance-saved-selection li")) == 25

    assert has_element?(
             view,
             "#maintenance-selection-details > summary",
             "Inspect selected checks and targets (60)"
           )

    refute has_element?(view, "#maintenance-selection-details[open]")
    assert length(elements(view, "#maintenance-preview .maintenance-matches li")) == 25

    assert has_element?(
             view,
             "#maintenance-preview-matches > summary",
             "Inspect currently matching results (60)"
           )

    refute has_element?(view, "#maintenance-preview-matches[open]")
    view |> element("nav[aria-label='Affected result pages'] button", "Next") |> render_click()
    assert has_element?(view, "nav[aria-label='Affected result pages']", "Page 2 of 3")
    assert length(elements(view, "#maintenance-preview .maintenance-matches li")) == 25
    assert has_element?(view, "#maintenance-save")
    refute has_element?(view, "#maintenance-preview-matches #maintenance-save")
    view |> element("nav[aria-label='Saved selection pages'] button", "Next") |> render_click()
    assert has_element?(view, "nav[aria-label='Saved selection pages']", "Page 2 of 3")
    saved = save_preview(view)
    assert Repo.aggregate(MaintenanceWindow, :count) == 1
    assert length(Repo.one!(MaintenanceWindow).selections) == 60

    assert has_element?(
             saved,
             "#maintenance-saved",
             "One window covering 60 selected checks or targets"
           )

    assert length(elements(saved, "#maintenance-saved-selection li")) == 25

    assert has_element?(
             saved,
             "#maintenance-selection-details > summary",
             "Inspect selected checks and targets (60)"
           )

    refute has_element?(saved, "#maintenance-selection-details[open]")
    assert has_element?(saved, "#maintenance-history", "60 selected checks or targets")
    assert has_element?(saved, "#maintenance-history a[href='#maintenance-saved-selection']")
    refute has_element?(saved, "#maintenance-select-matching")
    refute has_element?(saved, "#maintenance-include-more")
    {:ok, listing, _} = live(build_conn(), "/maintenance")
    assert has_element?(listing, "#maintenance-list", "60 selected checks or targets")

    check =
      Repo.one!(from a in Assignment, where: a.source_id == "maintenance.consumer", limit: 1)

    {:ok, detail, _} = live(build_conn(), "/resources/" <> check.id)
    assert has_element?(detail, "#maintenance-summary-#{check.id}", "Selected checks and targets")

    refute has_element?(
             detail,
             "#maintenance-summary-#{check.id}",
             "All results of this scheduled check"
           )
  end

  test "a delayed checkbox change uses the displayed page even after inventory reorders" do
    publish_many(30)
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    view
    |> form("#maintenance-selection-form", filters: %{source_id: "maintenance.consumer"})
    |> render_change()

    view |> element("#maintenance-select-page") |> render_click()
    captured = selection_recovery(view)
    [moved_key | _] = choice_keys(view)
    moved = moved_key |> Base.url_decode64!(padding: false) |> Jason.decode!()
    check = Repo.get!(Assignment, moved["assignment_id"])
    Monitoring.change(check, %{label: "ZZZ check moved to the next page"})
    view |> form("#maintenance-selection-form") |> render_change()
    refute moved_key in choice_keys(view)
    assert has_element?(view, "#maintenance-selected-count", "25 selections")
    delayed = Map.update!(captured, "selected_keys", &List.delete(&1, moved_key))
    render_change(view, "selection_change", delayed)
    assert has_element?(view, "#maintenance-selected-count", "24 selections")
    saved = Jason.decode!(hidden(view, "_proposal"))["selections"]
    refute Enum.any?(saved, &(&1["assignment_id"] == moved["assignment_id"]))
  end

  test "a direct check can include targets without double counting or implying host children" do
    check = publish()
    {:ok, view, _} = live(build_conn(), new_path(check.id))
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_change()
    view |> element("#maintenance-include-more") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "1 selection")
    render_click(view, "include_more", %{})
    assert has_element?(view, "#maintenance-selected-count", "1 selection")
    assert has_element?(view, "#maintenance-selection-help", "same source")

    assert has_element?(
             view,
             "#maintenance-check-chooser",
             "does not include separately named disks"
           )

    view
    |> form("#maintenance-selection-form",
      filters: %{kind: "target", source_id: "maintenance.consumer"}
    )
    |> render_change()

    assert has_element?(view, "#maintenance-check-chooser", "across all observers")
    view |> element("#maintenance-select-matching") |> render_click()
    assert has_element?(view, "#maintenance-selected-count", "3 selections")
    view |> form("#maintenance-form") |> render_submit()

    assert has_element?(
             view,
             "#maintenance-preview-summary",
             "2 results across 1 scheduled check"
           )

    saved = save_preview(view)
    assert has_element?(saved, "#maintenance-history", "3 selected checks or targets")
  end

  test "recovery preserves unsent selection and settings in either form recovery order" do
    publish_many(30)
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    view
    |> form("#maintenance-selection-form", filters: %{source_id: "maintenance.consumer"})
    |> render_change()

    view |> element("#maintenance-select-page") |> render_click()
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_change()

    view
    |> element("nav[aria-label='Maintenance selection pages'] button", "Next")
    |> render_click()

    [new_key | _] = choice_keys(view)
    captured = selection_recovery(view) |> Map.put("selected_keys", [new_key])

    settings = %{
      "_proposal" => hidden(view, "_proposal"),
      "window" => %{"name" => "Typed while disconnected", "reason" => "Unsent reason survives"}
    }

    for order <- [[:selection, :settings], [:settings, :selection]] do
      {:ok, recovered, _} = live(build_conn(), "/maintenance/new")

      for event <- order do
        case event do
          :selection -> render_change(recovered, "recover_selection", captured)
          :settings -> render_change(recovered, "recover", settings)
        end
      end

      assert has_element?(recovered, "#maintenance-name[value='Typed while disconnected']")
      assert has_element?(recovered, "#maintenance-reason", "Unsent reason survives")
      assert has_element?(recovered, "#maintenance-selected-count", "26 selections")

      assert has_element?(
               recovered,
               "nav[aria-label='Maintenance selection pages']",
               "Page 2 of 2"
             )

      assert has_element?(recovered, "#maintenance-source[value='maintenance.consumer']")
      refute has_element?(recovered, "#maintenance-save")
      recovered |> form("#maintenance-form") |> render_submit()

      assert has_element?(
               recovered,
               "#maintenance-preview-summary",
               "26 results across 26 scheduled checks"
             )
    end
  end

  test "converted direct-check drafts recover before the chooser was present on reconnect" do
    {:ok, view, _} = live(build_conn(), new_path())
    view |> element("#maintenance-include-more") |> render_click()
    view |> element("#maintenance-select-matching") |> render_click()
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_change()
    captured = selection_recovery(view)

    settings = %{
      "_proposal" => hidden(view, "_proposal"),
      "window" => %{"name" => "Converted draft"}
    }

    {:ok, recovered, _} = live(build_conn(), new_path())
    render_change(recovered, "recover_selection", captured)
    render_change(recovered, "recover", settings)
    assert has_element?(recovered, "#maintenance-selected-count", "3 selections")
    refute has_element?(recovered, "#maintenance-check-chooser[style='display: none']")
    assert has_element?(recovered, "#maintenance-name[value='Converted draft']")
  end

  test "selection recovery accepts bounded arrays above the old limit and rejects malformed or oversized drafts" do
    {:ok, view, _} = live(build_conn(), "/maintenance/new")
    base = Jason.decode!(hidden(view, "_proposal"))

    selectors =
      for index <- 1..40,
          do: %{
            "scope" => "target",
            "assignment_id" => nil,
            "source_id" => String.duplicate("a", 180),
            "environment" => String.duplicate("e", 120),
            "target_kind" => "volume",
            "target_key" => "target-#{index}-" <> String.duplicate("k", 170)
          }

    valid = base |> Map.put("selections", selectors) |> Jason.encode!()
    assert byte_size(valid) > 16_000
    render_change(view, "recover", %{"_proposal" => valid})
    assert has_element?(view, "#maintenance-selected-count", "40 selections")

    for invalid <- [
          Map.put(base, "selections", List.duplicate(hd(selectors), 513)),
          Map.put(base, "selections", [%{"scope" => "target", "target_key" => ["nested"]}]),
          Map.put(base, "name", %{"nested" => "value"})
        ] do
      render_change(view, "recover", %{"_proposal" => Jason.encode!(invalid)})
      assert has_element?(view, "#maintenance-error", "does not belong")
      assert has_element?(view, "#maintenance-selected-count", "40 selections")
    end

    render_change(view, "recover", %{"_proposal" => String.duplicate("x", 2_097_153)})
    assert has_element?(view, "#maintenance-error", "does not belong")
  end

  test "maximum escaped selector identities fit the explicit bounded reconnect payload" do
    {:ok, view, _} = live(build_conn(), "/maintenance/new")
    base = Jason.decode!(hidden(view, "_proposal"))

    selectors =
      for index <- 1..512 do
        %{
          "scope" => "target",
          "assignment_id" => nil,
          "source_id" => "s" <> String.duplicate(<<1>>, 199),
          "environment" => "e" <> String.duplicate(<<2>>, 127),
          "target_kind" => "k" <> String.duplicate(<<3>>, 63),
          "target_key" => String.pad_leading(Integer.to_string(index), 200, <<4>>)
        }
      end

    encoded = base |> Map.put("selections", selectors) |> Jason.encode!()
    assert byte_size(encoded) > 1_500_000
    assert byte_size(encoded) < 2_097_152
    render_change(view, "recover", %{"_proposal" => encoded})
    assert has_element?(view, "#maintenance-selected-count", "512 selections")
    view |> element("#maintenance-review-selected") |> render_click()
    captured = selection_recovery(view)
    {:ok, recovered, _} = live(build_conn(), "/maintenance/new")
    render_change(recovered, "recover_selection", captured)
    assert has_element?(recovered, "#maintenance-selected-count", "512 selections")
    assert length(elements(recovered, ".maintenance-picker-rows li")) == 25
    refute has_element?(recovered, "#maintenance-error")
  end

  test "withdrawn choices remain inspectable with zero matches and membership drift invalidates review" do
    check = publish()
    {:ok, view, _} = live(build_conn(), new_path(check.id))
    view |> element("#maintenance-include-more") |> render_click()
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_submit()
    view = save_preview(view)

    view
    |> form("#maintenance-form", window: %{reason: "Preserve this unsaved explanation"})
    |> render_submit()

    assert has_element?(view, "#maintenance-save")
    assert {:ok, _} = Inventory.reconcile(inventory([], 2), at())
    send(view.pid, :tick)
    refute has_element?(view, "#maintenance-save")
    assert has_element?(view, "#maintenance-error", "changed")
    assert has_element?(view, "#maintenance-name[value='Sunday storage work']")
    assert has_element?(view, "#maintenance-reason", "Preserve this unsaved explanation")
    assert has_element?(view, "#maintenance-saved-selection", "0 current results")
    assert has_element?(view, "#maintenance-saved-selection", "Not currently available")
    view |> form("#maintenance-form") |> render_submit()
    assert has_element?(view, "#maintenance-zero-matches")
    saved = save_preview(view)
    assert has_element?(saved, "#maintenance-saved-selection", "Shared storage query")
    assert has_element?(saved, "#maintenance-saved-selection", "0 current results")
    assert has_element?(saved, "#maintenance-cancel")
  end

  test "future scheduling requires a preview and presents local, UTC and overlap meaning" do
    {:ok, view, _} = live(build_conn(), new_path())
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    values = future_values()
    view |> form("#maintenance-form", window: values) |> render_submit()
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    assert has_element?(view, "#maintenance-preview-summary", "1 result across 1 scheduled check")
    assert has_element?(view, "#maintenance-preview", "UTC")
    assert has_element?(view, "#maintenance-overlaps", "Overlaps are allowed")
    assert has_element?(view, "#maintenance-save")
    saved = save_preview(view)
    assert has_element?(saved, "#maintenance-saved", "Upcoming")
    assert has_element?(saved, "#maintenance-history", "Local operator")
    window = Repo.one!(MaintenanceWindow)
    assert window.name == values["name"]
    assert DateTime.compare(window.starts_at, Monitoring.now()) == :gt
    {:ok, listing, _} = live(build_conn(), "/maintenance")
    assert has_element?(listing, "#maintenance-window-#{window.id}", values["name"])
  end

  test "invalid daylight-saving gaps retain values and repeated times require an explicit occurrence" do
    {:ok, view, _} = live(build_conn(), new_path())
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()

    values =
      Map.merge(future_values(), %{
        "timezone" => "Europe/Berlin",
        "starts_local" => "2055-03-28T02:30:00",
        "ends_local" => "2055-03-28T04:00:00"
      })

    view |> form("#maintenance-form", window: values) |> render_submit()
    assert has_element?(view, "#maintenance-error", "does not exist")
    assert has_element?(view, "#maintenance-start[value='2055-03-28T02:30:00']")
    assert has_element?(view, "#maintenance-reason", values["reason"])

    values =
      Map.merge(values, %{
        "starts_local" => "2055-10-31T02:30:00",
        "ends_local" => "2055-10-31T03:30:00"
      })

    view |> form("#maintenance-form", window: values) |> render_change()
    assert has_element?(view, "input[name='window[start_fold]'][value='earlier']")
    view |> form("#maintenance-form") |> render_submit()
    assert has_element?(view, "#maintenance-error", "occurs twice")
    view |> form("#maintenance-form", window: %{start_fold: "earlier"}) |> render_submit()
    assert has_element?(view, "#maintenance-preview", "00:30:00 UTC")
    assert has_element?(view, "#maintenance-preview", "2 hours")
    view |> element("button", "Back to editing") |> render_click()

    view
    |> form("#maintenance-form", window: %{starts_local: "2055-10-31T02:45:00"})
    |> render_change()

    refute has_element?(view, "input[name='window[start_fold]'][checked]")
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
  end

  test "preview reconnect restores the complete draft but requires a new review" do
    {:ok, view, _} = live(build_conn(), new_path())
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    values = future_values()
    view |> form("#maintenance-form", window: values) |> render_submit()
    captured = hidden(view, "_proposal")
    send(view.pid, :tick)
    assert has_element?(view, "#maintenance-preview", values["name"])
    {:ok, recovered, _} = live(build_conn(), new_path())
    recovered |> render_change("recover", %{"_proposal" => captured})
    assert has_element?(recovered, "#maintenance-name[value='#{values["name"]}']")
    assert has_element?(recovered, "#maintenance-notice", "Preview again")
    refute has_element?(recovered, "#maintenance-save")
    assert Repo.aggregate(MaintenanceWindow, :count) == 0
    recovered |> form("#maintenance-form") |> render_submit()
    save_preview(recovered)
    assert Repo.one!(MaintenanceWindow).name == values["name"]
  end

  test "concurrent update preserves draft and requires current revision review" do
    window = save_window()
    path = "/maintenance/" <> window["id"]
    {:ok, view, _} = live(build_conn(), path)
    view |> form("#maintenance-form", window: %{name: "My unsaved window"}) |> render_submit()
    assert {:ok, current} = Maintenance.get(window["id"])
    other = Map.put(current["proposal"], "name", "Changed elsewhere")
    assert {:ok, review} = Maintenance.preview(other)
    assert {:ok, _} = Maintenance.apply(review["review_token"], review["proposal"])
    view |> form("#maintenance-form") |> render_submit()
    assert has_element?(view, "#maintenance-name[value='My unsaved window']")
    assert has_element?(view, "#maintenance-review-current")
    assert has_element?(view, "#maintenance-preview-button[disabled]")
    view |> element("#maintenance-review-current") |> render_click()
    assert has_element?(view, "#maintenance-name[value='My unsaved window']")
    view |> form("#maintenance-form") |> render_submit()
    save_preview(view)
    assert {:ok, %{"name" => "My unsaved window"}} = Maintenance.get(window["id"])
  end

  test "clean saved reconnect does not report a draft or change scheduled and active windows" do
    upcoming = save_window()
    assert {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")
    proposal = Map.merge(seed["proposal"], %{"name" => "Active work", "reason" => "Disk work"})
    assert {:ok, review} = Maintenance.preview(proposal)
    assert {:ok, active} = Maintenance.apply(review["review_token"], review["proposal"])

    for window <- [upcoming, active] do
      path = "/maintenance/" <> window["id"]
      {:ok, view, _} = live(build_conn(), path)
      captured = hidden(view, "_proposal")
      values = recovered_values(captured)
      {:ok, recovered, _} = live(build_conn(), path)
      render_change(recovered, "recover", %{"_proposal" => captured, "window" => values})

      refute has_element?(recovered, "#maintenance-notice")
      refute has_element?(recovered, "#maintenance-review-current")
      refute has_element?(recovered, "#maintenance-save")
      assert has_element?(recovered, "#maintenance-name[value='#{window["name"]}']")
      assert {:ok, current} = Maintenance.get(window["id"])
      assert current["status"] == window["status"]
      assert current["revision"] == window["revision"]
      assert current["starts_at"] == window["starts_at"]
      assert current["ends_at"] == window["ends_at"]
    end
  end

  test "saved reconnect distinguishes unsaved edits from maintenance already in effect" do
    upcoming = save_window()
    assert {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")
    proposal = Map.merge(seed["proposal"], %{"name" => "Active work", "reason" => "Disk work"})
    assert {:ok, review} = Maintenance.preview(proposal)
    assert {:ok, active} = Maintenance.apply(review["review_token"], review["proposal"])

    for {window, message} <- [
          {upcoming, "Saved maintenance is still scheduled"},
          {active, "Saved maintenance remains in effect"}
        ] do
      path = "/maintenance/" <> window["id"]
      {:ok, view, _} = live(build_conn(), path)
      captured = hidden(view, "_proposal")
      values = Map.put(recovered_values(captured), "reason", "Unsent reason while disconnected")
      {:ok, recovered, _} = live(build_conn(), path)
      render_change(recovered, "recover", %{"_proposal" => captured, "window" => values})

      assert has_element?(recovered, "#maintenance-notice", message)
      assert has_element?(recovered, "#maintenance-reason", values["reason"])
      refute has_element?(recovered, "#maintenance-review-current")
      refute has_element?(recovered, "#maintenance-save")
      assert {:ok, current} = Maintenance.get(window["id"])
      assert current["reason"] == window["reason"]
      assert current["revision"] == window["revision"]
    end
  end

  test "saved reconnect retains an old reviewed revision and unsaved edits after concurrent change" do
    window = save_window()
    path = "/maintenance/" <> window["id"]
    {:ok, view, _} = live(build_conn(), path)
    captured = hidden(view, "_proposal")
    assert {:ok, window} = Maintenance.get(window["id"])
    proposal = Map.put(window["proposal"], "reason", "Changed elsewhere")
    assert {:ok, review} = Maintenance.preview(proposal)
    assert {:ok, _} = Maintenance.apply(review["review_token"], review["proposal"])
    {:ok, recovered, _} = live(build_conn(), path)
    values = Map.put(recovered_values(captured), "name", "My unsent name")
    render_change(recovered, "recover", %{"_proposal" => captured, "window" => values})

    assert has_element?(recovered, "#maintenance-name[value='My unsent name']")
    assert has_element?(recovered, "#maintenance-notice", "Review the changed saved window")
    assert has_element?(recovered, "#maintenance-review-current")
    assert has_element?(recovered, "#maintenance-preview-button[disabled]")
    assert Jason.decode!(hidden(recovered, "_proposal"))["revision"] == window["revision"]
  end

  test "cancellation draft survives reconnect and stale cancellation cannot end a newer window" do
    window = save_window()
    path = "/maintenance/" <> window["id"]
    {:ok, view, _} = live(build_conn(), path)
    view |> element("#maintenance-cancel") |> render_click()
    view |> form("#maintenance-cancel-form", reason: "Work postponed") |> render_change()

    captured = %{
      "_id" => window["id"],
      "_open" => "true",
      "revision" => to_string(window["revision"]),
      "reason" => "Work postponed"
    }

    {:ok, recovered, _} = live(build_conn(), path)
    recovered |> render_change("edit_cancel", captured)
    assert has_element?(recovered, "#maintenance-cancel-reason", "Work postponed")
    assert {:ok, current} = Maintenance.get(window["id"])

    assert {:ok, review} =
             Maintenance.preview(Map.put(current["proposal"], "name", "Latest plan"))

    assert {:ok, _} = Maintenance.apply(review["review_token"], review["proposal"])
    recovered |> form("#maintenance-cancel-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-error", "changed")
    assert {:ok, %{"status" => "upcoming"}} = Maintenance.get(window["id"])
    assert has_element?(recovered, "#maintenance-cancel-reason", "Work postponed")
    recovered |> element("#maintenance-review-current") |> render_click()
    recovered |> element("button", "Keep window") |> render_click()
    recovered |> element("#maintenance-cancel") |> render_click()
    navigation = recovered |> form("#maintenance-cancel-form") |> render_submit()
    {:ok, cancelled, _} = follow_redirect(navigation, build_conn())
    assert has_element?(cancelled, "#maintenance-saved", "Cancelled")
    assert has_element?(cancelled, "#maintenance-saved dt", "Scheduled start")
    assert has_element?(cancelled, "#maintenance-saved dt", "Scheduled end")
    assert has_element?(cancelled, "#maintenance-saved dt", "Planned duration")
    assert has_element?(cancelled, "#maintenance-saved dt", "Cancelled at")
    assert has_element?(cancelled, "#maintenance-history h3", "Window cancelled before start")
    assert has_element?(cancelled, "#maintenance-history", "Work postponed")
    refute has_element?(cancelled, "#maintenance-form")
  end

  test "target scope isolates one result of a shared execution and survives withdrawal" do
    check = publish()

    streams =
      Repo.all(from s in ResultStream, where: s.assignment_id == ^check.id)
      |> Map.new(&{&1.result_key, &1})

    {:ok, view, _} =
      live(build_conn(), new_path(check.id) <> "&stream_id=" <> streams["volume"].id)

    assert has_element?(view, "#maintenance-dynamic-scope", "same source")
    refute has_element?(view, "[name='window[source_id]']")
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_submit()

    assert has_element?(
             view,
             "#maintenance-preview-summary",
             "1 result across 1 scheduled check"
           )

    assert has_element?(view, "#maintenance-preview a[href='/checks/#{streams["volume"].id}']")
    refute has_element?(view, "#maintenance-preview a[href='/checks/#{streams["other"].id}']")
    captured = hidden(view, "_proposal")
    {:ok, recovered, _} = live(build_conn(), new_path(check.id))
    recovered |> render_change("recover", %{"_proposal" => captured})
    assert has_element?(recovered, "#maintenance-dynamic-scope", "same source")
    recovered |> form("#maintenance-form") |> render_submit()
    save_preview(recovered)
    window = Repo.one!(MaintenanceWindow)
    assert {:ok, _} = Inventory.reconcile(inventory([], 2), at())
    {:ok, dormant, _} = live(build_conn(), "/maintenance/" <> window.id)
    assert has_element?(dormant, "#maintenance-saved", "No current results match")

    dormant
    |> form("#maintenance-form", window: %{reason: "Target returning during window"})
    |> render_submit()

    assert has_element?(dormant, "#maintenance-zero-matches", "matching results can be covered")
    saved = save_preview(dormant)
    assert has_element?(saved, "#maintenance-cancel")
  end

  test "active windows fix start and scope while allowing the end to change" do
    assert {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")

    proposal =
      Map.merge(seed["proposal"], %{"name" => "Ongoing work", "reason" => "Disk replacement"})

    assert {:ok, preview} = Maintenance.preview(proposal)
    assert {:ok, window} = Maintenance.apply(preview["review_token"], proposal)
    {:ok, view, _} = live(build_conn(), "/maintenance/" <> window["id"])
    assert has_element?(view, "#maintenance-scope[disabled]")
    assert has_element?(view, "#maintenance-start[readonly]")
    assert has_element?(view, "#maintenance-timezone[readonly]")
    ends = Monitoring.now() |> DateTime.add(3 * 86_400) |> MaintenanceTime.local("UTC")
    view |> form("#maintenance-form", window: %{ends_local: ends}) |> render_submit()
    saved = save_preview(view)
    assert has_element?(saved, "#maintenance-cancel", "End maintenance now")
    assert {:ok, current} = Maintenance.get(window["id"])
    assert current["starts_at"] == window["starts_at"]
    saved |> element("#maintenance-cancel") |> render_click()

    navigation =
      saved
      |> form("#maintenance-cancel-form", reason: "Replacement completed")
      |> render_submit()

    {:ok, ended, _} = follow_redirect(navigation, build_conn())
    assert has_element?(ended, "#maintenance-saved dt", "Scheduled end")
    assert has_element?(ended, "#maintenance-saved dt", "Planned duration")
    assert has_element?(ended, "#maintenance-saved dt", "Ended early at")
    refute has_element?(ended, "#maintenance-saved dt", "Elapsed duration")
    assert has_element?(ended, "#maintenance-history h3", "Maintenance ended early")
  end

  test "target scope survives normalized preview, back to editing and full form recovery" do
    check = publish()

    stream =
      Repo.one!(
        from s in ResultStream, where: s.assignment_id == ^check.id and s.result_key == "volume"
      )

    {:ok, view, _} = live(build_conn(), new_path(check.id) <> "&stream_id=" <> stream.id)
    view |> form("#maintenance-form", window: %{start_mode: "scheduled"}) |> render_change()
    view |> form("#maintenance-form", window: future_values()) |> render_submit()
    captured_after_preview = hidden(view, "_proposal")
    assert Jason.decode!(captured_after_preview)["selections"] == []
    view |> element("button", "Back to editing") |> render_click()

    selected =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#maintenance-scope option[selected]")
      |> LazyHTML.attribute("value")
      |> hd()

    assert has_element?(view, "#maintenance-scope option[selected]", "volume: across runners")

    view
    |> form("#maintenance-form", window: %{reason: "Keep the exact selected volume"})
    |> render_change()

    assert Jason.decode!(hidden(view, "_proposal"))["scope"] == "target"
    assert Jason.decode!(hidden(view, "_proposal"))["target_key"] == "volume-uid"
    {:ok, recovered, _} = live(build_conn(), new_path(check.id))

    render_change(recovered, "recover", %{
      "_proposal" => captured_after_preview,
      "scope_choice" => selected,
      "window" => %{"reason" => "Unsent volume explanation"}
    })

    assert has_element?(recovered, "#maintenance-dynamic-scope")
    assert has_element?(recovered, "#maintenance-reason", "Unsent volume explanation")
    recovered |> form("#maintenance-form") |> render_submit()

    assert has_element?(
             recovered,
             "#maintenance-preview-summary",
             "1 result across 1 scheduled check"
           )

    assert has_element?(recovered, "#maintenance-preview a[href='/checks/#{stream.id}']")
  end

  test "full recovered form retains its target when inventory inserts an earlier scope option" do
    check = publish()

    stream =
      Repo.one!(
        from s in ResultStream, where: s.assignment_id == ^check.id and s.result_key == "volume"
      )

    path = new_path(check.id)
    {:ok, view, _} = live(build_conn(), path <> "&stream_id=" <> stream.id)
    values = %{"name" => "My volume window", "reason" => "Preserve the selected target"}
    view |> form("#maintenance-form", window: values) |> render_change()
    captured = hidden(view, "_proposal")

    selected =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#maintenance-scope option[selected]")
      |> LazyHTML.attribute("value")
      |> hd()

    {:ok, before_seed} = Maintenance.seed(check.id)

    before_index =
      Enum.find_index(before_seed["scope_options"], &(&1["target_key"] == "volume-uid"))

    definition =
      check
      |> Monitoring.public()
      |> Map.take(
        ~w(label definition_revision environment params_owner parameter_schema params interval_seconds timeout_seconds freshness_seconds)
      )
      |> Map.put("key", check.source_key)
      |> Map.put(
        "outputs",
        check.outputs ++
          [
            %{
              "key" => "added",
              "label" => "Added result",
              "target" => %{"key" => "added-uid", "kind" => "volume", "label" => "Added target"}
            }
          ]
      )

    assert {:ok, _} = Inventory.reconcile(inventory([definition], 2), at())
    # Keep the inventory change real, while making the new row's position in
    # the UUID-ordered selector deterministic for the reconnect regression.
    Repo.update_all(
      from(s in ResultStream, where: s.assignment_id == ^check.id and s.result_key == "added"),
      set: [id: "00000000-0000-4000-8000-000000000001"]
    )

    {:ok, after_seed} = Maintenance.seed(check.id)

    assert Enum.find_index(after_seed["scope_options"], &(&1["target_key"] == "volume-uid")) ==
             before_index + 1

    {:ok, recovered, _} = live(build_conn(), path)

    recovered
    |> render_change("recover", %{
      "_proposal" => captured,
      "scope_choice" => selected,
      "window" => values
    })

    assert Jason.decode!(hidden(recovered, "_proposal"))["target_key"] == "volume-uid"
    assert has_element?(recovered, "#maintenance-name[value='My volume window']")
    recovered |> form("#maintenance-form") |> render_submit()
    assert has_element?(recovered, "#maintenance-preview a[href='/checks/#{stream.id}']")
    refute has_element?(recovered, "#maintenance-preview", "Added result")
    save_preview(recovered)
    assert Repo.one!(MaintenanceWindow).target_key == "volume-uid"
  end

  test "native datetime values remain valid while unchanged saves preserve exact timestamps" do
    assert {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")

    proposal =
      Map.merge(seed["proposal"], %{
        "name" => "Precise existing window",
        "reason" => "Initial plan"
      })

    assert {:ok, preview} = Maintenance.preview(proposal)
    assert {:ok, window} = Maintenance.apply(preview["review_token"], proposal)
    {:ok, view, _} = live(build_conn(), "/maintenance/" <> window["id"])

    values =
      for name <- ~w(starts_local ends_local), into: %{} do
        input_id = if name == "starts_local", do: "maintenance-start", else: "maintenance-end"

        value =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query("##{input_id}")
          |> LazyHTML.attribute("value")
          |> hd()

        assert byte_size(value) == 19
        {name, value}
      end

    view
    |> form("#maintenance-form",
      window: Map.put(values, "reason", "Same interval, clearer reason")
    )
    |> render_submit()

    save_preview(view)
    assert {:ok, current} = Maintenance.get(window["id"])
    assert current["starts_at"] == window["starts_at"]
    assert current["ends_at"] == window["ends_at"]
  end

  test "a window becoming active while its start is edited has an explicit review escape" do
    window = save_window()
    {:ok, view, _} = live(build_conn(), "/maintenance/" <> window["id"])
    proposed_start = Monitoring.now() |> DateTime.add(5_400) |> MaintenanceTime.local("UTC")

    view
    |> form("#maintenance-form",
      window: %{starts_local: proposed_start, reason: "Keep this reason"}
    )
    |> render_change()

    # Move the saved boundary across the current clock without changing its
    # revision, representing the time-dependent upcoming-to-active transition.
    started = DateTime.add(Monitoring.now(), -60)

    Repo.update_all(from(w in MaintenanceWindow, where: w.id == ^window["id"]),
      set: [starts_at: started, starts_local: MaintenanceTime.local(started, "UTC")]
    )

    send(view.pid, :tick)
    assert has_element?(view, "#maintenance-start[readonly]")
    assert has_element?(view, "#maintenance-review-current")
    assert has_element?(view, "#maintenance-preview-button[disabled]")
    view |> element("#maintenance-review-current") |> render_click()
    assert has_element?(view, "#maintenance-reason", "Keep this reason")
    refute has_element?(view, "#maintenance-preview-button[disabled]")
    view |> form("#maintenance-form") |> render_submit()
    save_preview(view)
    assert {:ok, current} = Maintenance.get(window["id"])
    assert current["starts_at"] == DateTime.to_iso8601(started)
  end

  defp new_path(id \\ "10000000-0000-4000-8000-000000000001"),
    do: "/maintenance/new?check_id=" <> id

  defp future_values do
    now = Monitoring.now() |> DateTime.truncate(:second)

    %{
      "name" => "Sunday storage work",
      "reason" => "Replace the volume controller",
      "timezone" => "UTC",
      "start_mode" => "scheduled",
      "starts_local" => MaintenanceTime.local(DateTime.add(now, 3_600), "UTC"),
      "ends_local" => MaintenanceTime.local(DateTime.add(now, 7_200), "UTC")
    }
  end

  defp save_preview(view) do
    navigation = view |> form("#maintenance-form") |> render_submit()
    {:ok, saved, _} = follow_redirect(navigation, build_conn())
    saved
  end

  defp save_window do
    assert {:ok, seed} = Maintenance.seed("10000000-0000-4000-8000-000000000001")
    assert {:ok, review} = Maintenance.preview(Map.merge(seed["proposal"], future_values()))
    assert {:ok, window} = Maintenance.apply(review["review_token"], review["proposal"])
    window
  end

  defp hidden(view, name),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#maintenance-form input[name='#{name}']")
      |> LazyHTML.attribute("value")
      |> hd()

  defp recovered_values(encoded) do
    encoded
    |> Jason.decode!()
    |> Map.take(~w(name reason timezone start_mode starts_local ends_local))
    |> Map.update!("starts_local", &String.slice(&1, 0, 19))
    |> Map.update!("ends_local", &String.slice(&1, 0, 19))
  end

  defp elements(view, selector),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.to_tree()

  defp choice_keys(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(".maintenance-picker-rows input[type='checkbox']")
      |> LazyHTML.attribute("value")

  defp selection_recovery(view) do
    document = view |> render() |> LazyHTML.from_document()

    fields =
      for name <- ~w(_proposal _page_selections _filters _selected_only _selected_page),
          into: %{} do
        {name,
         document
         |> LazyHTML.query("#maintenance-selection-form input[name='#{name}']")
         |> LazyHTML.attribute("value")
         |> hd()}
      end

    selected =
      document
      |> LazyHTML.query("#maintenance-selection-form input[type='checkbox'][checked]")
      |> LazyHTML.attribute("value")

    Map.put(fields, "selected_keys", selected)
  end

  defp publish_many(count) do
    definitions =
      for index <- 0..(count - 1) do
        key = index |> Integer.to_string() |> String.pad_leading(3, "0")

        %{
          "key" => "bulk-" <> key,
          "label" => "Bulk check " <> key,
          "definition_revision" => String.duplicate("b", 64),
          "environment" => "production",
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{}},
          "params" => %{},
          "outputs" => [
            %{
              "key" => "health",
              "label" => "Volume " <> key,
              "target" => %{
                "key" => "volume-" <> key,
                "kind" => "volume",
                "label" => "Volume " <> key
              }
            }
          ],
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12
        }
      end

    assert {:ok, _} = Inventory.reconcile(inventory(definitions, 1), at())
  end

  defp publish do
    check = %{
      "key" => "shared",
      "label" => "Shared storage query",
      "definition_revision" => String.duplicate("b", 64),
      "environment" => "production",
      "params_owner" => "source",
      "parameter_schema" => %{"fields" => %{}},
      "params" => %{},
      "outputs" =>
        Enum.map(["volume", "other"], fn key ->
          %{
            "key" => key,
            "label" => key <> " result",
            "target" => %{"key" => key <> "-uid", "kind" => "volume", "label" => key}
          }
        end),
      "interval_seconds" => 3,
      "timeout_seconds" => 2,
      "freshness_seconds" => 12
    }

    assert {:ok, _} = Inventory.reconcile(inventory([check], 1), at())
    Repo.one!(from a in Assignment, where: a.source_id == "maintenance.consumer")
  end

  defp inventory(checks, revision),
    do:
      control()
      |> Map.merge(%{
        "runner_label" => "Storage observer",
        "source_id" => "maintenance.consumer",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => revision,
        "complete" => true,
        "checks" => checks
      })
end

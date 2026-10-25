# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PublisherLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{PublisherLifecycle, SourceInventory, ResultStream}
  alias Mondek.CoverageFixtures, as: F

  @endpoint MondekWeb.Endpoint

  test "missing publications have no action form and publishing runners provide an entry point" do
    {:ok, missing, _} = live(build_conn(), "/coverage/publishers/not-an-id")
    assert has_element?(missing, "#publisher-missing", "Publication not found")
    refute has_element?(missing, "#publisher-lifecycle-form")
    {_publication, source} = publication("Storage observer")
    {:ok, list, _} = live(build_conn(), "/coverage/publishers")
    assert has_element?(list, "a[href='/coverage/publishers/#{source.id}']", "Manage publication")
    {:ok, view, _} = live(build_conn(), path(source))
    assert has_element?(view, "#publisher-heading", "Storage observer")
    assert has_element?(view, "#publisher-summary", "Other observers keep independent evidence")
    assert has_element?(view, "a[href='/checks?runner_id=#{source.runner_id}&status=all']")
  end

  test "retirement requires review and retains administrative history; restore waits for a new publication" do
    {p, source} = publication("Old observer")
    assert {:ok, _} = F.activate(p, Monitoring.now())
    assert disposition(F.sample(p, "CRIT", 1, Monitoring.now())) == "current"
    [incident] = Repo.all(from i in Incident, where: i.status == "open")
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "retire", "Host decommissioned")
    send(view.pid, :tick)
    assert has_element?(view, "#publisher-reason", "Host decommissioned")
    preview(view)
    assert has_element?(view, "#publisher-preview", "Host decommissioned")
    assert has_element?(view, "#publisher-apply:not([disabled])")
    token = hidden(view, "_review_token")
    send(view.pid, :tick)
    assert hidden(view, "_review_token") == token
    apply_review(view)
    assert has_element?(view, "#publisher-status", "Retired from this controller")
    assert has_element?(view, "#publisher-history", "Host decommissioned")
    assert Repo.get!(Incident, incident.id).closure_reason == "publisher_retired"
    assert active_results(source) == 0

    assert has_element?(
             view,
             "a[href='/coverage?source_id=#{source.source_id}']",
             "Current scopes from remaining publishers"
           )

    edit(view, "restore", "Return this deployment")
    preview(view)

    assert has_element?(
             view,
             "#publisher-preview",
             "Restored checks use defaults from code and matching configuration rules"
           )

    assert has_element?(
             view,
             "#publisher-preview",
             "Individual check exceptions and acknowledgements remain with retired instances"
           )

    apply_review(view)
    assert has_element?(view, "#publisher-status", "Waiting for a new publication")
    assert has_element?(view, "#publisher-summary", "does not revive previous health")
    assert active_results(source) == 0
    {:ok, coverage, _} = live(build_conn(), "/coverage")
    assert has_element?(coverage, "#coverage-restoration-warning", "waiting for a new inventory")
    {:ok, waiting, _} = live(build_conn(), "/coverage/publishers?lifecycle=awaiting_inventory")

    assert has_element?(
             waiting,
             "[data-publisher-id='#{source.id}']",
             "Waiting for a new publication"
           )

    refute has_element?(waiting, "[data-publisher-id='#{source.id}'] a", "Declared scopes")
  end

  test "replacement choices remain source scoped and fresh Critical evidence qualifies" do
    {_old, source} = publication("Old observer")
    {new, successor} = publication("New observer")
    {_other, other} = publication("Other project", "different-source")
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "replace", "Move collection")
    render_change(view, "recover", recovery(view))
    assert has_element?(view, "#publisher-selected-successor", "No replacement selected")
    assert has_element?(view, "[data-successor-id='#{successor.id}']", "New observer")
    refute has_element?(view, "[data-successor-id='#{other.id}']")
    view |> element("[data-successor-id='#{successor.id}'] button") |> render_click()
    edit(view, "retire", "Move collection")
    edit(view, "replace", "Move collection")
    assert has_element?(view, "#publisher-selected-successor", "No replacement selected")
    view |> element("[data-successor-id='#{successor.id}'] button") |> render_click()
    preview(view)
    assert has_element?(view, "#publisher-apply[disabled]")
    assert has_element?(view, "#publisher-preview-blockers")
    assert {:ok, _} = F.activate(new, Monitoring.now())
    assert disposition(F.sample(new, "CRIT", 1, Monitoring.now())) == "current"
    view |> element("button", "Discard review") |> render_click()
    preview(view)
    assert has_element?(view, "#publisher-apply:not([disabled])")
    apply_review(view)
    assert has_element?(view, "#publisher-status", "Retired from this controller")
    assert has_element?(view, "#publisher-history", "Replacement recorded")

    view
    |> element("#publisher-history a", "Inspect saved decision and evidence")
    |> render_click()

    assert has_element?(view, "#publisher-saved-decision", "Critical")
    assert has_element?(view, "#publisher-saved-decision", "Saved replacement evidence reference")
  end

  test "recovery preserves the exact review token but offline edits require a fresh review" do
    {_p, source} = publication("Observer")
    {:ok, first, _} = live(build_conn(), path(source))
    edit(first, "retire", "Planned retirement")
    preview(first)
    captured = recovery(first)
    {:ok, recovered, _} = live(build_conn(), path(source))
    render_change(recovered, "recover", captured)
    assert hidden(recovered, "_review_token") == captured["_review_token"]
    assert has_element?(recovered, "#publisher-apply:not([disabled])")
    assert has_element?(recovered, "#publisher-reason", "Planned retirement")

    render_change(
      recovered,
      "recover",
      put_in(captured, ["lifecycle", "reason"], "Edited offline")
    )

    assert has_element?(recovered, "#publisher-reason", "Edited offline")
    refute has_element?(recovered, "#publisher-preview")
    render_change(recovered, "recover", %{"_proposal" => Jason.encode!(%{"publisher_id" => %{}})})
    assert has_element?(recovered, "#publisher-error", "could not be restored")
  end

  test "membership changes invalidate the original review without discarding the draft" do
    {p, source} = publication("Observer")
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "retire", "Remove source")
    preview(view)
    token = hidden(view, "_review_token")

    changed =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("checks", [])
      |> put_in(["coverage", "candidates"], [])

    assert {:ok, _} = Monitoring.inventory(changed, Monitoring.now())
    send(view.pid, :tick)
    assert has_element?(view, "#publisher-preview", "no longer current")
    assert has_element?(view, "#publisher-apply[disabled]")
    assert hidden(view, "_review_token") == token
    assert has_element?(view, "#publisher-reason", "Remove source")
    apply_review(view)
    refute Repo.get!(SourceInventory, source.id).retired_at
  end

  test "impact paging and saved decisions retain full counts and drafts" do
    candidates =
      for n <- 1..31,
          do: F.candidate(F.check("check-#{String.pad_leading(to_string(n), 2, "0")}"), false)

    p = F.publication(candidates)
    assert {:ok, _} = Monitoring.inventory(p, Monitoring.now())
    source = source(p)
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "retire", "Remove catalogue")
    preview(view)
    assert has_element?(view, "#publisher-impact summary", "31")

    assert Enum.count(LazyHTML.query(LazyHTML.from_document(render(view)), "[data-impact-scope]")) ==
             25

    token = hidden(view, "_review_token")
    view |> element("#publisher-impact-pages button", "Next") |> render_click()
    assert hidden(view, "_review_token") == token
    assert has_element?(view, "#publisher-impact-pages", "Page 2 of 2")

    assert Enum.count(LazyHTML.query(LazyHTML.from_document(render(view)), "[data-impact-scope]")) ==
             6

    apply_review(view)
    edit(view, "restore", "Retain this draft while inspecting history")

    view
    |> element("#publisher-history a", "Inspect saved decision and evidence")
    |> render_click()

    assert has_element?(view, "#publisher-saved-decision", "31 affected result declarations")
    view |> element("#publisher-saved-decision-pages a", "Next") |> render_click()
    assert has_element?(view, "#publisher-saved-decision", "page 2 of 2")
    assert has_element?(view, "#publisher-reason", "Retain this draft while inspecting history")
  end

  test "replaying a saved retirement reports the newer publication state honestly" do
    {_p, source} = publication("Observer")
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "retire", "First decision")
    preview(view)
    proposal = Jason.decode!(hidden(view, "_proposal"))
    assert {:ok, _} = PublisherLifecycle.apply(hidden(view, "_review_token"), proposal)

    assert {:ok, restore} =
             PublisherLifecycle.preview(%{
               "publisher_id" => source.id,
               "action" => "restore",
               "reason" => "Second decision"
             })

    assert {:ok, _} = PublisherLifecycle.apply(restore["review_token"], restore["proposal"])
    apply_review(view)
    assert has_element?(view, "#publisher-notice", "already recorded")
    assert has_element?(view, "#publisher-status", "Waiting for a new publication")
    refute has_element?(view, "#publisher-notice", "Stop or remove")
  end

  test "restore replay after fresh publication acceptance does not claim it is still waiting" do
    {p, source} = publication("Returning observer")

    assert {:ok, retire} =
             PublisherLifecycle.preview(%{
               "publisher_id" => source.id,
               "action" => "retire",
               "reason" => "Retire"
             })

    assert {:ok, _} = PublisherLifecycle.apply(retire["review_token"], retire["proposal"])
    {:ok, view, _} = live(build_conn(), path(source))
    edit(view, "restore", "Restore")
    preview(view)

    assert {:ok, _} =
             PublisherLifecycle.apply(
               hidden(view, "_review_token"),
               Jason.decode!(hidden(view, "_proposal"))
             )

    refreshed =
      p
      |> Map.put("inventory_revision", 2)
      |> Map.put("restoration_revision", Repo.get!(SourceInventory, source.id).lifecycle_revision)

    assert {:ok, _} = Monitoring.inventory(refreshed, Monitoring.now())
    apply_review(view)
    assert has_element?(view, "#publisher-status", "Active publication")
    assert has_element?(view, "#publisher-notice", "publication has changed")
    refute has_element?(view, "#publisher-notice", "Waiting for a new publication")
  end

  test "saved measurement remains inspectable after current result history advances and cannot leak across events" do
    {_old, predecessor} = publication("Predecessor")
    {p, successor} = publication("Replacement")
    now = Monitoring.now()
    assert {:ok, _} = F.activate(p, now)
    [assignment] = F.assignments(p)

    report =
      measurement("OK", 1, %{
        "assignment_id" => assignment.id,
        "installation_id" => p["installation_id"],
        "session_id" => p["session_id"],
        "generation" => assignment.desired_generation,
        "started_at" => Monitoring.iso(now),
        "evaluated_at" => Monitoring.iso(now),
        "results" => [
          %{
            "key" => "health",
            "health" => "OK",
            "summary" => "Original readiness witness",
            "details" => "Original consumer details\nSecond retained line",
            "value" => 42,
            "source_at" => Monitoring.iso(now)
          }
        ]
      })

    assert disposition(
             Monitoring.ingest(
               envelope([report], Map.take(p, ~w(installation_id session_id))),
               now
             )
           ) == "current"

    proposal = %{
      "publisher_id" => predecessor.id,
      "action" => "replace",
      "successor_id" => successor.id,
      "reason" => "Save exact readiness evidence"
    }

    assert {:ok, review} = PublisherLifecycle.preview(proposal)
    assert {:ok, receipt} = PublisherLifecycle.apply(review["review_token"], review["proposal"])
    event_id = receipt["receipt"]["id"]

    for sequence <- 2..36,
        do:
          assert(
            disposition(F.sample(p, "OK", sequence, DateTime.add(now, sequence, :millisecond))) ==
              "current"
          )

    {:ok, view, _} =
      live(build_conn(), path(predecessor) <> "?event_id=#{event_id}&event_page=1&history_page=1")

    edit(view, "restore", "Unsaved restoration draft")
    view |> element("#publisher-saved-decision a", "Inspect saved measurement") |> render_click()

    assert has_element?(
             view,
             "#publisher-saved-measurement[data-observation-id='#{report["id"]}']"
           )

    assert has_element?(view, "#publisher-saved-measurement", "Original readiness witness")
    assert has_element?(view, "#publisher-saved-measurement", "Original consumer details")
    assert has_element?(view, "#publisher-saved-measurement", "Second retained line")
    assert has_element?(view, "#publisher-saved-measurement", "Measured value: 42")

    assert has_element?(
             view,
             "#publisher-saved-measurement time[datetime='#{report["evaluated_at"]}']"
           )

    assert has_element?(view, "#publisher-saved-measurement", p["session_id"])
    assert has_element?(view, "#publisher-reason", "Unsaved restoration draft")
    refute has_element?(view, "#publisher-saved-measurement", "Measured OK")
    send(view.pid, :tick)
    assert has_element?(view, "#publisher-saved-measurement", "Original readiness witness")

    render_patch(view, path(predecessor) <> "?event_id=#{event_id}")
    refute has_element?(view, "#publisher-saved-measurement")

    render_patch(
      view,
      path(predecessor) <> "?event_id=#{event_id}&evidence_id=#{Ecto.UUID.generate()}"
    )

    assert has_element?(view, "#publisher-saved-measurement-missing", "No retained measurement")

    refute has_element?(
             view,
             "#publisher-saved-measurement",
             "This is the original measurement retained"
           )

    refute has_element?(view, "#publisher-saved-measurement", "Original readiness witness")

    assert {:ok, restore} =
             PublisherLifecycle.preview(%{
               "publisher_id" => predecessor.id,
               "action" => "restore",
               "reason" => "Another saved decision"
             })

    assert {:ok, restored} =
             PublisherLifecycle.apply(restore["review_token"], restore["proposal"])

    render_patch(
      view,
      path(predecessor) <> "?event_id=#{restored["receipt"]["id"]}&evidence_id=#{report["id"]}"
    )

    assert has_element?(view, "#publisher-saved-measurement-missing", "No retained measurement")
    refute has_element?(view, "#publisher-saved-measurement", "Original readiness witness")
  end

  test "excluded scope measurements remain context rather than retained decision witnesses" do
    selected = F.candidate(F.check("selected"))
    excluded = F.candidate(F.check("excluded"), false)
    predecessor = F.publication([selected, excluded])

    successor =
      F.publication([
        selected,
        Map.put(excluded, "selected", true) |> Map.put("exclusion_reason", nil)
      ])

    now = Monitoring.now()
    for p <- [predecessor, successor], do: assert({:ok, _} = Monitoring.inventory(p, now))
    assert {:ok, _} = F.activate(successor, now)

    for assignment <- F.assignments(successor) do
      report =
        measurement("OK", 1, %{
          "assignment_id" => assignment.id,
          "installation_id" => successor["installation_id"],
          "session_id" => successor["session_id"],
          "generation" => assignment.desired_generation,
          "started_at" => Monitoring.iso(now),
          "evaluated_at" => Monitoring.iso(now),
          "results" => [
            %{
              "key" => "health",
              "health" => "OK",
              "summary" => "Measured context",
              "source_at" => Monitoring.iso(now)
            }
          ]
        })

      assert disposition(
               Monitoring.ingest(
                 envelope([report], Map.take(successor, ~w(installation_id session_id))),
                 now
               )
             ) == "current"
    end

    old = source(predecessor)

    proposal = %{
      "publisher_id" => old.id,
      "action" => "replace",
      "successor_id" => source(successor).id,
      "reason" => "Replace selected scopes"
    }

    assert {:ok, review} = PublisherLifecycle.preview(proposal)
    assert {:ok, receipt} = PublisherLifecycle.apply(review["review_token"], review["proposal"])
    {:ok, view, _} = live(build_conn(), path(old) <> "?event_id=#{receipt["receipt"]["id"]}")

    assert Enum.count(
             LazyHTML.query(
               LazyHTML.from_document(render(view)),
               "#publisher-saved-decision a[href*='evidence_id=']"
             )
           ) == 1

    refute has_element?(
             view,
             "#publisher-saved-decision article:first-of-type a",
             "Inspect saved measurement"
           )

    refute has_element?(
             view,
             "#publisher-saved-decision article:first-of-type summary",
             "Saved replacement evidence reference"
           )

    assert has_element?(
             view,
             "#publisher-saved-decision article:first-of-type",
             "Replacement's last measured health at the decision: Healthy"
           )
  end

  defp publication(label, source_id \\ "coverage-test") do
    p =
      F.publication([F.candidate(F.check())], %{"runner_label" => label, "source_id" => source_id})

    assert {:ok, _} = Monitoring.inventory(p, Monitoring.now())
    {p, source(p)}
  end

  defp source(p),
    do: Repo.get_by!(SourceInventory, runner_id: p["installation_id"], source_id: p["source_id"])

  defp active_results(source),
    do:
      Repo.aggregate(
        from(s in ResultStream,
          join: a in Assignment,
          on: a.id == s.assignment_id,
          where:
            a.runner_id == ^source.runner_id and a.source_id == ^source.source_id and
              is_nil(s.retired_at)
        ),
        :count
      )

  defp path(source), do: "/coverage/publishers/#{source.id}"

  defp edit(view, action, reason),
    do:
      view
      |> form("#publisher-lifecycle-form", %{
        "lifecycle" => %{"action" => action, "reason" => reason}
      })
      |> render_change()

  defp preview(view), do: view |> form("#publisher-lifecycle-form") |> render_submit()
  defp apply_review(view), do: render_submit(view, "apply", recovery(view))

  defp recovery(view) do
    proposal = hidden(view, "_proposal")
    draft = Jason.decode!(proposal)

    %{
      "_proposal" => proposal,
      "_review_token" => hidden(view, "_review_token"),
      "_preview_page" => hidden(view, "_preview_page"),
      "lifecycle" =>
        Map.new(Map.take(draft, ~w(action reason successor_id)), fn {k, v} ->
          {k, to_string(v)}
        end)
    }
  end

  defp hidden(view, name) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("input[name='#{name}']")
    |> LazyHTML.attribute("value")
    |> List.first()
  end
end

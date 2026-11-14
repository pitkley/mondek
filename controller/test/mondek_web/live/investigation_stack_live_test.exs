# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationStackLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{CoverageFixtures, Inspection}
  alias MondekWeb.{InvestigationTrail, PreviewIncidentControls}
  @endpoint MondekWeb.Endpoint
  @moduletag :empty_source_fixture

  test "incident draft and captured authority survive related result, rewind, forward, tick and presentation" do
    {incident, result} = failure()
    token = "health:#{incident.id}"
    base = "/next/incidents/health/#{incident.id}"
    {:ok, view, _} = live(build_conn(), base)

    review =
      PreviewIncidentControls.revision(
        Monitoring.incident_detail(incident.id, Monitoring.now())["incident"]
      )

    draft = %{"mode" => "duration", "amount" => "3", "unit" => "hours", "note" => "Investigating"}
    view |> form("#preview-incident-ack-form", mode: "duration") |> render_change()
    view |> form("#preview-incident-ack-form", draft) |> render_change()
    assert has_element?(view, "textarea[name=note]", "Investigating")

    result_path = href(view, "#overview-panel a", "View latest check result")
    view |> element("#overview-panel a", "View latest check result") |> render_click()
    assert_patch(view, result_path)
    assert has_element?(view, "#overview-panel-title", result["label"])
    assert has_element?(view, "[data-panel-back-path]")

    # A crafted event naming an inactive rear entity must not submit its form.
    view
    |> with_target("#investigation-stack")
    |> render_hook("save_acknowledgement", Map.put(draft, "entity", token))

    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
    previous = href(view, "[data-overview-close]", "Back one level")
    render_patch(view, previous)
    assert has_element?(view, "textarea[name=note]", "Investigating")
    render_patch(view, result_path)
    render_patch(view, previous)
    send(view.pid, :tick)
    assert has_element?(view, "textarea[name=note]", "Investigating")

    page = href(view, "#overview-panel a", "Open as page")
    render_patch(view, page)
    assert has_element?(view, "#incident-page textarea[name=note]", "Investigating")
    refute has_element?(view, "#overview-panel")
    view |> element("#incident-page a", "Open fly-over") |> render_click()
    assert has_element?(view, "#overview-panel textarea[name=note]", "Investigating")

    # A remote write must not silently renew the review captured before leaving.
    assert {:ok, _} =
             Monitoring.acknowledge(
               incident.id,
               Map.put(review, "mode", "until_incident_ends"),
               "Other operator"
             )

    send(view.pid, :tick)

    view
    |> with_target("#investigation-stack")
    |> render_hook("save_acknowledgement", Map.put(draft, "entity", token))

    assert has_element?(view, "[role=alert]", "The incident changed")
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Other operator"
    assert has_element?(view, "#overview-panel", "Other operator")
  end

  test "a direct full page root shares identity and draft state with its overlays" do
    {incident, _result} = failure()
    base = "/next/incidents/health/#{incident.id}/full"
    {:ok, view, _} = live(build_conn(), base)
    view |> form("#preview-incident-ack-form", note: "Keep this root") |> render_change()
    view |> element("#incident-page a", "View latest check result") |> render_click()
    assert has_element?(view, "#incident-page[inert]")
    assert has_element?(view, "#overview-panel-title")
    view |> element("#overview-panel a", "Open as page") |> render_click()
    assert has_element?(view, "#preview-result-page #full-result-heading")
    refute has_element?(view, "#overview-panel")
    view |> element("#preview-result-page a", "Open fly-over") |> render_click()
    assert has_element?(view, "#incident-page[inert]")
    # A link back to the root reactivates it, without creating a duplicate card.
    view |> element("#overview-panel a", "View incident") |> render_click()
    refute has_element?(view, "#overview-panel")
    assert has_element?(view, "#incident-page textarea[name=note]", "Keep this root")
    refute has_element?(view, "[data-panel-back-path]")
  end

  test "retry reason belongs to the incident and is retained across a related result" do
    {incident, _} = failure()
    occurrence = Repo.one!(Occurrence)
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    Monitoring.change(occurrence, %{status: "exhausted"})
    {:ok, view, _} = live(build_conn(), "/next/incidents/health/#{incident.id}")
    selector = "#preview-retry-#{occurrence.id}"
    view |> form(selector, reason: "Receiver repaired") |> render_change()
    view |> element("#overview-panel a", "View latest check result") |> render_click()
    view |> element("[data-overview-close]") |> render_click()
    assert has_element?(view, selector <> " input[name=reason][value='Receiver repaired']")
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
  end

  test "signed recovery restores an inactive incident and its old review without writes" do
    {incident, _} = failure()
    {:ok, view, _} = live(build_conn(), "/next/incidents/health/#{incident.id}")
    view |> form("#preview-incident-ack-form", note: "Keep through reconnect") |> render_change()
    result_path = href(view, "#overview-panel a", "View latest check result")
    view |> element("#overview-panel a", "View latest check result") |> render_click()
    snapshot = input_value(view, "#investigation-stack-recovery input[name=snapshot]")
    {:ok, recovered, _} = live(build_conn(), result_path)

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    recovered |> element("[data-overview-close]") |> render_click()
    assert has_element?(recovered, "textarea[name=note]", "Keep through reconnect")
    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))

    # Invalid tokens and a token for a different host do not restore authority.
    {:ok, other, _} = live(build_conn(), "/next?inspect=health%3A#{incident.id}")

    other
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    refute has_element?(other, "textarea[name=note]", "Keep through reconnect")

    other
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => "forged"})

    refute Monitoring.acknowledgement_active?(Repo.get!(Incident, incident.id))
  end

  test "replacement forms recover without silently reviewing a newer revision" do
    {incident, _} = failure()
    current = Monitoring.incident_detail(incident.id, Monitoring.now())["incident"]
    review = PreviewIncidentControls.revision(current)

    assert {:ok, _} =
             Monitoring.acknowledge(
               incident.id,
               Map.put(review, "mode", "until_incident_ends"),
               "Original"
             )

    path = "/next/incidents/health/#{incident.id}"
    {:ok, view, _} = live(build_conn(), path)
    view |> element("button", "Replace acknowledgement") |> render_click()
    view |> form("#preview-incident-ack-form", note: "Replacement draft") |> render_change()
    snapshot = input_value(view, "#investigation-stack-recovery input[name=snapshot]")

    newer_review =
      PreviewIncidentControls.revision(Monitoring.incident_detail(incident.id)["incident"])

    assert {:ok, _} =
             Monitoring.acknowledge(
               incident.id,
               Map.put(newer_review, "mode", "until_incident_ends"),
               "Changed elsewhere"
             )

    {:ok, recovered, _} = live(build_conn(), path)
    refute has_element?(recovered, "#preview-incident-ack-form")

    recovered
    |> with_target("#investigation-stack")
    |> render_hook("recover_investigation", %{"snapshot" => snapshot})

    assert has_element?(recovered, "textarea[name=note]", "Replacement draft")
    recovered |> form("#preview-incident-ack-form", note: "Replacement draft") |> render_submit()
    assert has_element?(recovered, "[role=alert]", "The incident changed")
    assert Repo.get!(Incident, incident.id).acknowledgement_note == "Changed elsewhere"
  end

  test "retained entity bound preserves earlier drafts when a seventeenth identity is requested" do
    {incident, _} = failure()
    base = "/next/incidents/health/#{incident.id}"
    {:ok, view, _} = live(build_conn(), base)
    view |> form("#preview-incident-ack-form", note: "Retained at capacity") |> render_change()

    for _ <- 1..15 do
      render_patch(
        view,
        InvestigationTrail.path(base, [{"health", incident.id}, {"result", Ecto.UUID.generate()}])
      )
    end

    render_patch(
      view,
      InvestigationTrail.path(base, [{"health", incident.id}, {"result", Ecto.UUID.generate()}])
    )

    assert has_element?(view, "[role=alert]", "This investigation is full")
    render_patch(view, InvestigationTrail.path(base, [{"health", incident.id}]))
    assert has_element?(view, "textarea[name=note]", "Retained at capacity")
  end

  test "promoted pages deduplicate their full prefix and cannot exceed the six-entity bound" do
    {incident, result} = failure()
    base = "/next/incidents/health/#{incident.id}"
    {:ok, view, _} = live(build_conn(), base)
    view |> form("#preview-incident-ack-form", note: "Prefix draft") |> render_change()

    trail =
      [{"health", incident.id}] ++
        for(_ <- 1..4, do: {"result", Ecto.UUID.generate()}) ++ [{"result", result["id"]}]

    page =
      InvestigationTrail.path(base, trail, %{
        "surface" => "page",
        "page_entity" => "result:#{result["id"]}"
      })

    render_patch(view, page)
    assert has_element?(view, "#preview-result-page")
    assert has_element?(view, "[role=alert]", "This investigation is full")
    view |> element("#preview-result-page a", "View incident") |> render_click()
    assert has_element?(view, "#overview-panel textarea[name=note]", "Prefix draft")
    refute has_element?(view, "#preview-result-page")

    root = base <> "/full"

    {:ok, direct, _} =
      live(
        build_conn(),
        InvestigationTrail.path(
          root,
          Enum.map(1..6, fn _ -> {"result", Ecto.UUID.generate()} end)
        )
      )

    assert has_element?(direct, "#incident-page")
    refute has_element?(direct, "#overview-panel")

    {:ok, malformed, _} =
      live(build_conn(), "/next?inspect=bad&surface=page&page_entity=health%3A#{incident.id}")

    refute has_element?(malformed, "#incident-page")
    refute has_element?(malformed, "#overview-panel")
    {:ok, malformed_shape, _} = live(build_conn(), "/next?surface=page&page_entity[]=x")
    refute has_element?(malformed_shape, "#overview-panel")
  end

  test "typed trails reject malformed, repeated and oversized identities and deduplicate roots" do
    ids = for _ <- 1..7, do: {"result", Ecto.UUID.generate()}

    assert {:ok, Enum.take(ids, 6)} ==
             InvestigationTrail.parse(
               Enum.map_join(Enum.take(ids, 6), ",", &InvestigationTrail.token/1)
             )

    assert :error ==
             InvestigationTrail.parse(Enum.map_join(ids, ",", &InvestigationTrail.token/1))

    assert :error == InvestigationTrail.parse("result:not-an-id")
    assert :error == InvestigationTrail.parse(String.duplicate("x", 8193))

    assert :error ==
             InvestigationTrail.parse(
               Enum.map_join([hd(ids), hd(ids)], ",", &InvestigationTrail.token/1)
             )

    assert {:ok, [hd(ids)]} == InvestigationTrail.open(Enum.take(ids, 3), hd(ids))
    assert {:ok, []} == InvestigationTrail.open(Enum.take(ids, 3), hd(ids), hd(ids))
    assert {:error, :limit} == InvestigationTrail.open(Enum.take(ids, 6), List.last(ids))
    {:ok, view, _} = live(build_conn(), "/next?inspect=result%3Anot-an-id")
    refute has_element?(view, "#overview-panel")
  end

  defp input_value(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("input")
    |> LazyHTML.attribute("value")
    |> hd()
  end

  defp failure do
    now = Monitoring.now()

    candidate =
      CoverageFixtures.candidate(CoverageFixtures.check("Queue depth", "production", "Queue"))

    publication = CoverageFixtures.publication([candidate])
    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = CoverageFixtures.activate(publication, now)
    assert disposition(CoverageFixtures.sample(publication, "CRIT", 1, now)) == "current"
    [result] = Inspection.overview_results(%{}, now).attention.items
    {Repo.one!(Incident), result}
  end

  defp href(view, selector, text) do
    view
    |> element(selector, text)
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("a")
    |> LazyHTML.attribute("href")
    |> hd()
  end
end

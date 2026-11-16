# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CorrelationTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  import OpenApiSpex.TestAssertions
  @endpoint MondekWeb.Endpoint

  defp episode do
    connect()
    ingest(measurement("CRIT"))
    ref(Repo.one!(Incident))
  end

  defp ref(row), do: %{"type" => "individual", "id" => row.id}

  defp proposal(episodes),
    do: %{
      "action" => "create",
      "request_id" => Ecto.UUID.generate(),
      "title" => "Network outage",
      "reason" => "Related failures",
      "episodes" => episodes
    }

  defp post_json(path, body),
    do:
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  test "HTTP schemas, read-only MCP and retained evidence" do
    e = episode()
    conn = post_json("/api/v1/incidents/correlation/preview", proposal([e]))
    review = json_response(conn, 200)
    assert_operation_response(conn)

    conn =
      post_json("/api/v1/incidents/correlation/apply", %{"review_token" => review["review_token"]})

    id = json_response(conn, 200)["case_id"]
    assert_operation_response(conn)

    for path <- [
          "/api/v1/incidents/candidates",
          "/api/v1/incidents/cases",
          "/api/v1/incidents/cases/#{id}"
        ] do
      conn = get(build_conn(), path)
      assert json_response(conn, 200)["data"]
      assert_operation_response(conn)
    end

    conn = get(build_conn(), "/api/v1/incidents/health/#{e["id"]}")
    assert json_response(conn, 200)["data"]["incident"]["correlation"]["case_id"] == id
    assert_operation_response(conn)
    assert {:ok, data} = Mondek.AgentInspection.call("get_case", %{"case_id" => id})
    assert data["case"]["id"] == id
    assert {:ok, listing} = Mondek.AgentInspection.call("list_cases", %{})
    assert length(listing["items"]) == 1
    assert json_response(get(build_conn(), "/api/v1/incidents/cases/#{id}?page=0"), 422)
    assert json_response(get(build_conn(), "/api/v1/incidents/cases/#{id}?unknown=yes"), 400)
  end

  test "real LiveView form creates a case and canonical detail exposes controls" do
    e = episode()
    {:ok, view, _} = live(build_conn(), "/incidents/cases")

    render_submit(
      form(view, "#grouping-form",
        grouping: %{
          action: "create",
          title: "Network outage",
          reason: "Shared failure",
          episodes: ["individual:" <> e["id"]],
          anchor: "individual:" <> e["id"],
          other_case_id: ""
        }
      )
    )

    assert has_element?(view, "#correlation-review")

    assert {:error, {:live_redirect, %{to: path}}} =
             view |> element("#correlation-review button") |> render_click()

    {:ok, detail, _} = live(build_conn(), path)
    assert has_element?(detail, "#case-detail", "Network outage")
    assert has_element?(detail, "#case-detail", "Suspected parent")
    assert has_element?(detail, "#grouping-action option[value=detach]")
    assert has_element?(detail, "#case-detail", "Local operator")
    assert render(detail) =~ "Native controls remain independent"
  end

  test "maximum size review token works through HTTP" do
    refs =
      for n <- 1..250 do
        c =
          Repo.insert!(%Mondek.ConditionIncident{
            namespace: "test",
            key: "scope-#{n}",
            label: "Scope #{n}",
            health: "CRIT",
            opened_at: at()
          })

        %{"type" => "condition", "id" => c.id}
      end

    conn = post_json("/api/v1/incidents/correlation/preview", proposal(refs))
    review = json_response(conn, 200)
    assert_operation_response(conn)
    assert byte_size(review["review_token"]) > 8192

    conn =
      post_json("/api/v1/incidents/correlation/apply", %{"review_token" => review["review_token"]})

    assert json_response(conn, 200)["case_id"]
    assert_operation_response(conn)
  end

  test "mixed case identities normalize before duplicate and self merge checks" do
    e = episode()
    copy = Map.update!(e, "id", &String.upcase/1)

    assert json_response(
             post_json("/api/v1/incidents/correlation/preview", proposal([e, copy])),
             422
           )

    {:ok, review} = Mondek.Correlations.preview(proposal([e]))
    {:ok, receipt} = Mondek.Correlations.apply(review["review_token"])

    p = %{
      "action" => "merge",
      "request_id" => Ecto.UUID.generate(),
      "reason" => "Invalid self merge",
      "case_id" => receipt["case_id"],
      "other_case_id" => String.upcase(receipt["case_id"])
    }

    assert json_response(post_json("/api/v1/incidents/correlation/preview", p), 422)
  end

  test "merge UI accepts plain case id and reviews both cases" do
    a = episode()
    {:ok, draft} = Mondek.Correlations.preview(proposal([a]))
    {:ok, receipt} = Mondek.Correlations.apply(draft["review_token"])
    original = receipt["case_id"]

    {:ok, other} =
      create_source_fixture("python", "App", %{
        "path" => "/",
        "warn_percent" => 80,
        "crit_percent" => 90
      })

    connect(%{"prepared" => %{other["id"] => 1}})
    ingest(measurement("CRIT", 1, %{"assignment_id" => other["id"]}))
    i = Repo.get_by!(Incident, assignment_id: other["id"])
    {:ok, review} = Mondek.Correlations.preview(proposal([ref(i)]))
    {:ok, receipt} = Mondek.Correlations.apply(review["review_token"])
    source = receipt["case_id"]
    {:ok, view, _} = live(build_conn(), "/incidents/cases/#{original}")

    render_submit(
      form(view, "#grouping-form",
        grouping: %{
          action: "merge",
          title: "",
          reason: "One outage",
          other_case_id: source,
          anchor: ""
        }
      )
    )

    assert has_element?(view, "#correlation-review", source)
    assert has_element?(view, "#correlation-review", original)
    render_click(element(view, "#correlation-review button"))
    assert Mondek.Correlations.detail(original)["case"]["member_count"] == 2
    assert Mondek.Correlations.detail(source)["case"]["status"] == "closed"
  end

  defp synthetic_sources(count) do
    for n <- 1..count do
      {:ok, a} =
        create_source_fixture("python", "Scope #{n}", %{
          "path" => "/",
          "warn_percent" => 80,
          "crit_percent" => 90
        })

      connect(%{"prepared" => %{a["id"] => 1}})

      assert disposition(ingest(measurement("CRIT", 1, %{"assignment_id" => a["id"]}))) ==
               "current"
    end
  end

  test "off-page selection and anchor survive draft changes" do
    synthetic_sources(21)
    [a | _] = Mondek.Correlations.candidates(%{"page" => 1}, at())["items"]
    [b | _] = Mondek.Correlations.candidates(%{"page" => 2}, at())["items"]
    first = a["incident_type"] <> ":" <> a["id"]
    second = b["incident_type"] <> ":" <> b["id"]
    {:ok, view, _} = live(build_conn(), "/incidents/cases")

    render_change(
      form(view, "#grouping-form",
        grouping: %{
          action: "create",
          title: "Review",
          reason: "Testing selection",
          episodes: [first],
          anchor: first,
          other_case_id: ""
        }
      )
    )

    view |> element("a", "More episodes") |> render_click()
    assert has_element?(view, "input[type=hidden][value='#{first}']")
    assert has_element?(view, "#case-anchor option[selected][value='#{first}']")

    render_submit(
      form(view, "#grouping-form",
        grouping: %{
          episodes: [first, second],
          title: "Review",
          reason: "Across pages",
          anchor: first,
          action: "create",
          other_case_id: ""
        }
      )
    )

    assert has_element?(view, "#correlation-review", a["id"])
    assert has_element?(view, "#correlation-review", b["id"])
  end

  test "HTTP and UI review case acknowledgement and batch policy" do
    e = episode()
    {:ok, r} = Mondek.Correlations.preview(proposal([e]))
    {:ok, r} = Mondek.Correlations.apply(r["review_token"])
    id = r["case_id"]

    p = %{
      "action" => "enable",
      "request_id" => Ecto.UUID.generate(),
      "note" => "Batch exact work"
    }

    conn = post_json("/api/v1/incidents/cases/#{id}/control/preview", p)
    r = json_response(conn, 200)
    assert_operation_response(conn)

    conn =
      post_json("/api/v1/incidents/cases/control/apply", %{"review_token" => r["review_token"]})

    assert json_response(conn, 200)
    assert_operation_response(conn)
    {:ok, v, _} = live(build_conn(), "/incidents/cases/#{id}")

    v
    |> form("#case-control-form",
      control: %{action: "acknowledge", note: "Reviewed exact members", seconds: "60"}
    )
    |> render_submit()

    assert has_element?(v, "#case-control-review", "Ceiling:")
    assert {:error, {:live_redirect, _}} = render_click(element(v, "#case-control-review button"))
    refute is_nil(Mondek.CaseControls.latest(id))
    assert {:ok, data} = Mondek.AgentInspection.call("get_case", %{"case_id" => id})
    assert data["delivery"].acknowledgement.active
    conn = get(build_conn(), "/api/v1/incidents/cases/#{id}")
    assert json_response(conn, 200)["data"]["delivery"]["acknowledgement"]["active"]
    assert_operation_response(conn)
  end
end

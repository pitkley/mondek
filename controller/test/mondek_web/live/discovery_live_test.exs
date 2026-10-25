# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DiscoveryLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{CoverageFixtures, Discovery, ResultStream}
  @endpoint MondekWeb.Endpoint

  setup do
    now = Monitoring.now()

    publication =
      CoverageFixtures.publication([CoverageFixtures.candidate(CoverageFixtures.check())])

    assert {:ok, _} = Monitoring.inventory(publication, now)
    assert {:ok, _} = CoverageFixtures.activate(publication, now)
    [assignment] = CoverageFixtures.assignments(publication)
    stream = Repo.get_by!(ResultStream, assignment_id: assignment.id)
    evidence = discovery()
    report = measure(publication, evidence, 1, now)
    %{publication: publication, stream: stream, discovery: evidence, now: now, report: report}
  end

  test "incident investigation separates updated findings from opening history and returns from discovery",
       ctx do
    incident = Repo.get_by!(Incident, stream_id: ctx.stream.id)
    {:ok, view, _} = live(build_conn(), "/incidents/#{incident.id}")
    assert has_element?(view, "#incident-check-now h2", "Latest measurement")
    refute has_element?(view, "#incident-measurements[open]")

    later =
      measure(ctx.publication, ctx.discovery, 2, DateTime.add(ctx.now, 1), %{
        "summary" => "7 containers need classification",
        "details" => "Unclassified running containers:\n- service-new\n- <unsafe-name>"
      })

    send(view.pid, :tick)
    assert has_element?(view, "#incident-check-now", "7 containers need classification")
    assert has_element?(view, "#incident-current-details pre", "service-new")
    assert has_element?(view, "#incident-current-details pre", "<unsafe-name>")
    refute has_element?(view, "#incident-current-details unsafe-name")

    assert has_element?(
             view,
             "#incident-measurements #evidence-#{ctx.report["id"]} h3",
             "When this incident opened"
           )

    assert has_element?(
             view,
             "#incident-measurements #evidence-#{ctx.report["id"]}",
             "5 containers need classification"
           )

    refute has_element?(
             view,
             "#incident-measurements #evidence-#{ctx.report["id"]}",
             "service-new"
           )

    assert Repo.get!(Observation, ctx.report["id"]).payload["results"]
           |> hd()
           |> Map.fetch!("summary") == "5 containers need classification"

    assert Repo.get!(ResultStream, ctx.stream.id).current["confirmed_observation_id"] ==
             later["id"]

    navigation = view |> element("#incident-discovery-review") |> render_click()
    {:ok, discovery, _} = follow_redirect(navigation, build_conn())

    assert has_element?(
             discovery,
             "#discovery-back[href='/incidents/#{incident.id}']",
             "Back to incident"
           )

    assert has_element?(discovery, "#discovery-candidate-0")
  end

  test "source-declared choices require explicit selection and produce a reviewed typed prompt without writes",
       ctx do
    return_to =
      MondekWeb.CheckInventory.normalize(%{"tab" => "critical", "view" => "list"})
      |> MondekWeb.CheckInventory.path()

    {:ok, result, _} =
      live(
        build_conn(),
        "/checks/#{ctx.stream.id}?" <> URI.encode_query(%{"return_to" => return_to})
      )

    assert has_element?(result, "#result-discovery-review", "Review discovered resources")
    navigation = result |> element("#result-discovery-review") |> render_click()
    {:ok, view, _} = follow_redirect(navigation, build_conn())

    assert has_element?(
             view,
             "#discovery-back[href='/checks/#{ctx.stream.id}?return_to=#{URI.encode_www_form(return_to)}']"
           )

    assert has_element?(view, "h1", "Review discovered resources")
    assert has_element?(view, "#discovery-omitted", "1 additional")
    refute has_element?(view, "#discovery-review-form input[type=checkbox][checked]")
    refute has_element?(view, "#discovery-choice-0")
    view |> form("#discovery-review-form") |> render_submit()
    assert has_element?(view, "#discovery-error", "Select at least one")

    choose(view, "")

    assert has_element?(
             view,
             "#discovery-choice-0 option[value=''][selected]",
             "Choose a proposal"
           )

    view |> form("#discovery-review-form") |> render_submit()
    assert has_element?(view, "#discovery-error", "Choose a proposal for Export archive")
    choose(view, "monitor")

    assert has_element?(
             view,
             "label[for='discovery-params-0-maximum_age_hours']",
             "Maximum age (hours)"
           )

    assert has_element?(view, "#discovery-params-0-maximum_age_hours[value='24']")
    before_assignments = Repo.all(Assignment)
    before_incidents = Repo.all(Incident)

    view
    |> form("#discovery-review-form",
      selections: %{
        "0" => %{
          "selected" => "true",
          "choice_key" => "monitor",
          "params" => %{"maximum_age_hours" => "36"}
        }
      }
    )
    |> render_submit()

    assert has_element?(view, "#discovery-proposal-review", "Maximum age")
    assert has_element?(view, "#discovery-proposal-review", "36")
    refute has_element?(view, "#discovery-prompt-text")
    view |> element("#discovery-generate") |> render_click()
    prompt = text(view, "#discovery-prompt-text")
    assert prompt =~ ~s("candidate_key": "export-archive")
    assert prompt =~ ~s("maximum_age_hours": 36)
    refute prompt =~ ~s("candidate_key": "other-archive")
    assert has_element?(view, "#discovery-prompt-copy", "Copy prompt")
    assert Repo.all(Assignment) == before_assignments
    assert Repo.all(Incident) == before_incidents
  end

  test "fresh identical evidence preserves edits and a changed snapshot requires an explicit reload",
       ctx do
    {:ok, view, _} = live(build_conn(), path(ctx))
    choose(view, "monitor")
    edit_age(view, "37")
    original = Discovery.inspect(ctx.stream.id)
    measure(ctx.publication, ctx.discovery, 2, ctx.now)
    send(view.pid, :tick)
    assert has_element?(view, "#discovery-params-0-maximum_age_hours[value='37']")
    refute has_element?(view, "#discovery-changed")
    assert Discovery.inspect(ctx.stream.id)["fingerprint"] == original["fingerprint"]
    saved_token = hidden(view, "snapshot")

    changed = put_in(ctx.discovery, ["candidates", Access.at(0), "label"], "Replacement archive")
    measure(ctx.publication, changed, 3, ctx.now)
    send(view.pid, :tick)
    assert has_element?(view, "#discovery-changed", "previous selections are retained")
    assert has_element?(view, "#discovery-review[disabled]")
    assert has_element?(view, "#discovery-candidate-0", "Export archive")
    assert has_element?(view, "#discovery-params-0-maximum_age_hours[value='37']")

    # The old signed snapshot reconstructs the exact old draft after reconnect.
    {:ok, recovered, _} = live(build_conn(), path(ctx))

    render_hook(recovered, "recover", %{
      "snapshot" => saved_token,
      "selections" => %{
        "0" => %{
          "selected" => "true",
          "choice_key" => "monitor",
          "params" => %{"maximum_age_hours" => "37"}
        }
      }
    })

    assert has_element?(recovered, "#discovery-changed")
    assert has_element?(recovered, "#discovery-candidate-0", "Export archive")
    assert has_element?(recovered, "#discovery-params-0-maximum_age_hours[value='37']")
    recovered |> element("#discovery-reload") |> render_click()
    assert has_element?(recovered, "#discovery-candidate-0", "Replacement archive")
    refute has_element?(recovered, "#discovery-review-form input[type=checkbox][checked]")
    refute has_element?(recovered, "#discovery-changed")
  end

  test "fresh same-snapshot form recovery retains typed drafts and rejects altered recovery tokens",
       ctx do
    {:ok, first, _} = live(build_conn(), path(ctx))
    token = hidden(first, "snapshot")
    {:ok, view, _} = live(build_conn(), path(ctx))

    form = %{
      "snapshot" => token,
      "selections" => %{
        "0" => %{
          "selected" => "true",
          "choice_key" => "monitor",
          "params" => %{"maximum_age_hours" => "39"}
        }
      }
    }

    render_hook(view, "recover", form)
    assert has_element?(view, "#discovery-params-0-maximum_age_hours[value='39']")
    refute has_element?(view, "#discovery-review[disabled]")
    render_hook(view, "recover", Map.put(form, "snapshot", token <> "altered"))
    assert has_element?(view, "#discovery-error", "could not be recovered")
    refute has_element?(view, "#discovery-proposal-review")
  end

  test "generation rechecks freshness and retained unavailable evidence cannot generate a prompt",
       ctx do
    {:ok, view, _} = live(build_conn(), path(ctx))
    choose(view, "monitor")
    edit_age(view, "41")
    view |> form("#discovery-review-form") |> render_submit()
    assert has_element?(view, "#discovery-generate")

    current = Repo.get!(ResultStream, ctx.stream.id).current

    Monitoring.change(Repo.get!(ResultStream, ctx.stream.id), %{
      current: Map.put(current, "source_at", Monitoring.iso(DateTime.add(ctx.now, -100)))
    })

    view |> element("#discovery-generate") |> render_click()
    refute has_element?(view, "#discovery-prompt-text")
    assert has_element?(view, "#discovery-unavailable", "fresh confirmed measurement")
    assert has_element?(view, "#discovery-review[disabled]")
    assert has_element?(view, "#discovery-select-0[checked]")

    # Browsers omit disabled controls. Hidden mirrors retain the frozen choice
    # through the same native form shape that automatic recovery sends.
    recovery = hidden_form(view)
    assert recovery["selections"]["0"]["selected"] == "true"
    assert recovery["selections"]["0"]["choice_key"] == "monitor"
    assert recovery["selections"]["0"]["params"]["maximum_age_hours"] == "41"
    {:ok, recovered, _} = live(build_conn(), path(ctx))
    render_hook(recovered, "recover", recovery)
    assert has_element?(recovered, "#discovery-select-0[checked]")
    assert has_element?(recovered, "#discovery-choice-0 option[value=monitor][selected]")
    assert has_element?(recovered, "#discovery-params-0-maximum_age_hours[value='41']")
    assert has_element?(recovered, "#discovery-review[disabled]")

    measure(ctx.publication, ctx.discovery, 2, ctx.now)
    send(view.pid, :tick)
    refute has_element?(view, "#discovery-review[disabled]")
    refute has_element?(view, "#discovery-prompt-text")
  end

  test "missing discovery and unsafe returns stay within the application", ctx do
    {:ok, view, _} = live(build_conn(), path(ctx) <> "?return_to=https%3A%2F%2Fexample.com")
    assert has_element?(view, "#discovery-back[href='/checks/#{ctx.stream.id}']")
    unknown = Ecto.UUID.generate()
    {:ok, missing, _} = live(build_conn(), "/checks/#{unknown}/discovery")
    assert has_element?(missing, "#discovery-missing", "No retained discovery")
    refute has_element?(missing, "#discovery-review-form")
  end

  defp path(ctx), do: "/checks/#{ctx.stream.id}/discovery"

  defp choose(view, choice) do
    view
    |> form("#discovery-review-form", selections: %{"0" => %{"selected" => "true"}})
    |> render_change()

    view
    |> form("#discovery-review-form",
      selections: %{"0" => %{"selected" => "true", "choice_key" => choice}}
    )
    |> render_change()
  end

  defp edit_age(view, age),
    do:
      view
      |> form("#discovery-review-form",
        selections: %{
          "0" => %{
            "selected" => "true",
            "choice_key" => "monitor",
            "params" => %{"maximum_age_hours" => age}
          }
        }
      )
      |> render_change()

  defp hidden(view, name),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#discovery-review-form input[name='#{name}']")
      |> LazyHTML.attribute("value")
      |> hd()

  defp text(view, selector),
    do:
      view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.text()

  defp hidden_form(view) do
    inputs =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#discovery-review-form input[type=hidden]")

    Enum.zip(LazyHTML.attribute(inputs, "name"), LazyHTML.attribute(inputs, "value"))
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
  end

  defp measure(publication, discovery, sequence, now, findings \\ %{}) do
    [assignment] = CoverageFixtures.assignments(publication)
    time = Monitoring.iso(now)

    result = %{
      "key" => "health",
      "health" => "WARN",
      "summary" => "5 containers need classification",
      "source_at" => time,
      "discovery" => discovery
    }

    result = Map.merge(result, findings)

    report =
      measurement("WARN", sequence, %{
        "assignment_id" => assignment.id,
        "installation_id" => publication["installation_id"],
        "session_id" => publication["session_id"],
        "started_at" => time,
        "evaluated_at" => time,
        "results" => [result]
      })

    assert disposition(
             Monitoring.ingest(
               envelope([report], Map.take(publication, ~w(installation_id session_id))),
               now
             )
           ) == "current"

    report
  end

  defp discovery do
    %{
      "version" => 1,
      "title" => "Unconfigured exports",
      "instructions" => "Choose which archives belong in the source-owned export policy.",
      "omitted" => 1,
      "choices" => [
        %{
          "key" => "monitor",
          "label" => "Monitor export age",
          "description" => "Add an explicit expected export and age limit.",
          "parameter_schema" => %{
            "fields" => %{
              "maximum_age_hours" => %{
                "type" => "number",
                "label" => "Maximum age",
                "unit" => "hours",
                "minimum" => 1,
                "maximum" => 168
              }
            },
            "comparisons" => []
          },
          "params" => %{"maximum_age_hours" => 24}
        },
        %{
          "key" => "ignore",
          "label" => "Ignore explicitly",
          "description" => "Record an explicit source-owned exclusion.",
          "parameter_schema" => %{"fields" => %{}, "comparisons" => []},
          "params" => %{}
        }
      ],
      "candidates" => [
        %{
          "key" => "export-archive",
          "label" => "Export archive",
          "details" => "Export archive detected on this target."
        },
        %{
          "key" => "other-archive",
          "label" => "Other archive",
          "details" => "A separate discovered archive."
        }
      ]
    }
  end
end

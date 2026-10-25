# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.APITest do
  use Mondek.DataCase, async: false

  setup do
    pid = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    %{url: "http://127.0.0.1:#{port}"}
  end

  defp post(url, path, body, timeout \\ 5000) do
    {:ok, {{_, code, _}, _, json}} =
      :httpc.request(
        :post,
        {String.to_charlist(url <> path), [], ~c"application/json", Jason.encode!(body)},
        [timeout: timeout],
        body_format: :binary
      )

    {code,
     case Jason.decode(json) do
       {:ok, value} -> value
       {:error, _} -> %{"error" => json}
     end}
  end

  test "actual HTTP commits, acknowledges, deduplicates and rejects semantic conflicts", %{
    url: url
  } do
    assert {200, %{"version" => 1}} = post(url, "/api/v1/control", control())
    time = DateTime.to_iso8601(Monitoring.now())

    r =
      measurement("CRIT", 1, %{"started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)

    assert {200, %{"dispositions" => [%{"disposition" => "current"}]}} =
             post(url, "/api/v1/observations", envelope([r]))

    assert Repo.aggregate(Incident, :count) == 1

    assert {200,
            %{
              "dispositions" => [
                %{"disposition" => "duplicate", "original_disposition" => "current"}
              ]
            }} = post(url, "/api/v1/observations", envelope([r]))

    changed = put_in(r, ["results", Access.at(0), "health"], "OK")

    assert {200, %{"dispositions" => [%{"disposition" => "conflict"}]}} =
             post(url, "/api/v1/observations", envelope([changed]))

    assert Repo.aggregate(Occurrence, :count) == 1
  end

  test "exact numeric retries survive JSONB representation changes without rounding conflicts", %{
    url: url
  } do
    assert {200, _} = post(url, "/api/v1/control", control())
    time = DateTime.to_iso8601(Monitoring.now())

    for {value, sequence} <- Enum.with_index([1.0e20, 1.0e24, -1.0e24, 1.7976931348623157e308], 1) do
      report =
        measurement("CRIT", sequence, %{"started_at" => time, "evaluated_at" => time})
        |> put_in(["results", Access.at(0), "source_at"], time)
        |> put_in(["results", Access.at(0), "value"], value)

      assert {200, %{"dispositions" => [%{"disposition" => "current"}]}} =
               post(url, "/api/v1/observations", envelope([report]))

      stored = Repo.get!(Observation, report["id"])
      persisted_value = hd(stored.payload["results"])["value"]
      assert is_integer(persisted_value)

      assert {200,
              %{
                "dispositions" => [
                  %{"disposition" => "duplicate", "original_disposition" => "current"}
                ]
              }} = post(url, "/api/v1/observations", envelope([report]))

      # One decimal integer step is far smaller than a float ULP at these
      # magnitudes. It is still a different value and must remain a conflict.
      changed = put_in(report, ["results", Access.at(0), "value"], persisted_value + 1)

      assert {200, %{"dispositions" => [%{"disposition" => "conflict"}]}} =
               post(url, "/api/v1/observations", envelope([changed]))
    end

    assert Repo.aggregate(Observation, :count) == 4
    assert Repo.aggregate(Incident, :count) == 1
    assert Repo.aggregate(Occurrence, :count) == 1
  end

  test "wire bounds and malformed types return explicit client errors", %{url: url} do
    assert {422, _} = post(url, "/api/v1/control", control(%{"version" => 2}))

    for key <- ["prepared", "active", "status"] do
      assert {422, _} = post(url, "/api/v1/control", control(%{key => false}))
    end

    assert {422, _} =
             post(url, "/api/v1/incidents/not-a-uuid/acknowledge", %{
               "seconds" => 60,
               "note" => "test"
             })

    assert {200, _} = post(url, "/api/v1/control", control())
    assert {422, _} = post(url, "/api/v1/observations", envelope(List.duplicate(report(), 33)))

    oversized =
      put_in(report(), ["results", Access.at(0), "summary"], String.duplicate("x", 2049))

    assert {200, %{"dispositions" => [%{"disposition" => "rejected"}]}} =
             post(url, "/api/v1/observations", envelope([oversized]))

    assert {413, _} = post(url, "/api/v1/control", %{"huge" => String.duplicate("x", 262_144)})

    assert {:error, {:invalid, _}} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000002", 1, %{
               "url" => "http://target/" <> String.duplicate("x", 2048)
             })
  end

  test "real inventory HTTP accepts bounded large catalogs while ordinary bodies stay small", %{
    url: url
  } do
    checks =
      for n <- 1..500 do
        %{
          "key" => "http-check-#{n}",
          "label" => "HTTP check #{n}",
          "definition_revision" => String.duplicate("b", 64),
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{"description" => %{"type" => "string"}}},
          "params" => %{"description" => String.duplicate("x", 600)},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "value",
              "label" => "Output #{n}",
              "target" => %{"key" => "host-#{n}", "kind" => "host", "label" => "Host #{n}"}
            }
          ]
        }
      end

    body =
      control()
      |> Map.merge(%{
        "runner_label" => "HTTP node",
        "source_id" => "http-source",
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => checks
      })

    assert byte_size(Jason.encode!(body)) > 262_144

    assert {200, %{"accepted_checks" => 500}} =
             post(url, "/api/v1/inventory", body, 15_000)

    assert {413, _} =
             post(url, "/api/v1/observations", %{"large" => String.duplicate("x", 262_144)})

    assert {413, _} =
             post(url, "/api/v1/inventory", %{"large" => String.duplicate("x", 4_194_304)})

    assert {:ok, {{_, 200, _}, _, response}} =
             :httpc.request(
               :get,
               {String.to_charlist(url <> "/api/v1/checks?search=http-check&page_size=23&page=2"),
                []},
               [timeout: 5000],
               body_format: :binary
             )

    page = Jason.decode!(response)
    assert page["total"] == 500 and length(page["items"]) == 23
    stream = hd(page["items"])

    assert {:ok, {{_, 200, _}, _, detail}} =
             :httpc.request(
               :get,
               {String.to_charlist(url <> "/api/v1/checks/" <> stream["id"]), []},
               [timeout: 5000],
               body_format: :binary
             )

    assert Jason.decode!(detail)["stream"]["id"] == stream["id"]

    assert {422, _} =
             post(
               url,
               "/api/v1/inventory",
               put_in(body, ["checks", Access.at(0), "extra"], <<0>>)
             )

    assert {422, _} = post(url, "/api/v1/control", control(%{"runner_label" => <<0>>}))
  end

  @tag timeout: 120_000
  @tag empty_source_fixture: true
  test "real HTTP reviews and saves 512 escaped target identities within an explicit body bound",
       %{url: url} do
    source = String.duplicate("\\\"", 100)
    environment = String.duplicate("\\\"", 64)
    kind = String.duplicate("\\\"", 32)

    targets =
      for n <- 1..512,
          do: String.duplicate("\\\"", 98) <> String.pad_leading(to_string(n), 4, "0")

    checks =
      Enum.with_index(targets, fn target, index ->
        %{
          "key" => "escaped-#{index}",
          "label" => "Escaped target #{index}",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => environment,
          "params_owner" => "source",
          "params" => %{},
          "parameter_schema" => %{"fields" => %{}},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => [
            %{
              "key" => "value",
              "label" => "Value",
              "target" => %{"key" => target, "kind" => kind, "label" => "Escaped target #{index}"}
            }
          ]
        }
      end)

    inventory =
      control()
      |> Map.merge(%{
        "runner_label" => "Escaped identity observer",
        "source_id" => source,
        "source_revision" => String.duplicate("a", 64),
        "inventory_revision" => 1,
        "complete" => true,
        "checks" => checks
      })

    assert {200, %{"accepted_checks" => 512}} = post(url, "/api/v1/inventory", inventory, 30_000)

    selectors =
      for target <- targets,
          do: %{
            "scope" => "target",
            "assignment_id" => nil,
            "source_id" => source,
            "environment" => environment,
            "target_kind" => kind,
            "target_key" => target
          }

    proposal =
      Mondek.MaintenanceSelection.proposal(selectors)
      |> Map.put("reason", "Review a complete large selection through real HTTP")

    body = %{"proposal" => proposal}
    assert byte_size(Jason.encode!(body)) > 524_288
    assert byte_size(Jason.encode!(body)) < 2_097_152
    assert {200, preview} = post(url, "/api/v1/maintenance/preview", body, 30_000)
    assert preview["counts"] == %{"matched_checks" => 512, "matched_results" => 512}
    assert length(preview["selection_summary"]) == 512

    assert {200, saved} =
             post(
               url,
               "/api/v1/maintenance/apply",
               %{"proposal" => preview["proposal"], "review_token" => preview["review_token"]},
               30_000
             )

    assert length(saved["selections"]) == 512

    assert {200, _} =
             post(
               url,
               "/api/v1/maintenance/" <> saved["id"] <> "/cancel",
               %{"revision" => 1, "reason" => "Finish large HTTP selection test"},
               30_000
             )

    for path <- ["/api/v1/maintenance/preview", "/api/v1/maintenance/apply"] do
      assert {413, _} = post(url, path, %{"large" => String.duplicate("x", 2_097_152)})
    end

    assert {413, _} = post(url, "/api/v1/control", %{"large" => String.duplicate("x", 262_144)})
  end

  test "out-of-range configuration generations are rejected before database encoding", %{url: url} do
    assert {200, _} = post(url, "/api/v1/control", control())

    assert {200, %{"dispositions" => [%{"disposition" => "rejected"}]}} =
             post(
               url,
               "/api/v1/observations",
               envelope([report(%{"generation" => 2_147_483_648})])
             )

    for key <- ["prepared", "active"] do
      assert {422, _} =
               post(
                 url,
                 "/api/v1/control",
                 control(%{key => %{"10000000-0000-4000-8000-000000000001" => 2_147_483_648}})
               )
    end

    assert Repo.aggregate(Observation, :count) == 0
  end

  test "browser form requests cannot change local API state", %{url: url} do
    body = URI.encode_query(%{"seconds" => 60, "reason" => "Cross-origin form"})

    assert {:ok, {{_, 415, _}, _, _}} =
             :httpc.request(
               :post,
               {String.to_charlist(url <> "/api/v1/maintenance/preview"),
                [{~c"origin", ~c"https://example.invalid"}],
                ~c"application/x-www-form-urlencoded", body},
               [timeout: 5000],
               body_format: :binary
             )

    refute Repo.exists?(
             from w in Mondek.MaintenanceWindow,
               where: w.assignment_id == "10000000-0000-4000-8000-000000000002"
           )

    assert Repo.aggregate(Mondek.Control, :count) == 0

    {:ok, seed} = Mondek.Maintenance.seed("10000000-0000-4000-8000-000000000002")
    proposal = Map.put(seed["proposal"], "reason", "Local JSON control")
    assert {200, preview} = post(url, "/api/v1/maintenance/preview", %{"proposal" => proposal})

    assert {200, _} =
             post(url, "/api/v1/maintenance/apply", %{
               "proposal" => preview["proposal"],
               "review_token" => preview["review_token"]
             })

    assert Repo.aggregate(Mondek.MaintenanceWindow, :count) == 1
  end

  test "selected incident HTTP detail includes its evidence and handles unknown IDs", %{url: url} do
    assert {200, _} = post(url, "/api/v1/control", control())
    time = DateTime.to_iso8601(Monitoring.now())

    report =
      measurement("CRIT", 1, %{"started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)

    assert {200, _} = post(url, "/api/v1/observations", envelope([report]))
    incident = Repo.one!(Incident)

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(
               :get,
               {String.to_charlist(url <> "/api/v1/incidents/" <> incident.id), []},
               [timeout: 5000],
               body_format: :binary
             )

    detail = Jason.decode!(body)
    assert detail["incident"]["id"] == incident.id
    assert Enum.any?(detail["evidence"], &(&1["id"] == report["id"]))

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      assert {:ok, {{_, 404, _}, _, _}} =
               :httpc.request(
                 :get,
                 {String.to_charlist(url <> "/api/v1/incidents/" <> id), []},
                 [timeout: 5000],
                 body_format: :binary
               )
    end
  end

  test "controller-only setup, built-in creation and manual retirement routes are absent", %{
    url: url
  } do
    for route <- [
          "/api/v1/setup",
          "/api/v1/assignments",
          "/api/v1/assignments/10000000-0000-4000-8000-000000000001/retire"
        ] do
      assert {404, _} =
               post(url, route, %{"kind" => "http", "revision" => 1, "reason" => "No manual path"})
    end

    assert Repo.aggregate(Assignment, :count) == 3
    assert Enum.all?(Repo.all(Assignment), &(&1.kind == "python" && &1.source_id))
  end

  test "real HTTP retries exhausted delivery once and validates operator reason", %{url: url} do
    connect()
    ingest(measurement("CRIT"))
    occurrence = Repo.one!(Occurrence)
    Monitoring.change(Repo.one!(Oban.Job), %{state: "discarded"})
    Mondek.Sweeper.sweep(at())

    assert {422, _} =
             post(url, "/api/v1/notifications/#{occurrence.id}/retry", %{"reason" => " "})

    assert {422, _} =
             post(url, "/api/v1/notifications/#{occurrence.id}/retry", %{
               "reason" => "Invalid\u0000reason"
             })

    assert {404, _} =
             post(url, "/api/v1/assignments/10000000-0000-4000-8000-000000000001/retire", %{
               "revision" => 1,
               "reason" => "Invalid\u0000reason"
             })

    assert {200, %{"id" => id, "status" => "pending"}} =
             post(url, "/api/v1/notifications/#{occurrence.id}/retry", %{
               "reason" => "Receiver restored"
             })

    assert id == occurrence.id

    assert {409, %{"error" => "not_exhausted"}} =
             post(url, "/api/v1/notifications/#{id}/retry", %{"reason" => "Duplicate click"})

    assert Repo.aggregate(Oban.Job, :count) == 2
    assert Repo.one!(Mondek.Control).kind == "notification_retry"
  end

  test "malformed batch membership rejects that report before binding database text", %{url: url} do
    assert {200, _} = post(url, "/api/v1/control", control())
    time = DateTime.to_iso8601(Monitoring.now())

    valid =
      measurement("OK", 1, %{"started_at" => time, "evaluated_at" => time})
      |> put_in(["results", Access.at(0), "source_at"], time)

    invalid =
      valid |> Map.put("id", Ecto.UUID.generate()) |> Map.put("assignment_id", "filesystem\u0000")

    raw_binary_id =
      invalid
      |> Map.put("id", Ecto.UUID.generate())
      |> Map.put("assignment_id", String.duplicate("x", 15) <> "\u0000")

    assert {200,
            %{
              "dispositions" => [
                %{"disposition" => "rejected"},
                %{"disposition" => "rejected"},
                %{"disposition" => "current"}
              ]
            }} =
             post(url, "/api/v1/observations", envelope([invalid, raw_binary_id, valid]))

    assert Repo.aggregate(Observation, :count) == 1
  end

  test "malformed assignment route IDs never bind invalid PostgreSQL text", %{url: url} do
    for encoded_id <- ["filesystem%00", String.duplicate("x", 15) <> "%00"],
        suffix <- ["", "/inspection"] do
      path = "/api/v1/assignments/" <> encoded_id <> suffix

      assert {:ok, {{_, 404, _}, _, _}} =
               :httpc.request(:get, {String.to_charlist(url <> path), []}, [timeout: 5000],
                 body_format: :binary
               )
    end

    assert {404, _} =
             post(url, "/api/v1/assignments/10000000-0000-4000-8000-000000000001%00/retire", %{
               "revision" => 1,
               "reason" => "Malformed target"
             })

    assert {404, _} =
             post(
               url,
               "/api/v1/assignments/10000000-0000-4000-8000-000000000001%00/maintenance",
               %{
                 "seconds" => 60,
                 "reason" => "Malformed target"
               }
             )

    assert {:ok, {{_, 404, _}, _, _}} =
             :httpc.request(
               :put,
               {String.to_charlist(
                  url <> "/api/v1/assignments/10000000-0000-4000-8000-000000000001%00"
                ), [], ~c"application/json",
                Jason.encode!(%{
                  "revision" => 1,
                  "params" => %{"path" => "/", "warn_percent" => 70, "crit_percent" => 90}
                })},
               [timeout: 5000],
               body_format: :binary
             )

    assert is_nil(Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").retired_at)
    assert Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001").revision == 1
    assert Repo.aggregate(Mondek.Control, :count) == 0
  end
end

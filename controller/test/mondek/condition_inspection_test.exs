# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionInspectionTest do
  use Mondek.DataCase, async: false
  @moduletag empty_source_fixture: true
  alias Mondek.{ConditionInspection, ConditionIncident, Conditions, Control}

  test "contribution pages keep complete counts, bad-to-good order and derived shared coverage" do
    rows = inventory(31)

    for {a, index} <- Enum.with_index(rows),
        do: sample(a, if(index < 16, do: "CRIT", else: "WARN"), 1)

    group = Repo.one!(ConditionIncident)
    ack(group)
    first = ConditionInspection.detail(group.id, %{}, at())
    assert first["counts"]["total"] == 31
    assert first["counts"]["open"] == 31
    assert first["counts"]["critical"] == 16
    assert first["counts"]["warning"] == 15
    assert first["counts"]["shared_acknowledged"] == 31
    assert first["counts"]["uncovered"] == 0
    assert length(first["contributions"]) == 25
    assert first["contribution_page"]["omitted"] == 6

    assert Enum.take(first["contributions"], 16)
           |> Enum.all?(&(&1["last_failure_health"] == "CRIT"))

    assert Enum.all?(first["contributions"], & &1["coverage"]["shared_acknowledgement"])
    assert Enum.all?(first["contributions"], &is_nil(&1["incident"]["acknowledgement_mode"]))
    second = ConditionInspection.detail(group.id, %{"page" => 2}, at())
    assert length(second["contributions"]) == 6
    assert second["contribution_page"]["omitted"] == 25

    refute Enum.any?(second["contributions"], fn row ->
             Enum.any?(first["contributions"], &(&1["incident"]["id"] == row["incident"]["id"]))
           end)

    assert second["counts"] == first["counts"]
    assert length(first["controls"]) == 1
  end

  test "measurement evidence stays distinct from unavailable collection and current freshness" do
    [a] = inventory(1)
    failure = sample(a, "CRIT", 1)
    later = sample(a, "UNKNOWN", 2)
    group = Repo.one!(ConditionIncident)
    detail = ConditionInspection.detail(group.id, %{}, at())
    [row] = detail["contributions"]
    assert row["measured_result"]["health"] == "CRIT"
    assert row["evidence_ids"]["latest"] == failure["id"]
    assert row["stream"]["current"]["observation_id"] == later["id"]
    assert row["stream"]["current"]["knowledge"] == "unavailable"
    assert detail["counts"]["unavailable"] == 1
    sample(a, "CRIT", 3)
    stale = ConditionInspection.detail(group.id, %{}, DateTime.add(at(), 20))
    assert stale["counts"]["stale"] == 1
    assert hd(stale["contributions"])["measured_result"]["health"] == "CRIT"
  end

  test "individual contribution inspection retains exact episode evidence beyond recent executions" do
    [check] = inventory(1)
    opening = sample(check, "CRIT", 1, [], DateTime.add(at(), 1))
    contribution = Repo.one!(Incident)

    latest =
      for sequence <- 2..17 do
        sample(check, "CRIT", sequence, [], DateTime.add(at(), sequence))
      end
      |> List.last()

    unavailable = sample(check, "UNKNOWN", 18, [], DateTime.add(at(), 18))
    detail = Monitoring.incident_detail(contribution.id, DateTime.add(at(), 18))
    ids = Enum.map(detail["evidence"], & &1["id"])
    assert opening["id"] in ids
    assert latest["id"] in ids
    assert unavailable["id"] in ids
    assert detail["incident"]["opening_observation_id"] == opening["id"]
    assert detail["incident"]["latest_observation_id"] == latest["id"]
    assert detail["stream"]["current"]["observation_id"] == unavailable["id"]

    assert detail["limits"]["evidence"] == %{
             "referenced" => 3,
             "missing" => 0,
             "recent_limit" => 12
           }

    assert length(ids) == 13
    assert detail["occurrences"] == []
    assert detail["attempts"] == []

    recovery = sample(check, "OK", 19, [], DateTime.add(at(), 19))

    current =
      for sequence <- 20..33 do
        sample(check, "CRIT", sequence, [], DateTime.add(at(), sequence))
      end
      |> List.last()

    closed = Monitoring.incident_detail(contribution.id, DateTime.add(at(), 33))
    ids = Enum.map(closed["evidence"], & &1["id"])
    assert closed["incident"]["status"] == "closed"
    assert closed["incident"]["condition_incident_id"] == contribution.condition_incident_id
    assert closed["incident"]["opening_observation_id"] == opening["id"]
    assert closed["incident"]["latest_observation_id"] == recovery["id"]
    assert closed["incident"]["closing_observation_id"] == recovery["id"]
    assert opening["id"] in ids
    assert recovery["id"] in ids
    assert closed["stream"]["current"]["observation_id"] == current["id"]

    assert closed["limits"]["evidence"] == %{
             "referenced" => 3,
             "missing" => 0,
             "recent_limit" => 12
           }

    assert length(ids) == 14
    assert closed["occurrences"] == []
  end

  test "per-member maintenance and individual acknowledgement survive ending the shared control" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1)
    sample(two, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    assert {:ok, _} = reviewed_maintenance_fixture(one.id, 100, "Repair this observer", at())

    individual =
      Repo.one!(from i in Incident, where: i.assignment_id == ^two.id and i.status == "open")

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               individual.id,
               %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
               "Investigating this observer",
               at()
             )

    ack(group)
    detail = ConditionInspection.detail(group.id, %{}, at())
    assert detail["counts"]["shared_acknowledged"] == 2
    assert detail["counts"]["maintained"] == 1
    assert detail["counts"]["individually_acknowledged"] == 1
    assert detail["counts"]["uncovered"] == 0
    group = Repo.get!(ConditionIncident, group.id)

    assert {:ok, _} =
             Conditions.acknowledge(
               group.id,
               ack_options(group, "end"),
               "Continue individual work",
               at()
             )

    after_end = ConditionInspection.detail(group.id, %{}, at())
    assert after_end["counts"]["shared_acknowledged"] == 0
    assert after_end["counts"]["maintained"] == 1
    assert after_end["counts"]["individually_acknowledged"] == 1
    assert after_end["counts"]["uncovered"] == 0

    assert Enum.any?(
             after_end["contributions"],
             &(length(&1["coverage"]["maintenance_windows"]) > 0)
           )
  end

  test "closed contribution history never borrows a later episode's current failure or acknowledgement" do
    [a] = inventory(1)
    sample(a, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    recovery = sample(a, "OK", 2)
    sample(a, "CRIT", 3)
    next = Repo.one!(from g in ConditionIncident, where: g.status == "open")
    ack(next)
    detail = ConditionInspection.detail(group.id, %{}, at())
    assert detail["contribution_page"]["state"] == "history"
    assert detail["counts"]["recovered"] == 1
    assert detail["counts"]["open"] == 0
    [row] = detail["contributions"]
    assert row["contribution_state"] == "recovered"
    assert row["measured_result"]["health"] == "OK"
    assert row["evidence_ids"]["closing"] == recovery["id"]
    assert row["stream"]["current"]["health"] == "CRIT"
    refute row["coverage"]["shared_acknowledgement"]
    refute row["coverage"]["uncovered"]
    assert detail["closing_evidence"]["id"] == recovery["id"]
    refute Enum.any?(detail["controls"], &(&1["condition_incident_id"] == next.id))
  end

  test "contradictory OK evidence is paged exact-condition context and does not vote away failure" do
    rows =
      inventory(32, %{
        31 => %{"environment" => "staging"},
        32 => %{"condition_namespace" => "other"}
      })

    [critical | healthy] = rows
    sample(critical, "CRIT", 1)
    Enum.each(healthy, &sample(&1, "OK", 1))
    group = Repo.one!(ConditionIncident)
    detail = ConditionInspection.detail(group.id, %{}, at())
    assert detail["counts"]["open"] == 1
    assert detail["counts"]["contradictory_results"] == 29
    assert length(detail["contradictions"]) == 25

    second =
      ConditionInspection.detail(group.id, %{"contradiction_page" => 2}, DateTime.add(at(), 20))

    assert length(second["contradictions"]) == 4
    assert second["contradiction_page"]["omitted"] == 25
    assert Enum.all?(second["contradictions"], &(&1["current"]["knowledge"] == "stale"))
    assert second["incident"]["status"] == "open"
    assert second["incident"]["health"] == "CRIT"
  end

  test "evidence excerpts omit unrelated output bodies without changing canonical reports" do
    [a] = inventory(1, %{1 => %{"extra_output" => true}})
    original = sample(a, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    detail = ConditionInspection.detail(group.id, %{}, at())
    assert detail["evidence_projection"] == "referenced_result_excerpts"
    [excerpt] = detail["evidence"]
    assert excerpt["excerpt"]
    assert excerpt["included_result_keys"] == ["pressure"]
    assert excerpt["omitted_result_count"] == 1
    assert Enum.map(excerpt["payload"]["results"], & &1["key"]) == ["pressure"]
    assert Repo.get!(Observation, original["id"]).payload["results"] == original["results"]
    assert byte_size(Jason.encode!(excerpt)) < 4000
    assert hd(detail["contributions"])["stream"]["target"]["kind"] == "volume"
    assert hd(detail["contributions"])["stream"]["runner_label"] == "Independent observer"
    assert hd(detail["contributions"])["incident"]["environment"] == "production"
  end

  test "attempt and control history is bounded and reports complete omitted counts" do
    [a] = inventory(1)
    sample(a, "CRIT", 1)
    group = Repo.one!(ConditionIncident)
    notice = Repo.one!(Occurrence)

    Repo.insert_all(
      Control,
      for index <- 1..140 do
        %{
          condition_incident_id: group.id,
          kind: "acknowledgement_ended",
          actor: "Local operator",
          reason: "Retained control #{index}",
          until: at(),
          inserted_at: DateTime.add(at(), index)
        }
      end
    )

    Repo.insert_all(
      Attempt,
      for index <- 1..150 do
        %{
          id: Ecto.UUID.generate(),
          occurrence_id: notice.id,
          status: "failed_or_ambiguous",
          started_at: DateTime.add(at(), index),
          finished_at: DateTime.add(at(), index),
          http_status: 503,
          error: "Local receiver rejected delivery"
        }
      end
    )

    detail = ConditionInspection.detail(group.id, %{}, DateTime.add(at(), 200))
    assert length(detail["controls"]) == 100
    assert detail["limits"]["controls"]["total"] == 140
    assert detail["limits"]["controls"]["omitted"] == 40
    assert length(detail["attempts"]) == 100
    assert detail["limits"]["attempts"]["total"] == 150
    assert detail["limits"]["attempts"]["omitted"] == 50
    assert hd(detail["occurrences"])["attempt_count"] == 150
    assert hd(detail["occurrences"])["latest_attempt"]["id"] == hd(detail["attempts"])["id"]
    assert ConditionInspection.detail("malformed") == nil
    assert ConditionInspection.detail(Ecto.UUID.generate()) == nil
  end

  test "large shared maintenance scopes are referenced without duplicating their selectors per contributor" do
    rows = inventory(512)
    rows |> Enum.take(25) |> Enum.each(&sample(&1, "CRIT", 1))
    group = Repo.one!(ConditionIncident)
    baseline = ConditionInspection.detail(group.id, %{}, at()) |> Jason.encode!() |> byte_size()

    selections = Enum.map(rows, &%{"scope" => "check", "assignment_id" => &1.id})

    {:ok, seed} = Mondek.Maintenance.seed(hd(rows).id, nil, at())

    proposal =
      Map.merge(seed["proposal"], %{
        "scope" => "selection",
        "assignment_id" => nil,
        "source_id" => nil,
        "environment" => nil,
        "target_kind" => nil,
        "target_key" => nil,
        "selections" => selections,
        "reason" => "Large planned storage work"
      })

    assert {:ok, reviewed} = Mondek.Maintenance.preview(proposal, 1, at())
    assert {:ok, saved} = Mondek.Maintenance.apply(reviewed["review_token"], proposal, at())
    detail = ConditionInspection.detail(group.id, %{}, at())
    assert detail["counts"]["maintained"] == 25

    assert ConditionInspection.detail(group.id, %{"state" => "uncovered"}, at())["contributions"] ==
             []

    assert byte_size(Jason.encode!(detail)) < baseline + 40_000

    refs =
      Enum.flat_map(detail["contributions"], & &1["coverage"]["maintenance_windows"]) ++
        Enum.flat_map(detail["occurrences"], & &1["maintenance_windows"])

    assert length(refs) == 26
    assert Enum.all?(refs, &(&1["scope_window_id"] == saved["id"]))
    assert Enum.all?(refs, &(&1["selection_count"] == 512))
    assert Enum.all?(refs, &(not Map.has_key?(&1, "selections")))
    assert {:ok, window} = Mondek.Maintenance.get(saved["id"], at())
    assert length(window["selections"]) == 512
  end

  test "notification references contain only supporting maintenance and direct links find older facts" do
    [one, two] = inventory(2)
    sample(one, "CRIT", 1, [%{"key" => "local-impact", "label" => "Local consequence"}])
    sample(two, "WARN", 1, [%{"key" => "service-impact", "label" => "Service consequence"}])
    assert {:ok, _} = reviewed_maintenance_fixture(one.id, 100, "Local work", at())
    group = Repo.one!(ConditionIncident)
    detail = ConditionInspection.detail(group.id, %{}, at())

    service =
      Enum.find(
        detail["occurrences"],
        &(&1["payload"]["requested_fact"]["key"] == "service-impact")
      )

    local =
      Enum.find(
        detail["occurrences"],
        &(&1["payload"]["requested_fact"]["key"] == "local-impact")
      )

    assert service["maintenance_windows"] == []
    assert service["gates"] == []
    assert length(local["maintenance_windows"]) == 1
    assert local["gates"] == ["maintenance"]
    uncovered = ConditionInspection.detail(group.id, %{"state" => "uncovered"}, at())
    assert uncovered["counts"]["open"] == 2
    assert uncovered["contribution_page"]["total"] == 1
    assert hd(uncovered["contributions"])["assignment"]["id"] == two.id

    for index <- 2..31,
        do:
          sample(two, "WARN", index, [
            %{"key" => "service-impact-#{index}", "label" => "Consequence #{index}"}
          ])

    oldest = Repo.one!(from o in Occurrence, order_by: [asc: o.inserted_at, asc: o.id], limit: 1)
    focused = ConditionInspection.detail(group.id, %{"notification_id" => oldest.id}, at())
    assert focused["notification_page"]["status"] == "all"
    assert focused["notification_page"]["page"] == 2
    assert Enum.any?(focused["occurrences"], &(&1["id"] == oldest.id))

    assert ConditionInspection.detail(group.id, %{"notification_id" => "invalid"}, at())[
             "notification_page"
           ]["status"] == "unresolved"
  end

  defp inventory(count, overrides \\ %{}) do
    checks =
      for index <- 1..count do
        extra = Map.get(overrides, index, %{})

        condition = %{
          "namespace" => extra["condition_namespace"] || "inspection",
          "key" => "storage",
          "label" => "Storage pressure"
        }

        outputs = [
          %{
            "key" => "pressure",
            "label" => "Storage pressure",
            "target" => %{
              "kind" => "volume",
              "key" => "volume-#{index}",
              "label" => "Data #{index}"
            },
            "condition" => condition
          }
        ]

        outputs =
          if extra["extra_output"],
            do:
              outputs ++
                [
                  %{
                    "key" => "unrelated",
                    "label" => "Unrelated result",
                    "target" => %{"kind" => "service", "key" => "noise", "label" => "Unrelated"}
                  }
                ],
            else: outputs

        %{
          "key" => "check-#{String.pad_leading(to_string(index), 3, "0")}",
          "label" => "Check #{index}",
          "definition_revision" => String.duplicate("b", 64),
          "environment" => Map.get(extra, "environment", "production"),
          "params_owner" => "source",
          "parameter_schema" => %{"fields" => %{}},
          "params" => %{},
          "interval_seconds" => 3,
          "timeout_seconds" => 2,
          "freshness_seconds" => 12,
          "outputs" => outputs
        }
      end

    assert {:ok, _} =
             Monitoring.inventory(
               Map.merge(control(), %{
                 "runner_label" => "Independent observer",
                 "source_id" => "condition-inspection",
                 "source_revision" => String.duplicate("a", 64),
                 "inventory_revision" => 1,
                 "complete" => true,
                 "checks" => checks
               }),
               at()
             )

    rows =
      Repo.all(
        from a in Assignment, where: a.source_id == "condition-inspection", order_by: a.source_key
      )

    assert {:ok, _} = connect(%{"prepared" => Map.new(rows, &{&1.id, 1})})
    rows
  end

  defp sample(a, health, sequence, impacts \\ [], measured_at \\ at()) do
    results = [
      %{
        "key" => "pressure",
        "health" => health,
        "summary" => "Measured #{health}",
        "value" => 90,
        "source_at" => Monitoring.iso(measured_at),
        "impacts" => impacts
      }
    ]

    results =
      if "unrelated" in a.expected_keys,
        do:
          results ++
            [
              %{
                "key" => "unrelated",
                "health" => "OK",
                "summary" => "Unrelated healthy result",
                "value" => 1,
                "source_at" => Monitoring.iso(measured_at),
                "details" => String.duplicate("z", 4000)
              }
            ],
        else: results

    evidence =
      measurement(health, sequence, %{
        "assignment_id" => a.id,
        "started_at" => Monitoring.iso(measured_at),
        "evaluated_at" => Monitoring.iso(measured_at),
        "results" => results
      })

    assert disposition(ingest(evidence, measured_at)) == "current"
    evidence
  end

  defp ack(group),
    do: Conditions.acknowledge(group.id, ack_options(group), "Review the shared condition", at())

  defp ack_options(group, mode \\ "until_incident_ends"),
    do: %{
      "mode" => mode,
      "revision" => group.acknowledgement_revision,
      "attention_revision" => group.attention_revision
    }
end

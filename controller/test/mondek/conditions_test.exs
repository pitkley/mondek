# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConditionsTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    Conditions,
    ConditionIncident,
    ConditionFact,
    Configuration,
    Control,
    OccurrenceEvidence,
    ResultStream
  }

  test "equivalent late arrivals preserve one episode, facts, immutable payload and original jobs" do
    linux = member("Linux")
    elastic = member("Elasticsearch", source: "other-source")
    group = record(linux, "CRIT", 1)
    [critical] = occurrences(group)
    jobs = jobs()
    initial_fact_ids = facts(group) |> Enum.map(& &1.id) |> Enum.sort()
    assert group.attention_revision == 1
    assert record(elastic, "CRIT", 1).id == group.id
    assert length(contributions(group)) == 2
    assert Repo.get!(Occurrence, critical.id).payload == critical.payload
    assert Enum.map(occurrences(group), & &1.id) == [critical.id]
    assert jobs() == jobs
    assert Enum.sort(Enum.map(facts(group), & &1.id)) == initial_fact_ids
    assert Repo.one!(OccurrenceEvidence).observation_id == critical.payload["observation_id"]
    assert critical.incident_id == nil
    assert critical.condition_incident_id == group.id
  end

  test "condition namespaces and missing environments are exact across sources and targets" do
    one = record(member("one", source: "one", target: "local-volume"), "CRIT", 1)
    same = record(member("two", source: "two", target: "search-service"), "CRIT", 1)
    other_namespace = record(member("three", namespace: "other"), "CRIT", 1)
    other_environment = record(member("four", environment: "staging"), "CRIT", 1)
    missing_environment = record(member("five", environment: nil), "CRIT", 1)
    missing_peer = record(member("six", environment: nil), "WARN", 1)
    assert one.id == same.id
    assert missing_environment.id == missing_peer.id

    assert MapSet.size(
             MapSet.new([
               one.id,
               other_namespace.id,
               other_environment.id,
               missing_environment.id
             ])
           ) == 4
  end

  test "shared acknowledgement covers corroboration and member return within its reviewed scope" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1, [impact("blocked-writes")])
    group = acknowledge(group)
    assert record(elastic, "CRIT", 1, [impact("blocked-writes")]).id == group.id
    assert Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id), tick(2))
    assert record(linux, "OK", 2).status == "open"
    assert record(linux, "CRIT", 3, [impact("blocked-writes")]).id == group.id
    saved = Repo.get!(ConditionIncident, group.id)
    assert Monitoring.acknowledgement_active?(saved, tick(4))
    assert saved.acknowledgement_revision == group.acknowledgement_revision
    assert length(contributions(group)) == 3

    assert Enum.all?(
             occurrences(group),
             &match?(
               {:gated, ["acknowledgement"], nil},
               Conditions.delivery_eligibility(&1, saved, tick(4))
             )
           )
  end

  test "severity above the acknowledged ceiling irreversibly ends shared acknowledgement" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "WARN", 1) |> acknowledge()
    assert record(elastic, "CRIT", 1).id == group.id
    invalidated = Repo.get!(ConditionIncident, group.id)
    assert invalidated.acknowledgement_mode == nil
    assert invalidated.acknowledgement_revision == group.acknowledgement_revision + 1
    record(elastic, "OK", 2)
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id), tick(3))

    assert Repo.exists?(
             from c in Control,
               where: c.condition_incident_id == ^group.id and c.kind == "acknowledgement_ended"
           )
  end

  test "a maintained new impact ends shared acknowledgement but cannot borrow another member's eligibility" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    maintain(elastic, 100)
    group = record(linux, "CRIT", 1) |> acknowledge()
    [original] = occurrences(group)
    record(elastic, "CRIT", 1, [impact("blocked-writes")])
    group = Repo.get!(ConditionIncident, group.id)
    assert group.acknowledgement_mode == nil

    assert Conditions.delivery_eligibility(Repo.get!(Occurrence, original.id), group, tick(2)) ==
             :eligible

    blocked = occurrence(group, "impact", "blocked-writes")
    assert {:gated, ["maintenance"], _} = Conditions.delivery_eligibility(blocked, group, tick(2))
    assert blocked.payload["requested_fact"]["kind"] == "impact"
    assert blocked.payload["group_health_at_creation"] == "CRIT"
    refute Map.has_key?(blocked.payload, "health")
    record(elastic, "CRIT", 2)
    assert Repo.get!(Occurrence, blocked.id).status == "superseded"
    refute Monitoring.acknowledgement_active?(Repo.get!(ConditionIncident, group.id), tick(3))
  end

  test "individual acknowledgement also captures material-impact keys and cannot cover a new one" do
    linux = member("Linux")
    group = record(linux, "CRIT", 1)
    [contribution] = contributions(group)

    assert {:ok, _} =
             reviewed_acknowledgement_fixture(
               contribution.id,
               %{"mode" => "until_incident_ends", "revision" => 0, "attention_revision" => 1},
               "Investigating the disk",
               tick(1)
             )

    record(linux, "CRIT", 2, [impact("blocked-writes")])
    changed = Repo.get!(Incident, contribution.id)
    assert changed.acknowledgement_mode == nil
    assert changed.attention_revision == contribution.attention_revision + 1

    assert :eligible =
             Conditions.delivery_eligibility(
               occurrence(group, "impact", "blocked-writes"),
               Repo.get!(ConditionIncident, group.id),
               tick(2)
             )
  end

  test "maintained critical never blocks a later uncovered warning and ending holds retains budgets" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    maintain(linux, 100)
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    refute Enum.any?(occurrences(group), &(&1.payload["requested_fact"]["key"] == "WARN"))
    record(elastic, "WARN", 1)
    group = Repo.get!(ConditionIncident, group.id)
    warning = occurrence(group, "severity", "WARN")
    assert :eligible = Conditions.delivery_eligibility(warning, group, tick(2))

    assert {:gated, ["maintenance"], _} =
             Conditions.delivery_eligibility(critical, group, tick(2))

    ids = Enum.map(occurrences(group), & &1.id) |> Enum.sort()
    before = jobs()

    assert {:ok, _} =
             reviewed_maintenance_fixture(elem(linux, 0).id, 0, "Work completed", tick(3))

    assert :eligible = Conditions.delivery_eligibility(critical, group, tick(3))

    assert {:gated, ["higher_severity_delivery"], _} =
             Conditions.delivery_eligibility(warning, group, tick(3))

    assert Enum.sort(Enum.map(occurrences(group), & &1.id)) == ids

    assert Enum.map(jobs(), &Map.take(&1, [:id, :max_attempts, :attempt])) ==
             Enum.map(before, &Map.take(&1, [:id, :max_attempts, :attempt]))
  end

  test "uncovered warning arriving first keeps its pending occurrence while critical is maintained" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(elastic, "WARN", 1)
    warning = occurrence(group, "severity", "WARN")
    maintain(linux, 100)
    record(linux, "CRIT", 1)
    assert Repo.get!(Occurrence, warning.id).status == "pending"

    assert :eligible =
             Conditions.delivery_eligibility(
               warning,
               Repo.get!(ConditionIncident, group.id),
               tick(2)
             )
  end

  test "accepted critical covers its exact warning lifetime and suppresses redundant lower delivery" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    accept(critical, tick(2))
    warn_fact = Repo.get!(ConditionFact, critical.covered_warn_fact_id)
    assert warn_fact.covered_by_occurrence_id == critical.id
    record(elastic, "WARN", 3)
    assert length(occurrences(group)) == 1
    record(linux, "OK", 4)
    assert Repo.get!(ConditionIncident, group.id).status == "open"
    assert Repo.get!(ConditionFact, warn_fact.id).ended_at == nil
    assert length(occurrences(group)) == 1
  end

  test "warning waits only while eligible critical has live retry budget" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(elastic, "WARN", 1)
    record(linux, "CRIT", 1)
    group = Repo.get!(ConditionIncident, group.id)
    warning = occurrence(group, "severity", "WARN")
    critical = occurrence(group, "severity", "CRIT")

    assert {:gated, ["higher_severity_delivery"], _} =
             Conditions.delivery_eligibility(warning, group, tick(2))

    Monitoring.change(critical, %{status: "exhausted"})

    Repo.update_all(
      from(j in Oban.Job, where: fragment("?->>'occurrence_id' = ?", j.args, ^critical.id)),
      set: [state: "discarded"]
    )

    assert :eligible = Conditions.delivery_eligibility(warning, group, tick(2))
    assert Repo.get!(Occurrence, critical.id).status == "exhausted"
    assert Repo.aggregate(Occurrence, :count) == 2
  end

  test "partial recovery ends only unsupported facts and preserves a still-supported lower retry" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(elastic, "WARN", 1)
    warning = occurrence(group, "severity", "WARN")
    record(linux, "CRIT", 1, [impact("blocked-writes")])
    critical = occurrence(group, "severity", "CRIT")
    blocked = occurrence(group, "impact", "blocked-writes")
    record(linux, "OK", 2)
    assert Repo.get!(Occurrence, critical.id).status == "superseded"
    assert Repo.get!(Occurrence, blocked.id).status == "superseded"
    assert Repo.get!(Occurrence, warning.id).status == "pending"

    assert :eligible =
             Conditions.delivery_eligibility(
               warning,
               Repo.get!(ConditionIncident, group.id),
               tick(2)
             )
  end

  test "withdrawing the original observer keeps equivalent support and frozen notification provenance" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    record(elastic, "CRIT", 1)
    retire(linux, "source_removed", tick(2))
    assert Repo.get!(ConditionIncident, group.id).status == "open"

    assert :eligible =
             Conditions.delivery_eligibility(
               critical,
               Repo.get!(ConditionIncident, group.id),
               tick(2)
             )

    assert Repo.get!(Occurrence, critical.id).payload == critical.payload
    assert record(elastic, "OK", 3).closure_reason == "source_removed"

    refute Repo.exists?(
             from o in Occurrence,
               where: o.condition_incident_id == ^group.id and o.kind == "resolved"
           )
  end

  test "retained failure survives unavailable samples and unrelated healthy contributions" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1)
    assert record(linux, "UNKNOWN", 2).id == group.id
    assert record(elastic, "OK", 1) == nil
    assert Repo.get!(ConditionIncident, group.id).status == "open"
    assert Repo.get!(ConditionIncident, group.id).health == "CRIT"
    assert length(contributions(group)) == 1
  end

  test "all contributions ending closes one episode and later failure never inherits acknowledgement" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1) |> acknowledge()
    record(elastic, "CRIT", 1)
    record(linux, "OK", 2)
    closed = record(elastic, "OK", 2)
    assert closed.status == "closed"
    assert closed.closure_reason == "measured_recovery"
    assert closed.acknowledgement_mode == nil
    next = record(linux, "CRIT", 3)
    assert next.id != group.id
    assert next.acknowledgement_revision == 0
    assert next.acknowledgement_mode == nil

    refute Repo.exists?(
             from o in Occurrence,
               where: o.condition_incident_id == ^group.id and o.kind == "resolved"
           )
  end

  test "prior attempted delivery yields one terminal occurrence with exact closing evidence" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    Repo.insert!(%Attempt{occurrence_id: critical.id, status: "started", started_at: tick(1)})
    record(elastic, "CRIT", 1)
    record(linux, "OK", 2)
    maintain(elastic, 100)
    closed = record(elastic, "OK", 3)

    terminal =
      Repo.one!(
        from o in Occurrence, where: o.condition_incident_id == ^group.id and o.kind == "resolved"
      )

    assert terminal.payload["closure_reason"] == "measured_recovery"
    assert terminal.payload["observation_id"] == closed.closing_observation_id
    assert Conditions.delivery_eligibility(terminal, closed, tick(3)) == :eligible

    assert Repo.exists?(
             from e in OccurrenceEvidence,
               where: e.occurrence_id == ^terminal.id and e.role == "closure"
           )
  end

  test "SMTP shared closures retain actual recovery measurements without declaring withdrawn monitoring healthy" do
    original =
      Map.new([:notification_adapter, :smtp], &{&1, Application.fetch_env(:mondek, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:mondek, key, value)
        {key, :error} -> Application.delete_env(:mondek, key)
      end)
    end)

    Application.put_env(:mondek, :notification_adapter, :smtp)

    Application.put_env(:mondek, :smtp,
      from: "mondek@example.invalid",
      to: "operator@example.invalid"
    )

    for mode <- [:recovered, :withdrawn] do
      linux = member("Linux #{mode}", namespace: to_string(mode))
      elastic = member("Elasticsearch #{mode}", namespace: to_string(mode))
      group = record(linux, "CRIT", 1)
      record(elastic, "CRIT", 1)
      critical = occurrence(group, "severity", "CRIT")
      Repo.insert!(%Attempt{occurrence_id: critical.id, status: "started", started_at: tick(1)})

      if mode == :recovered,
        do: record(linux, "OK", 2),
        else: retire(linux, "source_removed", tick(2))

      record(elastic, "OK", 3)

      terminal =
        Repo.one!(
          from o in Occurrence,
            where: o.condition_incident_id == ^group.id and o.kind == "resolved"
        )

      assert terminal.payload["email"]["measured_health"] == "OK"

      body =
        terminal
        |> Mondek.NotificationDelivery.message()
        |> String.split("\r\n\r\n", parts: 2)
        |> List.last()
        |> String.replace("\r\n", "")
        |> Base.decode64!()

      assert body =~ "Previous incident severity: CRIT"

      if mode == :recovered do
        assert body =~ "RECOVERED:"
        assert body =~ "Recovery measurement: OK"
      else
        assert body =~ "CLOSED:"
        assert body =~ "Recovery was not established for all contributing checks"
        refute body =~ "Recovery measurement: OK"
      end
    end
  end

  test "equal receipt timestamps preserve the exact final recovery observation instead of UUID order" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    group = record(linux, "CRIT", 1)
    record(elastic, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    Repo.insert!(%Attempt{occurrence_id: critical.id, status: "started", started_at: tick(1)})
    [first, last] = Enum.sort_by(contributions(group), & &1.id, :desc)

    members =
      Map.new([linux, elastic], fn {assignment, _, _} = entry -> {assignment.id, entry} end)

    assert record(members[first.assignment_id], "OK", 2).status == "open"
    closed = record(members[last.assignment_id], "OK", 2)
    last = Repo.get!(Incident, last.id)
    first = Repo.get!(Incident, first.id)
    assert first.closed_at == last.closed_at
    assert closed.closing_observation_id == last.closing_observation_id

    terminal =
      Repo.one!(
        from o in Occurrence, where: o.condition_incident_id == ^group.id and o.kind == "resolved"
      )

    assert terminal.payload["observation_id"] == last.closing_observation_id
    assert terminal.payload["contribution_id"] == last.id
  end

  test "impact disappearance and return creates a new fact but captured keys keep acknowledgement" do
    linux = member("Linux")
    group = record(linux, "CRIT", 1, [impact("blocked-writes")]) |> acknowledge()
    first = occurrence(group, "impact", "blocked-writes")
    record(linux, "CRIT", 2)
    record(linux, "CRIT", 3, [impact("blocked-writes", "Still blocked")])
    saved = Repo.get!(ConditionIncident, group.id)
    assert Monitoring.acknowledgement_active?(saved, tick(3))
    assert Repo.get!(Occurrence, first.id).status == "superseded"

    impact_occurrences =
      occurrences(group) |> Enum.filter(&(&1.payload["requested_fact"]["kind"] == "impact"))

    assert length(impact_occurrences) == 2
    assert length(Enum.uniq_by(impact_occurrences, & &1.condition_fact_id)) == 2
    assert saved.acknowledgement_revision == group.acknowledgement_revision
  end

  test "all outputs in one observation reduce together without an artificial episode boundary" do
    {assignment, first, definition} = member("Multi-output")

    second =
      Repo.insert!(%ResultStream{
        assignment_id: assignment.id,
        result_key: "secondary",
        label: "Secondary observer",
        target: first.target,
        condition: first.condition,
        environment: first.environment
      })

    definition =
      Map.update!(
        definition,
        "outputs",
        &(&1 ++ [%{"key" => "secondary", "condition" => first.condition}])
      )

    first_member = {assignment, first, definition}
    second_member = {assignment, second, definition}
    group = record(first_member, "CRIT", 1) |> acknowledge()
    original = occurrences(group)

    {:ok, _} =
      Repo.transaction(fn ->
        Monitoring.lock_assignment(assignment.id)
        Conditions.lock_keys!([Conditions.identity(definition, first.result_key)])
        one = observation(first_member, "OK", 2, [])
        two = observation(second_member, "CRIT", 2, [])

        left =
          Conditions.observe!(
            assignment,
            first,
            one,
            definition,
            %{"health" => "OK", "impacts" => []},
            tick(2)
          )

        right =
          Conditions.observe!(
            assignment,
            second,
            two,
            definition,
            %{"health" => "CRIT", "impacts" => []},
            tick(2)
          )

        Conditions.reduce!([left, right], tick(2))
      end)

    saved = Repo.get!(ConditionIncident, group.id)
    assert saved.status == "open"
    assert Monitoring.acknowledgement_active?(saved, tick(2))
    assert Enum.map(occurrences(group), & &1.id) == Enum.map(original, & &1.id)
  end

  test "concurrent first arrivals share exactly one open episode and one severity occurrence" do
    linux = member("Linux")
    elastic = member("Elasticsearch")
    parent = self()

    tasks =
      Enum.map([linux, elastic], fn entry ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> record(entry, "CRIT", 1)
          end
        end)
      end)

    for _ <- tasks do
      assert_receive {:ready, pid}
      send(pid, :go)
    end

    [one, two] = Enum.map(tasks, &Task.await(&1, 10_000))
    assert one.id == two.id
    assert length(contributions(one)) == 2
    assert length(occurrences(one)) == 1
    assert length(facts(one)) == 2
  end

  test "large and reversed declaration batches acquire bounded deterministic lock stripes" do
    identities =
      for index <- 1..16_384,
          do: %{
            "namespace" => "large-inventory",
            "key" => "condition-#{index}",
            "environment" => "production"
          }

    stripes = Conditions.lock_stripes(identities)
    assert length(stripes) <= 256
    assert length(stripes) > 200
    assert stripes == Enum.sort(Enum.uniq(stripes))
    assert stripes == Conditions.lock_stripes(Enum.reverse(identities))
    assert stripes == Conditions.lock_stripes(identities ++ identities)

    tasks =
      Enum.map([identities, Enum.reverse(identities)], fn ordered ->
        Task.async(fn ->
          Repo.transaction(fn ->
            Conditions.lock_keys!(ordered)

            %{rows: [[count]]} =
              Repo.query!(
                "SELECT count(*) FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory' AND classid=931741 AND objsubid=2"
              )

            assert count <= 256
          end)
        end)
      end)

    assert Enum.all?(Task.await_many(tasks, 30_000), &match?({:ok, _}, &1))
  end

  test "stale acknowledgement review cannot silently cover newly material evidence" do
    linux = member("Linux")
    group = record(linux, "WARN", 1)
    record(linux, "CRIT", 2)

    assert {:error, :stale} =
             Conditions.acknowledge(
               group.id,
               %{
                 "mode" => "until_incident_ends",
                 "revision" => group.acknowledgement_revision,
                 "attention_revision" => group.attention_revision
               },
               "Reviewed the warning",
               tick(2)
             )

    assert Repo.get!(ConditionIncident, group.id).acknowledgement_mode == nil
  end

  test "late critical receipt never covers a new episode's warning lifetime" do
    linux = member("Linux")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    record(linux, "OK", 2)
    next = record(linux, "WARN", 3)
    warn = occurrence(next, "severity", "WARN")
    accept(critical, tick(4))

    assert Repo.get!(ConditionFact, critical.covered_warn_fact_id).covered_by_occurrence_id ==
             critical.id

    assert Repo.get!(ConditionFact, warn.condition_fact_id).covered_by_occurrence_id == nil
    assert :eligible = Conditions.delivery_eligibility(warn, next, tick(4))
  end

  test "database rejects reassignment, duplicate live facts and mixed notification owners" do
    linux = member("Linux")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    [contribution] = contributions(group)

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE incidents SET condition_incident_id=NULL WHERE id=$1", [
        Ecto.UUID.dump!(contribution.id)
      ])
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE occurrences SET incident_id=$1 WHERE id=$2", [
        Ecto.UUID.dump!(contribution.id),
        Ecto.UUID.dump!(critical.id)
      ])
    end

    fact = Repo.get!(ConditionFact, critical.condition_fact_id)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%ConditionFact{
        condition_incident_id: group.id,
        kind: fact.kind,
        key: fact.key,
        label: fact.label,
        opened_at: tick(2),
        opening_observation_id: fact.opening_observation_id,
        opening_incident_id: contribution.id
      })
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE occurrence_evidence SET generation=generation+1 WHERE occurrence_id=$1",
        [Ecto.UUID.dump!(critical.id)]
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE condition_incidents SET environment='elsewhere' WHERE id=$1", [
        Ecto.UUID.dump!(group.id)
      ])
    end
  end

  test "terminal group deletion removes cyclic owned facts while ordinary history remains intact" do
    linux = member("Linux")
    group = record(linux, "CRIT", 1)
    critical = occurrence(group, "severity", "CRIT")
    accept(critical, tick(2))
    record(linux, "OK", 3)
    occurrence_ids = Enum.map(occurrences(group), & &1.id)
    Repo.delete_all(from a in Attempt, where: a.occurrence_id in ^occurrence_ids)
    assert {1, _} = Repo.delete_all(from g in ConditionIncident, where: g.id == ^group.id)
    assert Repo.aggregate(ConditionFact, :count) == 0
    assert Repo.aggregate(OccurrenceEvidence, :count) == 0
    refute Repo.exists?(from i in Incident, where: i.condition_incident_id == ^group.id)
    assert Repo.aggregate(Assignment, :count) >= 4
  end

  defp member(label, options \\ []) do
    id = Ecto.UUID.generate()
    source = Keyword.get(options, :source, "condition-tests")
    environment = Keyword.get(options, :environment, "production")

    condition = %{
      "namespace" => Keyword.get(options, :namespace, "shared.storage"),
      "key" => Keyword.get(options, :key, "orders.disk"),
      "label" => "Orders storage pressure"
    }

    target = %{"kind" => "volume", "key" => Keyword.get(options, :target, id), "label" => label}

    output = %{
      "key" => "capacity",
      "label" => label,
      "target" => target,
      "condition" => condition
    }

    definition = %{
      "outputs" => [output],
      "environment" => environment,
      "environment_label" => environment
    }

    assignment =
      Repo.insert!(%Assignment{
        id: id,
        kind: "10000000-0000-4000-8000-000000000003",
        label: label,
        source_id: source,
        source_key: id,
        environment: environment,
        params: %{},
        expected_keys: ["capacity"],
        outputs: [output],
        desired_generation: 1,
        authorized_generation: 1
      })

    Repo.insert!(%Configuration{
      assignment_id: id,
      generation: 1,
      params: %{},
      definition: definition,
      saved_at: at()
    })

    stream =
      Repo.insert!(%ResultStream{
        assignment_id: id,
        result_key: "capacity",
        label: label,
        target: target,
        condition: condition,
        environment: environment
      })

    {assignment, stream, definition}
  end

  defp observation({assignment, stream, _}, health, sequence, impacts) do
    Repo.insert!(%Observation{
      id: Ecto.UUID.generate(),
      assignment_id: assignment.id,
      installation_id: Ecto.UUID.generate(),
      session_id: Ecto.UUID.generate(),
      generation: 1,
      sequence: sequence,
      started_at: at(),
      evaluated_at: tick(sequence),
      received_at: tick(sequence),
      disposition: "current",
      payload: %{
        "complete" => true,
        "results" => [
          %{
            "key" => stream.result_key,
            "health" => health,
            "summary" => "Independent measured evidence",
            "impacts" => impacts,
            "source_at" => Monitoring.iso(tick(sequence))
          }
        ]
      }
    })
  end

  defp record({assignment, stream, definition} = member, health, sequence, impacts \\ []) do
    {:ok, group} =
      Repo.transaction(fn ->
        Monitoring.lock_assignment(assignment.id)
        Conditions.lock_keys!([Conditions.identity(definition, stream.result_key)])
        evidence = observation(member, health, sequence, impacts)

        id =
          Conditions.observe!(
            assignment,
            stream,
            evidence,
            definition,
            %{"health" => health, "impacts" => impacts},
            tick(sequence)
          )

        if id, do: Conditions.reduce!(id, tick(sequence), evidence)
      end)

    group
  end

  defp retire({assignment, stream, definition}, reason, at) do
    {:ok, _} =
      Repo.transaction(fn ->
        Monitoring.lock_assignment(assignment.id)
        Conditions.lock_keys!([Conditions.identity(definition, stream.result_key)])
        ids = Conditions.retire_contributions!([stream.id], reason, at)
        Monitoring.change(stream, %{retired_at: at, retirement_reason: reason})
        Conditions.reduce!(ids, at)
      end)
  end

  defp acknowledge(group) do
    assert {:ok, _} =
             Conditions.acknowledge(
               group.id,
               %{
                 "mode" => "until_incident_ends",
                 "revision" => group.acknowledgement_revision,
                 "attention_revision" => group.attention_revision
               },
               "Investigating the shared storage problem",
               tick(1)
             )

    Repo.get!(ConditionIncident, group.id)
  end

  defp accept(occurrence, at) do
    {:ok, _} =
      Repo.transaction(fn ->
        Conditions.lock!(occurrence.condition_incident_id)

        Repo.insert!(%Attempt{
          occurrence_id: occurrence.id,
          status: "accepted",
          started_at: at,
          finished_at: at,
          http_status: 202
        })

        current = Repo.get!(Occurrence, occurrence.id)

        unless current.status == "superseded",
          do: Monitoring.change(current, %{status: "delivered", delivered_at: at})

        Conditions.delivery_accepted!(occurrence, at)
      end)
  end

  defp maintain({assignment, _, _}, seconds) do
    assert {:ok, _} =
             reviewed_maintenance_fixture(
               assignment.id,
               seconds,
               "Planned storage maintenance",
               at()
             )
  end

  defp contributions(group),
    do:
      Repo.all(
        from i in Incident,
          where: i.condition_incident_id == ^group.id,
          order_by: [asc: i.opened_at, asc: i.id]
      )

  defp occurrences(group),
    do:
      Repo.all(
        from o in Occurrence,
          where: o.condition_incident_id == ^group.id,
          order_by: [asc: o.inserted_at, asc: o.id]
      )

  defp facts(group),
    do: Repo.all(from f in ConditionFact, where: f.condition_incident_id == ^group.id)

  defp occurrence(group, kind, key),
    do:
      Repo.one!(
        from o in Occurrence,
          join: f in ConditionFact,
          on: f.id == o.condition_fact_id,
          where:
            o.condition_incident_id == ^group.id and f.kind == ^kind and f.key == ^key and
              is_nil(f.ended_at)
      )

  defp jobs,
    do:
      Repo.all(
        from j in Oban.Job,
          order_by: [asc: j.id],
          select: %{id: j.id, args: j.args, attempt: j.attempt, max_attempts: j.max_attempts}
      )

  defp impact(key, label \\ "Blocked writes"), do: %{"key" => key, "label" => label}
  defp tick(seconds), do: DateTime.add(at(), seconds)
end

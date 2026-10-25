# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Mondek.{Repo, Monitoring, Assignment, Incident, Observation, Occurrence, Attempt}
      import Ecto.Query
      import Mondek.Fixtures
    end
  end

  setup context do
    Mondek.Repo.query!(
      "TRUNCATE discovery_changes, configuration_revisions, configuration_git_objects, configuration_repository, runners, assignments, oban_jobs, configuration_rules, configuration_policy_projects, configuration_rule_diagnostics, maintenance_windows, maintenance_series, condition_incidents, monitoring_incidents, monitoring_gaps RESTART IDENTITY CASCADE"
    )

    unless context[:empty_source_fixture], do: Mondek.Fixtures.seed_source_checks()
    :ok
  end
end

defmodule Mondek.Fixtures do
  @fixture_source "controller-fixture-source"
  @fixture_revision String.duplicate("a", 64)
  @fixture_specs [
    {"10000000-0000-4000-8000-000000000001", "Linux filesystem", "capacity",
     %{"path" => "/", "warn_percent" => 80, "crit_percent" => 90}},
    {"10000000-0000-4000-8000-000000000002", "HTTP readiness", "readiness",
     %{"url" => "http://target:8080/ready"}},
    {"10000000-0000-4000-8000-000000000003", "Python backlog consumer", "backlog",
     %{"url" => "http://target:8080/data", "warn_count" => 5, "crit_count" => 10}}
  ]

  # Current source-owned rows with stable fixture UUIDs. This is test data, not a
  # public setup API or an alternate controller assignment execution model.
  def seed_source_checks do
    alias Mondek.{Repo, Runner}
    c = control()

    Repo.get(Runner, c["installation_id"]) ||
      Repo.insert!(%Runner{
        id: c["installation_id"],
        session_id: c["session_id"],
        boot: 1,
        last_seen_at: at(),
        label: "Fixture observer"
      })

    for {id, label, key, params} <- @fixture_specs do
      Repo.get(Mondek.Assignment, id) || insert_source_fixture(id, id, label, key, params)
    end

    Mondek.ConfigurationRepository.state()
  end

  defp insert_source_fixture(id, key, label, output, params) do
    alias Mondek.{Repo, Assignment, Configuration, ResultStream}

    fields =
      Map.new(params, fn {name, value} ->
        type =
          cond do
            is_integer(value) and name not in ["warn_percent", "crit_percent"] -> "integer"
            is_number(value) -> "number"
            true -> "string"
          end

        spec = %{"type" => type, "label" => name}

        spec =
          if name in ["path", "url"],
            do: Map.put(spec, "choices", [value]),
            else:
              spec
              |> Map.put("minimum", 0)
              |> Map.put(
                "maximum",
                if(name in ["warn_percent", "crit_percent"], do: 100, else: 1_000_000)
              )

        {name, spec}
      end)

    comparisons =
      cond do
        Map.has_key?(params, "warn_percent") ->
          [%{"left" => "warn_percent", "op" => "lt", "right" => "crit_percent"}]

        Map.has_key?(params, "warn_count") ->
          [%{"left" => "warn_count", "op" => "lt", "right" => "crit_count"}]

        true ->
          []
      end

    outputs = [
      %{
        "key" => output,
        "label" => label,
        "target" => %{"key" => id, "kind" => "host", "label" => label}
      }
    ]

    a =
      Repo.insert!(%Assignment{
        id: id,
        kind: "python",
        label: label,
        source_id: @fixture_source,
        source_key: key,
        source_revision: @fixture_revision,
        definition_revision: @fixture_revision,
        runner_id: control()["installation_id"],
        params_owner: "ui",
        parameter_schema: %{"fields" => fields, "comparisons" => comparisons},
        params: params,
        source_defaults: params,
        expected_keys: [output],
        outputs: outputs
      })

    Repo.insert!(%Configuration{
      assignment_id: id,
      generation: 1,
      params: params,
      definition: Mondek.Inventory.definition(a),
      saved_at: at()
    })

    Repo.insert!(%ResultStream{
      assignment_id: id,
      admission_generation: 1,
      result_key: output,
      label: label,
      target: hd(outputs)["target"]
    })

    a
  end

  def create_source_fixture(kind, label, params) do
    output =
      cond do
        Map.has_key?(params, "path") -> "capacity"
        Map.has_key?(params, "warn_count") -> "backlog"
        true -> "readiness"
      end

    id = Ecto.UUID.generate()
    row = insert_source_fixture(id, kind <> ":" <> id, label, output, params)
    {:ok, Mondek.Monitoring.public(row)}
  end

  def withdraw_source_fixture(id, reason, at \\ at()) do
    Mondek.Repo.transaction(fn ->
      row = Mondek.Monitoring.lock_assignment(id) || Mondek.Repo.rollback(:not_found)
      Mondek.Monitoring.retire_source_assignment!(row, reason, at) |> Mondek.Monitoring.public()
    end)
  end

  def reviewed_acknowledgement_fixture(id, duration_or_options, note, at \\ at()) do
    options =
      if is_integer(duration_or_options) do
        row = Mondek.Repo.get!(Mondek.Incident, id)

        %{
          "mode" => if(duration_or_options == 0, do: "end", else: "duration"),
          "revision" => row.acknowledgement_revision,
          "attention_revision" => row.attention_revision
        }
        |> then(fn options ->
          if duration_or_options == 0,
            do: options,
            else: Map.put(options, "seconds", duration_or_options)
        end)
      else
        duration_or_options
      end

    Mondek.Monitoring.acknowledge(id, options, note, at)
  end

  def reviewed_monitoring_acknowledgement_fixture(id, duration_or_options, note, at \\ at()) do
    options =
      if is_integer(duration_or_options) do
        row = Mondek.Repo.get!(Mondek.MonitoringIncident, id)

        %{
          "mode" => if(duration_or_options == 0, do: "end", else: "duration"),
          "revision" => row.acknowledgement_revision,
          "attention_revision" => row.attention_revision
        }
        |> then(fn options ->
          if duration_or_options == 0,
            do: options,
            else: Map.put(options, "seconds", duration_or_options)
        end)
      else
        duration_or_options
      end

    Mondek.MonitoringLoss.acknowledge(id, options, note, at)
  end

  def reviewed_maintenance_fixture(id, seconds, reason, at \\ Mondek.Monitoring.now()) do
    if seconds == 0 do
      import Ecto.Query

      row =
        Mondek.Repo.one(
          from w in Mondek.MaintenanceWindow,
            where: w.assignment_id == ^id and is_nil(w.cancelled_at),
            order_by: [desc: w.inserted_at],
            limit: 1
        )

      if row, do: Mondek.Maintenance.cancel(row.id, row.revision, reason, at), else: {:ok, nil}
    else
      with {:ok, seed} <- Mondek.Maintenance.seed(id, nil, at),
           proposal =
             Map.merge(seed["proposal"], %{
               "reason" => reason,
               "timezone" => "UTC",
               "start_mode" => "now",
               "ends_local" =>
                 DateTime.add(at, seconds) |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
             }),
           {:ok, preview} <- Mondek.Maintenance.preview(proposal, 1, at) do
        Mondek.Maintenance.apply(preview["review_token"], preview["proposal"], at)
      end
    end
  end

  def at, do: ~U[2009-09-15 08:00:01.000000Z]

  def report(overrides \\ %{}) do
    Path.expand("../../../contracts/v1/observation.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.merge(overrides)
  end

  def control(overrides \\ %{}) do
    r = report()

    Map.merge(
      %{
        "version" => 1,
        "installation_id" => r["installation_id"],
        "session_id" => r["session_id"],
        "boot" => 1,
        "status" => %{"queue_count" => 0},
        "prepared" => %{
          "10000000-0000-4000-8000-000000000001" => 1,
          "10000000-0000-4000-8000-000000000002" => 1,
          "10000000-0000-4000-8000-000000000003" => 1
        },
        "active" => %{},
        "wait_seconds" => 0
      },
      overrides
    )
  end

  def connect(overrides \\ %{}), do: Mondek.Monitoring.control(control(overrides), at())

  def envelope(reports, overrides \\ %{}) do
    c = control()

    Map.merge(
      %{
        "version" => 1,
        "installation_id" => c["installation_id"],
        "session_id" => c["session_id"],
        "reports" => reports
      },
      overrides
    )
  end

  def ingest(report, at \\ at()), do: Mondek.Monitoring.ingest(envelope([report]), at)

  def measurement(health, sequence \\ 1, overrides \\ %{}) do
    report(
      Map.merge(
        %{
          "id" => Ecto.UUID.generate(),
          "sequence" => sequence,
          "results" => [
            %{
              "key" => "capacity",
              "health" => health,
              "value" => 90,
              "summary" => "Real sample in contract fixture",
              "source_at" => "2009-09-15T08:00:00.010000Z"
            }
          ]
        },
        overrides
      )
    )
  end

  def disposition({:ok, %{"dispositions" => [%{"disposition" => value}]}}), do: value
end

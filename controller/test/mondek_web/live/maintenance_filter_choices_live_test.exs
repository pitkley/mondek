# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.MaintenanceFilterChoicesLiveTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Mondek.{MaintenanceSelection, ResultStream, Runner}
  @endpoint MondekWeb.Endpoint

  test "named suggestions keep exact IDs and target selections cover other observers" do
    {first, _} = monitored("A", "production", "Production")
    {_second, _} = monitored("B", "production", "Production")
    {:ok, view, _} = live(build_conn(), "/maintenance/new")

    assert has_element?(
             view,
             "#maintenance-environment-options option[value='production']",
             "Production"
           )

    assert has_element?(
             view,
             "#maintenance-runner-options option[value='#{first.id}']",
             "Runner A"
           )

    assert has_element?(view, "#maintenance-source-options option[value='maintenance.choice']")
    assert has_element?(view, "label[for='maintenance-runner']", "Observing runner")

    filters = %{"kind" => "target", "environment" => "production", "runner_id" => first.id}
    view |> form("#maintenance-selection-form", filters: filters) |> render_change()
    assert has_element?(view, "#maintenance-runner[value='#{first.id}']")
    assert has_element?(view, ".maintenance-picker-rows", "all matching observers")
    [target] = MaintenanceSelection.list(filters)["items"]
    assert target["matched_results"] == 2
    view |> form("#maintenance-selection-form", selected_keys: [target["key"]]) |> render_change()
    assert has_element?(view, "#maintenance-selected-count", "1 selection")

    unknown = Ecto.UUID.generate()
    view |> form("#maintenance-selection-form", filters: %{runner_id: unknown}) |> render_change()
    assert has_element?(view, "#maintenance-runner[value='#{unknown}']")
    assert has_element?(view, "#maintenance-selected-count", "1 selection")
    view |> element("#maintenance-review-selected") |> render_click()
    assert has_element?(view, ".maintenance-picker-rows", "Shared host")
  end

  test "suggestions are bounded and IDs outside the suggestions remain usable" do
    entries =
      for number <- 0..100 do
        id = String.pad_leading(to_string(number), 3, "0")
        monitored(id, "env-" <> id, "Environment " <> id, "source-" <> id)
      end

    {last, assignment} = List.last(entries)
    choices = MaintenanceSelection.filter_choices()

    for key <- ~w(environments runners sources) do
      assert length(choices[key]) == 100
      assert choices["truncated"][key]
    end

    refute Enum.any?(choices["runners"], &(&1["id"] == last.id))
    {:ok, view, _} = live(build_conn(), "/maintenance/new")
    assert has_element?(view, "#maintenance-filter-help", "up to 100")
    refute has_element?(view, "#maintenance-runner-options option[value='#{last.id}']")

    view
    |> form("#maintenance-selection-form",
      filters: %{runner_id: last.id, environment: "env-100", source_id: "source-100"}
    )
    |> render_change()

    assert has_element?(view, "#maintenance-runner[value='#{last.id}']")
    assert has_element?(view, "#maintenance-environment[value='env-100']")
    assert has_element?(view, ".maintenance-picker-rows", assignment.label)
  end

  defp monitored(name, environment, environment_label, source \\ "maintenance.choice") do
    runner =
      Repo.insert!(%Runner{
        id: Ecto.UUID.generate(),
        session_id: Ecto.UUID.generate(),
        boot: 1,
        label: "Runner " <> name,
        last_seen_at: at()
      })

    assignment =
      Repo.insert!(%Assignment{
        id: Ecto.UUID.generate(),
        runner_id: runner.id,
        kind: "10000000-0000-4000-8000-000000000003",
        label: "Check " <> name,
        source_id: source,
        source_key: name,
        environment: environment,
        environment_label: environment_label,
        params: %{},
        expected_keys: ["value"]
      })

    Repo.insert!(%ResultStream{
      assignment_id: assignment.id,
      result_key: "value",
      label: "Value " <> name,
      environment: environment,
      environment_label: environment_label,
      target: %{"kind" => "host", "key" => "shared-host", "label" => "Shared host"}
    })

    {runner, assignment}
  end
end

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

    render_hook(view, "filter_open", %{"field" => "environment"})

    assert has_element?(
             view,
             "#maintenance-choice-search-options button[phx-value-key='production']",
             "Production"
           )

    render_hook(view, "filter_open", %{"field" => "runner_id"})

    assert has_element?(
             view,
             "#maintenance-choice-search-options button[phx-value-key='#{first.id}']",
             "Runner A"
           )

    render_hook(view, "filter_open", %{"field" => "source_id"})
    assert render(view) =~ "maintenance.choice"
    filters = %{"kind" => "target", "environment" => "production", "runner_id" => first.id}
    choose_filters(view, filters)
    assert has_element?(view, "#maintenance-choice-search-chip-runner_id", "Runner A")
    assert has_element?(view, ".preview-maintenance-choice-toolbar", "across runners")
    [target] = MaintenanceSelection.list(filters)["items"]
    assert target["matched_results"] == 2
    view |> form("#maintenance-selection-form", selected_keys: [target["key"]]) |> render_change()
    assert has_element?(view, "#maintenance-selected-count", "1 selected")
    unknown = Ecto.UUID.generate()
    choose_filters(view, %{"runner_id" => unknown})
    render_hook(view, "filter_close", %{})
    assert has_element?(view, "#maintenance-choice-search-chip-runner_id", "Runner A")
    refute has_element?(view, "#maintenance-choice-search-chip-runner_id", unknown)
    assert has_element?(view, "#maintenance-selected-count", "1 selected")

    render_submit(element(view, "#maintenance-choice-search"), %{"search" => "no matching target"})

    assert has_element?(view, ".preview-maintenance-pinned", "Shared host")
  end

  test "bounded suggestions still allow exact identifiers outside the first hundred" do
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

    choose_filters(view, %{
      "runner_id" => last.id,
      "environment" => "env-100",
      "source_id" => "source-100"
    })

    assert has_element?(view, "#maintenance-choice-search-chip-runner_id")
    assert has_element?(view, "#maintenance-choice-search-chip-environment")
    assert has_element?(view, "table[aria-label='Checks and targets']", assignment.label)
  end

  defp choose_filters(view, values) do
    for {field, value} <- values do
      render_hook(view, "filter_open", %{"field" => to_string(field)})
      render_hook(view, "filter_query", %{"search" => value})
      render_hook(view, "filter_select", %{"key" => value})
    end

    view
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

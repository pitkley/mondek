# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationValuesTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias MondekWeb.ConfigurationValues

  test "exception comparison names units, complete saved values and the masked rule" do
    assignment = %{
      "params" => %{"limit" => 80},
      "source_defaults" => %{"limit" => 100},
      "configuration_origin" => %{"kind" => "exception", "managed_project" => "Operations"},
      "parameter_schema" => %{
        "fields" => %{"limit" => %{"label" => "Threshold", "unit" => "items"}}
      }
    }

    html =
      render_component(&ConfigurationValues.comparison/1,
        assignment: assignment,
        values: %{
          "masked_params" => %{"limit" => 70},
          "masked_origin" => %{
            "kind" => "rule",
            "rule_id" => "rule-id",
            "rule_name" => "Volume policy"
          }
        }
      )

    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "table[aria-label='Saved values compared with defaults']")
           |> LazyHTML.text() =~ "Threshold"

    assert LazyHTML.query(document, ".configuration-difference") |> LazyHTML.text() =~ "(items)"
    assert LazyHTML.query(document, ".configuration-difference") |> LazyHTML.text() =~ "100"
    assert LazyHTML.query(document, ".configuration-difference") |> LazyHTML.text() =~ "80"
    assert LazyHTML.query(document, ".configuration-difference") |> LazyHTML.text() =~ "70"

    assert LazyHTML.query(
             document,
             "#configuration-under-exception a[href='/configuration/rules/rule-id']"
           )
           |> LazyHTML.text()
           |> String.trim() == "Volume policy"

    assert html =~ "complete parameter set"
  end

  test "equal defaults remain an explicit override and a blocked removal stays visible" do
    assignment = %{
      "params" => %{"limit" => 80},
      "source_defaults" => %{"limit" => 80},
      "configuration_origin" => %{"kind" => "exception"},
      "parameter_schema" => %{}
    }

    html =
      render_component(&ConfigurationValues.comparison/1,
        assignment: assignment,
        values: %{"masked_error" => "Matching rules conflict"}
      )

    assert html =~ "override still takes precedence"

    assert LazyHTML.from_document(html)
           |> LazyHTML.query("#configuration-hidden-conflict")
           |> LazyHTML.text() =~ "Matching rules conflict"
  end
end

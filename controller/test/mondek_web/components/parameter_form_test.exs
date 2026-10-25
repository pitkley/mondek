# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ParameterFormTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MondekWeb.ParameterForm

  test "comparison order puts the lower bound before the upper bound and fixed bindings last" do
    schema = %{
      "fields" => %{
        "upper" => integer_field("Upper bound"),
        "lower" => integer_field("Lower bound"),
        "binding" => %{"type" => "string", "label" => "Target", "choices" => ["node-a"]}
      },
      "comparisons" => [comparison("lower", "upper")]
    }

    html = render_fields(schema, %{"upper" => 20, "lower" => 10, "binding" => "node-a"})
    assert field_order(html) == ["lower", "upper", "binding"]
    assert html =~ "Lower bound must be less than Upper bound."
    assert html =~ "readonly"
    assert html =~ "value=\"node-a\""
  end

  test "transitive comparison chains determine order without relying on parameter names" do
    schema = %{
      "fields" => Map.new(~w(alpha middle zeta), &{&1, integer_field(&1)}),
      "comparisons" => [comparison("middle", "alpha"), comparison("zeta", "middle")]
    }

    assert field_order(render_fields(schema)) == ~w(zeta middle alpha)
  end

  test "unrelated fields and cyclic comparisons have deterministic complete fallback ordering" do
    schema = %{
      "fields" => Map.new(~w(alpha beta gamma delta), &{&1, integer_field(&1)}),
      "comparisons" => [comparison("alpha", "beta"), comparison("beta", "alpha")]
    }

    assert field_order(render_fields(schema)) == ~w(delta gamma alpha beta)

    assert field_order(render_fields(Map.put(schema, "comparisons", []))) ==
             ~w(alpha beta delta gamma)
  end

  test "ordering preserves mixed bulk controls and treats multi-choice fields as editable" do
    schema = %{
      "fields" => %{
        "alpha_fixed" => %{"type" => "integer", "choices" => [1]},
        "gamma" => integer_field("Limit"),
        "beta_choice" => %{"type" => "string", "choices" => ["normal", "strict"]}
      },
      "comparisons" => [comparison("alpha_fixed", "gamma")]
    }

    html =
      render_component(&ParameterForm.fields/1,
        id_prefix: "review",
        schema: schema,
        values: %{"alpha_fixed" => 1, "gamma" => 5, "beta_choice" => "normal"},
        mixed_fields: ["gamma"]
      )

    assert field_order(html) == ~w(beta_choice gamma alpha_fixed)
    document = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(document, "#review-gamma[disabled]")) == 1
    assert Enum.count(LazyHTML.query(document, "input[name='resolved[gamma]']")) == 2
    assert Enum.count(LazyHTML.query(document, "select#review-beta_choice")) == 1
    assert Enum.count(LazyHTML.query(document, "#review-alpha_fixed[readonly]")) == 1
    assert html =~ "Alpha fixed must be less than Limit."
  end

  defp integer_field(label), do: %{"type" => "integer", "label" => label}
  defp comparison(left, right), do: %{"left" => left, "op" => "lt", "right" => right}

  defp render_fields(schema, values \\ %{}) do
    render_component(&ParameterForm.fields/1, id_prefix: "review", schema: schema, values: values)
  end

  defp field_order(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(".field > label[for]")
    |> LazyHTML.attribute("for")
    |> Enum.map(&String.replace_prefix(&1, "review-", ""))
  end
end

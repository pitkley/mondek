# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ScalarFilterPickerTest do
  use ExUnit.Case, async: true
  alias MondekWeb.ScalarFilterPicker
  @fields [{"contact", "Contact", "pulse"}]
  defp choices("contact"),
    do: [{"all", "Any contact"}, {"recent", "Recent contact"}, {"overdue", "Contact overdue"}]

  test "suggestions omit clearing values and reject unknown fields" do
    assert %{options: [%{key: "recent"}]} =
             ScalarFilterPicker.draft(@fields, &choices/1, "contact", "RECENT")

    assert %{options: [_, _]} = ScalarFilterPicker.draft(@fields, &choices/1, "contact", "")
    assert ScalarFilterPicker.draft(@fields, &choices/1, "unknown", "") == nil
  end

  test "applied chip labels preserve unknown exact identities and omit defaults" do
    assert ScalarFilterPicker.chips(@fields, %{"contact" => "all"}, &choices/1) == []

    assert [%{label: "Recent contact"}] =
             ScalarFilterPicker.chips(@fields, %{"contact" => "recent"}, &choices/1)

    assert ScalarFilterPicker.label([], "unlisted-source") == "unlisted-source"
    assert ScalarFilterPicker.text(<<255>>) == ""
    assert ScalarFilterPicker.text(["bad"]) == ""
  end

  test "source IDs can use words reserved for other fields' clearing values" do
    fields = [{"source_id", "Source", "code"}]
    choices = fn _ -> [{"all", "all"}] end

    assert %{options: [%{key: "all"}]} =
             ScalarFilterPicker.draft(fields, choices, "source_id", "", [nil, ""])

    assert [%{label: "all"}] =
             ScalarFilterPicker.chips(fields, %{"source_id" => "all"}, choices, fn _ ->
               [nil, ""]
             end)
  end
end

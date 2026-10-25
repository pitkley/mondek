# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.DurationTest do
  use ExUnit.Case, async: true
  alias MondekWeb.Duration

  test "uses ordinary units for short schedules and day-long freshness budgets" do
    for {seconds, expected} <- [
          {0, "0 seconds"},
          {1.0, "1 second"},
          {3.0, "3 seconds"},
          {60, "1 minute"},
          {61, "1 minute 1 second"},
          {3_600, "1 hour"},
          {3_661, "1 hour 1 minute 1 second"},
          {21_600.0, "6 hours"},
          {86_400.0, "1 day"},
          {90_061, "1 day 1 hour 1 minute 1 second"},
          {172_800.0, "2 days"}
        ] do
      assert Duration.format_seconds(seconds) == expected
    end
  end

  test "preserves fractional-second precision and exact boundaries" do
    for {seconds, expected} <- [
          {0.1, "0.1 seconds"},
          {0.0000001, "0.0000001 seconds"},
          {59.999999999, "59.999999999 seconds"},
          {60.000000001, "1 minute 0.000000001 seconds"},
          {61.25, "1 minute 1.25 seconds"},
          {3_600.1, "1 hour 0.1 seconds"},
          {86_400.000001, "1 day 0.000001 seconds"}
        ] do
      assert Duration.format_seconds(seconds) == expected
    end
  end

  test "missing and invalid values do not imply a zero schedule" do
    for value <- [nil, -1, -0.1, "3", %{}] do
      assert Duration.format_seconds(value) == "Not recorded"
    end
  end
end

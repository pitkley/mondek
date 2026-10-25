# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceRecurrenceTest do
  use ExUnit.Case, async: true
  alias Mondek.MaintenanceRecurrence, as: Recurrence

  defp proposal(changes \\ %{}) do
    Map.merge(
      %{
        "start_mode" => "scheduled",
        "starts_local" => "2009-10-18T10:00",
        "ends_local" => "2009-10-18T11:00",
        "timezone" => "Europe/Berlin",
        "start_fold" => "reject",
        "end_fold" => "reject"
      },
      changes
    )
  end

  defp count(n, interval \\ 1), do: %{"count" => n, "interval" => interval}

  test "weekly civil clocks stay fixed while UTC offsets change" do
    assert {:ok, expanded} = Recurrence.expand(proposal(), count(3))
    [first, autumn, winter] = expanded["windows"]
    assert first["starts_at"] == "2009-10-18T08:00:00.000000Z"
    assert autumn["starts_at"] == "2009-10-25T09:00:00.000000Z"
    assert winter["starts_at"] == "2009-11-01T09:00:00.000000Z"
    assert Enum.map(expanded["windows"], & &1["index"]) == [1, 2, 3]
    assert Enum.all?(expanded["windows"], &(&1["elapsed_seconds"] == 3600))
    assert expanded["timezone_version"] == Mondek.MaintenanceTime.version()

    assert expanded["recurrence"] == %{
             "frequency" => "weekly",
             "interval" => 1,
             "end_mode" => "count",
             "count" => 3,
             "until_date" => nil
           }
  end

  test "overnight endpoints preserve civil dates and disclose the longer autumn window" do
    p = proposal(%{"starts_local" => "2009-10-17T23:00", "ends_local" => "2009-10-18T03:00"})
    assert {:ok, %{"windows" => [first, autumn]}} = Recurrence.expand(p, count(2))
    assert first["elapsed_seconds"] == 4 * 3600
    assert autumn["starts_local"] == "2009-10-24T23:00:00"
    assert autumn["ends_local"] == "2009-10-25T03:00:00"
    assert autumn["elapsed_seconds"] == 5 * 3600
  end

  test "end date is inclusive of local starts, never the overnight end" do
    p = proposal(%{"starts_local" => "2009-10-17T23:00", "ends_local" => "2009-10-18T03:00"})
    rule = %{"end_mode" => "date", "until_date" => "2009-10-31", "interval" => 2}
    assert {:ok, %{"windows" => [_, last], "recurrence" => saved}} = Recurrence.expand(p, rule)
    assert last["starts_local"] == "2009-10-31T23:00:00"
    assert last["ends_local"] == "2009-11-01T03:00:00"
    assert saved["count"] == nil
    assert saved["until_date"] == "2009-10-31"

    assert {:ok, %{"windows" => same}} =
             Recurrence.expand(p, %{rule | "until_date" => "2009-11-01"})

    assert length(same) == 2

    assert {:error, {:invalid, message}} =
             Recurrence.expand(p, %{rule | "until_date" => "2009-10-30"})

    assert message =~ "2–52 windows"
  end

  test "date ending cannot silently truncate more than fifty-two windows" do
    p = proposal(%{"starts_local" => "2009-01-04T10:00", "ends_local" => "2009-01-04T11:00"})
    rule = %{"end_mode" => "date", "until_date" => "2009-12-27"}
    assert {:ok, %{"windows" => rows}} = Recurrence.expand(p, rule)
    assert length(rows) == 52

    assert {:error, {:invalid, message}} =
             Recurrence.expand(p, %{rule | "until_date" => "2010-01-03"})

    assert message =~ "No dates are silently truncated"
    assert {:error, {:invalid, _}} = Recurrence.expand(p, %{rule | "until_date" => "2008-12-31"})
  end

  test "spring gap in a later window rejects the entire series with the exact endpoint" do
    for fold <- ["reject", "earlier", "later"] do
      p =
        proposal(%{
          "starts_local" => "2010-03-21T02:30",
          "ends_local" => "2010-03-21T03:30",
          "start_fold" => fold
        })

      assert {:error, {:invalid, message}} = Recurrence.expand(p, count(3))
      assert message =~ "Window 2 start (2010-03-28T02:30:00)"
      assert message =~ "does not exist"
    end
  end

  test "a later ambiguous endpoint requires explicit policy even when the first window is ordinary" do
    p = proposal(%{"starts_local" => "2009-10-18T02:10", "ends_local" => "2009-10-18T02:50"})
    assert {:error, {:invalid, message}} = Recurrence.expand(p, count(2))
    assert message =~ "Window 2 start (2009-10-25T02:10:00)"
    assert message =~ "occurs twice"

    assert {:ok, %{"windows" => [first, folded]}} =
             Recurrence.expand(
               Map.merge(p, %{"start_fold" => "earlier", "end_fold" => "later"}),
               count(2)
             )

    assert first["elapsed_seconds"] == 40 * 60
    assert folded["starts_at"] == "2009-10-25T00:10:00.000000Z"
    assert folded["ends_at"] == "2009-10-25T01:50:00.000000Z"
    assert folded["elapsed_seconds"] == 100 * 60

    assert {:error, {:invalid, message}} =
             Recurrence.expand(
               Map.merge(p, %{"start_fold" => "later", "end_fold" => "earlier"}),
               count(2)
             )

    assert message =~ "Window 2"
    assert message =~ "must end after"
  end

  test "non-hour daylight saving transitions use the timezone database" do
    p =
      proposal(%{
        "timezone" => "Australia/Lord_Howe",
        "starts_local" => "2009-09-27T02:15",
        "ends_local" => "2009-09-27T03:15"
      })

    assert {:error, {:invalid, message}} = Recurrence.expand(p, count(2))
    assert message =~ "Window 2 start (2009-10-04T02:15:00)"
    assert message =~ "does not exist"
  end

  test "subsecond evidence and non-hour timezone offsets are not rounded" do
    p =
      proposal(%{
        "timezone" => "Asia/Kathmandu",
        "starts_local" => "2009-10-18T10:00:00.123456",
        "ends_local" => "2009-10-18T10:00:00.654321"
      })

    assert {:ok, %{"windows" => [first, second]}} = Recurrence.expand(p, count(2))
    assert first["starts_at"] == "2009-10-18T04:15:00.123456Z"
    assert second["starts_at"] == "2009-10-25T04:15:00.123456Z"
    assert first["elapsed_seconds"] == 0.530865
  end

  test "overlapping repeated windows reject but touching intervals are explicit" do
    p = proposal(%{"timezone" => "UTC", "ends_local" => "2009-10-25T10:00:01"})
    assert {:error, {:invalid, message}} = Recurrence.expand(p, count(2))
    assert message =~ "Window 2"
    assert message =~ "overlaps window 1"

    assert {:ok, %{"windows" => [first, second]}} =
             Recurrence.expand(%{p | "ends_local" => "2009-10-25T10:00"}, count(2))

    refute first["touches_previous"]
    assert second["touches_previous"]
    assert first["ends_at"] == second["starts_at"]
    assert {:ok, %{"windows" => [_, third]}} = Recurrence.expand(p, count(2, 2))
    refute third["touches_previous"]
  end

  test "local dates crossing supported years fail without leaking arithmetic exceptions" do
    p =
      proposal(%{
        "timezone" => "UTC",
        "starts_local" => "9999-12-25T10:00",
        "ends_local" => "9999-12-25T11:00"
      })

    assert {:error, {:invalid, message}} = Recurrence.expand(p, count(2))
    assert message =~ "years 0001–9999"

    p =
      proposal(%{
        "timezone" => "Etc/GMT-14",
        "starts_local" => "0001-01-01T00:30",
        "ends_local" => "0001-01-01T01:30"
      })

    assert {:error, {:invalid, message}} = Recurrence.expand(p, count(2))
    assert message =~ "Window 1 start"
  end

  test "rule limits and mutually exclusive endings are enforced before expansion" do
    for rule <- [
          nil,
          [],
          %{"count" => true},
          count(1),
          count(53),
          count(2, 0),
          count(2, 13),
          count(2, 1.0),
          %{"count" => "2"},
          %{"frequency" => "daily", "count" => 2},
          %{"count" => 2, "until_date" => "2009-10-25"},
          %{"end_mode" => "date", "count" => 2, "until_date" => "2009-10-25"},
          %{"end_mode" => "date", "until_date" => "2009-02-30"},
          %{"count" => 2, "skip_dates" => []}
        ] do
      assert {:error, {:invalid, _}} = Recurrence.expand(proposal(), rule)
    end

    assert {:ok, %{"windows" => windows}} = Recurrence.expand(proposal(), count(52, 12))
    assert length(windows) == 52
  end

  test "malformed first windows and invalid policies reject with bounded messages" do
    for change <- [
          %{"start_mode" => "now"},
          %{"starts_local" => nil},
          %{"starts_local" => %{}},
          %{"starts_local" => "2009-10-18T10:00:00+02:00"},
          %{"starts_local" => "0000-01-01T00:00"},
          %{"ends_local" => "2009-10-18T09:00"},
          %{"ends_local" => String.duplicate("x", 1000)},
          %{"timezone" => "Mars/Olympus"},
          %{"timezone" => %{}},
          %{"start_fold" => "automatic"}
        ] do
      assert {:error, {:invalid, message}} = Recurrence.expand(proposal(change), count(2))
      assert byte_size(message) < 500
    end

    assert {:error, {:invalid, _}} = Recurrence.expand(nil, count(2))
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceTimeTest do
  use ExUnit.Case, async: true
  alias Mondek.MaintenanceTime

  test "civil dates resolve through pinned zone rules, including non-hour offsets" do
    assert {:ok, ~U[2009-09-20 08:00:00Z]} =
             MaintenanceTime.resolve("2009-09-20T10:00", "Europe/Berlin")

    assert {:ok, ~U[2009-12-20 09:00:00Z]} =
             MaintenanceTime.resolve("2009-12-20T10:00:00", "Europe/Berlin")

    assert {:ok, ~U[2009-09-20 04:15:00Z]} =
             MaintenanceTime.resolve("2009-09-20T10:00:00", "Asia/Kathmandu")

    assert {:ok, ~U[2009-09-20 10:00:00Z]} =
             MaintenanceTime.resolve("2009-09-20T10:00:00", "UTC")
  end

  test "repeated hours require explicit independent occurrence choices" do
    assert {:error, {:invalid, message}} =
             MaintenanceTime.resolve("2009-10-25T02:30", "Europe/Berlin")

    assert message =~ "occurs twice"

    assert {:ok, ~U[2009-10-25 00:30:00Z]} =
             MaintenanceTime.resolve("2009-10-25T02:30", "Europe/Berlin", "earlier")

    assert {:ok, ~U[2009-10-25 01:30:00Z]} =
             MaintenanceTime.resolve("2009-10-25T02:30", "Europe/Berlin", "later")

    assert [%{"value" => "earlier"}, %{"value" => "later"}] =
             MaintenanceTime.choices("2009-10-25T02:30", "Europe/Berlin")
  end

  test "nonexistent times reject instead of advancing the operator's chosen clock time" do
    for fold <- ["reject", "earlier", "later"] do
      assert {:error, {:invalid, message}} =
               MaintenanceTime.resolve("2010-03-28T02:30", "Europe/Berlin", fold)

      assert message =~ "does not exist"
      assert message =~ "2010-03-28T03:00:00"
    end

    assert {:error, {:invalid, _}} =
             MaintenanceTime.resolve("2009-10-04T02:15", "Australia/Lord_Howe")
  end

  test "offset-bearing, malformed, oversized and invalid-zone input is rejected" do
    for local <- [
          nil,
          %{},
          "2009-09-20",
          "2009-09-20T10:00:00Z",
          "2009-09-20T10:00:00+02:00",
          "2009-02-30T10:00",
          "0000-01-01T00:00",
          "10000-01-01T00:00",
          String.duplicate("x", 1000)
        ] do
      assert {:error, {:invalid, _}} = MaintenanceTime.resolve(local, "UTC")
    end

    for zone <- [nil, %{}, "Mars/Olympus", String.duplicate("x", 101)] do
      assert {:error, {:invalid, _}} = MaintenanceTime.resolve("2009-09-20T10:00", zone)
    end
  end

  test "saved UTC instants round trip into the original zone without losing microseconds" do
    instant = ~U[2009-10-25 01:30:00.123456Z]
    local = MaintenanceTime.local(instant, "Europe/Berlin")
    assert local == "2009-10-25T02:30:00.123456"
    assert {:ok, ^instant} = MaintenanceTime.resolve(local, "Europe/Berlin", "later")
    assert MaintenanceTime.fold(instant, "Europe/Berlin") == "later"
    assert MaintenanceTime.fold(DateTime.add(instant, -3600), "Europe/Berlin") == "earlier"
    assert MaintenanceTime.fold(instant, "UTC") == "reject"
    assert MaintenanceTime.version() =~ ~r/^\d{4}[a-z]+$/
  end

  test "timezone offsets must not push the saved instant outside supported UTC years" do
    assert {:error, {:invalid, _}} =
             MaintenanceTime.resolve("9999-12-31T23:30", "Etc/GMT+12")

    assert {:error, {:invalid, _}} =
             MaintenanceTime.resolve("0001-01-01T00:30", "Etc/GMT-14")
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.RefreshRateTest do
  use Mondek.DataCase, async: false
  alias MondekWeb.ConfigurationLive

  test "broadcast bursts wait for the controlled tick while local saves refresh immediately" do
    # Exercise the real callbacks without a connected socket's wall-clock timer.
    # This makes the flood boundary deterministic instead of racing a one-second sleep.
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, live_action: :configuration_detail}
    }

    {:ok, socket} = ConfigurationLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      ConfigurationLive.handle_params(
        %{"id" => "10000000-0000-4000-8000-000000000001"},
        "http://localhost/configuration/10000000-0000-4000-8000-000000000001",
        socket
      )

    reviewed = socket.assigns.check_inspection["assignment"]

    assert {:ok, changed} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000001",
               reviewed["revision"],
               %{
                 "path" => "/",
                 "warn_percent" => 70,
                 "crit_percent" => 90
               }
             )

    owner = self()
    handler = "refresh-rate-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:mondek, :repo, :query],
        fn _, _, _, _ -> send(owner, :inspection_query) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for _ <- 1..500 do
      assert {:noreply, ^socket} = ConfigurationLive.handle_info(:changed, socket)
    end

    assert queries() == 0
    assert socket.assigns.check_inspection["assignment"]["revision"] == reviewed["revision"]

    {:noreply, refreshed} = ConfigurationLive.handle_info(:tick, socket)
    assert queries() > 0
    assert refreshed.assigns.check_inspection["assignment"]["revision"] == changed["revision"]
    assert refreshed.assigns.drafts == socket.assigns.drafts

    for _ <- 1..500 do
      assert {:noreply, ^refreshed} = ConfigurationLive.handle_info(:changed, refreshed)
    end

    assert queries() == 0

    {:noreply, saved} =
      ConfigurationLive.handle_event(
        "save",
        %{
          "_id" => "10000000-0000-4000-8000-000000000001",
          "_revision" => to_string(changed["revision"]),
          "params" => %{"path" => "/", "warn_percent" => "65", "crit_percent" => "90"}
        },
        refreshed
      )

    assert queries() > 0
    {:noreply, saved} = ConfigurationLive.handle_event("confirm_instance_save", %{}, saved)
    assert saved.assigns.check_inspection["assignment"]["params"]["warn_percent"] == 65
    assert saved.assigns.feedback["10000000-0000-4000-8000-000000000001"] =~ "saved"
  end

  defp queries(count \\ 0) do
    receive do
      :inspection_query -> queries(count + 1)
    after
      0 -> count
    end
  end
end

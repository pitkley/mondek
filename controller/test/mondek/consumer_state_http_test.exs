# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConsumerStateHTTPTest do
  use Mondek.DataCase, async: false
  @moduletag timeout: 120_000

  test "real runner workers share state, handle a lost committed reply and recover from outage" do
    pid = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    python = System.get_env("MONDEK_STATE_TEST_PYTHON", Path.expand("../runner/.venv/bin/python"))
    script = Path.expand("../tests/e2e/consumer_state_http.py")

    {output, code} =
      System.cmd(python, [script, "http://127.0.0.1:#{port}"],
        env: [{"PYTHONPATH", nil}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "Two real runners shared state"
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Retention do
  @moduledoc "Effective startup-configured history eligibility; references remain protected."
  def policy do
    Application.get_env(:mondek, :retention, %{
      receipt_days: 7,
      history_days: 30,
      max_observations: 100_000
    })
  end

  def summary do
    policy = policy()

    "Ordinary measurements expire after #{policy.receipt_days} days or beyond the newest #{policy.max_observations} receipts. Completed history retains #{policy.history_days} days. Current state, unresolved incidents and retained delivery/evidence references are protected and may exceed these limits. Count trimming can retain less time than the age limit; these are eligibility limits, not a guaranteed retention duration or storage cap. Changes take effect after controller restart."
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.TestWebhook do
  import Plug.Conn
  import Ecto.Query
  def init(options), do: options

  def call(conn, options) do
    {:ok, body, conn} = read_body(conn)
    payload = Jason.decode!(body)
    # Inspect the committed database from a distinct HTTP server process.
    attempt_exists? =
      Mondek.Repo.exists?(
        from a in Mondek.Attempt,
          where: a.occurrence_id == ^payload["occurrence_id"] and a.status == "started"
      )

    send(options[:owner], {:webhook, payload, attempt_exists?})

    status =
      if options[:controlled] do
        send(options[:owner], {:webhook_waiting, self()})

        receive do
          {:respond, status} -> status
        after
          2000 -> 500
        end
      else
        options[:status]
      end

    send_resp(conn, status, "recorded")
  end
end

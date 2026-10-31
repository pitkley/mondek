# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
Application.ensure_all_started(:postgrex)
ExUnit.start()

defmodule Mondek.PostgresTLSProfile do
  use ExUnit.Case, async: false

  defp connect(mode, host \\ "localhost", database \\ "mondek") do
    System.delete_env("DATABASE_URL")
    if mode, do: System.put_env("PGSSLMODE", mode), else: System.delete_env("PGSSLMODE")
    System.put_env("PGHOST", host)

    if mode in ["verify-ca", "verify-full"],
      do: System.put_env("PGSSLROOTCERT", System.fetch_env!("MONDEK_TLS_TEST_CA")),
      else: System.delete_env("PGSSLROOTCERT")

    options =
      Config.Reader.read!("config/runtime.exs", env: :test)[:mondek][Mondek.Repo]
      |> Keyword.merge(database: database, pool_size: 1, backoff_type: :stop, sync_connect: true)

    Postgrex.start_link(options)
  end

  defp rejected(mode, host \\ "localhost") do
    result =
      try do
        case connect(mode, host) do
          {:ok, connection} ->
            result = Postgrex.query(connection, "SELECT 1", [], timeout: 2000)
            if Process.alive?(connection), do: GenServer.stop(connection)
            result

          error ->
            error
        end
      catch
        :exit, reason -> {:error, reason}
      end

    assert {:error, _} = result
  end

  test "hostssl accepts encrypted connections and enforces verification policy" do
    for mode <- [nil, "disable"] do
      {:ok, connection} = connect(mode, "localhost", "plain")

      assert %{rows: [[false]]} =
               Postgrex.query!(
                 connection,
                 "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
                 []
               )

      GenServer.stop(connection)
    end

    for mode <- ["require", "verify-ca", "verify-full"] do
      {:ok, connection} = connect(mode)

      assert %{rows: [[true]]} =
               Postgrex.query!(
                 connection,
                 "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()",
                 []
               )

      GenServer.stop(connection)
    end

    # Failed synchronous connections may exit their caller as well as returning errors.
    Process.flag(:trap_exit, true)
    rejected("disable")
    rejected("verify-full", "127.0.0.1")
    {:ok, connection} = connect("verify-ca", "127.0.0.1")
    GenServer.stop(connection)

    System.put_env("MONDEK_TLS_TEST_CA", System.fetch_env!("MONDEK_TLS_TEST_UNTRUSTED_CA"))
    rejected("verify-full")
  end
end

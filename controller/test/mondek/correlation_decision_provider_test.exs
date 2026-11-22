# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationDecisionProviderTest do
  use ExUnit.Case, async: false

  alias Mondek.CorrelationDecisionProvider, as: Provider

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "provider.json")

    for {setting, value} <- [
          correlation_decisions_config: path,
          correlation_decisions_loopback: true
        ] do
      previous = Application.fetch_env(:mondek, setting)
      Application.put_env(:mondek, setting, value)

      on_exit(fn ->
        case previous do
          {:ok, old} -> Application.put_env(:mondek, setting, old)
          :error -> Application.delete_env(:mondek, setting)
        end
      end)
    end

    raw = %{
      "id" => "decision-test",
      "url" => "https://example.invalid/advice",
      "binding_key" => String.duplicate("k", 32),
      "evidence" => ["health", "dimensions"]
    }

    File.write!(path, Jason.encode!(raw))
    File.chmod!(path, 0o600)
    %{path: path, raw: raw}
  end

  @moduletag :tmp_dir
  test "rereads private file, binds adapter, credentials and authorized disclosure", %{
    path: path,
    raw: raw
  } do
    {:ok, config} = Provider.configuration()
    assert config.evidence == ["dimensions", "health"]
    fingerprint = Provider.fingerprint(config)

    for {field, value} <- [
          {"id", "another"},
          {"url", "https://example.invalid/b"},
          {"evidence", []},
          {"binding_key", String.duplicate("z", 32)},
          {"bearer_token", "test"},
          {"timeout_ms", 1000}
        ] do
      File.write!(path, Jason.encode!(Map.put(raw, field, value)))
      assert {:ok, changed} = Provider.configuration()
      refute fingerprint == Provider.fingerprint(changed)
    end

    for {key, bad} <- [
          {"url", "http://external.invalid"},
          {"url", "https://user@unknown.invalid"},
          {"evidence", ["raw"]},
          {"binding_key", "short"},
          {"bearer_token", "bad\r\nheader"}
        ] do
      File.write!(path, Jason.encode!(Map.put(raw, key, bad)))
      assert Provider.configuration() == {:error, :unavailable}
    end

    File.write!(path, Jason.encode!(raw))
    File.chmod!(path, 0o644)
    assert Provider.configuration() == {:error, :unavailable}
  end

  test "sends exact bytes and returns bounded JSON from the configured loopback endpoint", ctx do
    {result, request} =
      exchange(
        ctx,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nVary: Accept\r\nVary: Origin\r\nContent-Length: 2\r\n\r\n{}"
      )

    assert result == {:ok, "{}"}
    assert request =~ "POST /advice?q=test HTTP/1.1\r\n"
    assert request =~ "Idempotency-Key: request-42\r\n"
    assert request =~ "Authorization: Bearer fixture-token\r\n"
    assert String.ends_with?(request, "\r\n\r\n{\"v\":1}")
  end

  test "rejects redirects, ambiguous framing and hostile sizes without retrying", ctx do
    for response <- [
          "HTTP/1.1 302 Found\r\nLocation: https://example.invalid\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8193\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",
          "HTTP/1.1 200 OK\r\nX-Fill: " <> String.duplicate("a", 18_000) <> "\r\n\r\n",
          "HTTP/1.1 200 OK\r\nX-A: " <>
            String.duplicate("a", 9000) <>
            "\r\nX-B: " <> String.duplicate("b", 9000) <> "\r\n\r\n"
        ] do
      assert {{:error, :invalid}, _request} = exchange(ctx, response)
    end

    assert {:ok, config} = Provider.configuration()
    assert Provider.post(config, "id", String.duplicate("x", 32_769), 100) == {:error, :invalid}
  end

  test "temporary failures and incomplete bodies can be retried", ctx do
    for response <- [
          "HTTP/1.1 429 Busy\r\n\r\n",
          "HTTP/1.1 503 Busy\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{"
        ] do
      assert {{:error, :retryable}, _request} = exchange(ctx, response)
    end
  end

  test "the original deadline covers a response that keeps the connection open", ctx do
    response = fn socket ->
      :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
      # The client must close while the server is still waiting to finish its headers.
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1000)
    end

    assert {{:error, :retryable}, _request} = exchange(ctx, response, 150)
  end

  test "HTTPS verifies a loopback TLS endpoint against the installed trust store", %{
    tmp_dir: dir,
    path: path,
    raw: raw
  } do
    key = Path.join(dir, "test.key")
    cert = Path.join(dir, "test.pem")

    ca = Path.join(dir, "authority.pem")
    ca_key = Path.join(dir, "authority.key")
    csr = Path.join(dir, "server.csr")
    extensions = Path.join(dir, "extensions")
    File.write!(extensions, "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n")

    openssl([
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=test authority",
      "-keyout",
      ca_key,
      "-out",
      ca,
      "-days",
      "1",
      "-addext",
      "basicConstraints=critical,CA:TRUE"
    ])

    openssl([
      "req",
      "-new",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-subj",
      "/CN=localhost",
      "-keyout",
      key,
      "-out",
      csr
    ])

    openssl([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      ca,
      "-CAkey",
      ca_key,
      "-CAcreateserial",
      "-out",
      cert,
      "-days",
      "1",
      "-extfile",
      extensions
    ])

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        certfile: String.to_charlist(cert),
        keyfile: String.to_charlist(key)
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    on_exit(fn -> :ssl.close(listener) end)
    File.write!(path, Jason.encode!(Map.put(raw, "url", "https://localhost:#{port}/advice")))
    {:ok, config} = Provider.configuration()

    server = fn ->
      {:ok, tcp} = :ssl.transport_accept(listener, 3000)

      case :ssl.handshake(tcp, 3000) do
        {:ok, socket} ->
          {:ok, _request} = :ssl.recv(socket, 0, 2000)

          :ok =
            :ssl.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
            )

          :ssl.close(socket)

        {:error, _tls_alert} ->
          :rejected
      end
    end

    untrusted = Task.async(server)
    assert Provider.post(config, "request-42", "{}", 2000) == {:error, :retryable}
    assert Task.await(untrusted) == :rejected
    :public_key.cacerts_clear()
    :ok = :public_key.cacerts_load(String.to_charlist(ca))

    on_exit(fn ->
      :public_key.cacerts_clear()
      :public_key.cacerts_load()
    end)

    trusted = Task.async(server)
    assert Provider.post(config, "request-42", "{}", 2000) == {:ok, "{}"}
    Task.await(trusted)
  end

  defp openssl(args) do
    {_, 0} = System.cmd("openssl", args, stderr_to_stdout: true)
  end

  defp exchange(%{raw: raw, path: path}, response, remaining_ms \\ 2000) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, packet: :raw])

    {:ok, port} = :inet.port(listener)
    url = "http://127.0.0.1:#{port}/advice?q=test"

    File.write!(
      path,
      Jason.encode!(Map.merge(raw, %{"url" => url, "bearer_token" => "fixture-token"}))
    )

    {:ok, config} = Provider.configuration()

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        request = read_request(socket, "")

        if is_function(response),
          do: response.(socket),
          else: :ok = :gen_tcp.send(socket, response)

        :gen_tcp.close(socket)
        request
      end)

    try do
      {Provider.post(config, "request-42", ~s({"v":1}), remaining_ms), Task.await(task)}
    after
      :gen_tcp.close(listener)
    end
  end

  defp read_request(socket, bytes) do
    if String.ends_with?(bytes, ~s({"v":1})) do
      bytes
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 2000)
      read_request(socket, bytes <> more)
    end
  end
end

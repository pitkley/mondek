# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.WebhookHTTP do
  @moduledoc "Single HTTP/1.1 POST with bounded response headers; response bodies are never collected."
  @header_limit 16_384

  def post(destination, id, body) do
    uri = URI.parse(destination.url)
    transport = if uri.scheme == "https", do: :ssl, else: :gen_tcp
    options = [mode: :binary, active: false, packet: :raw, buffer: @header_limit]

    options =
      if transport == :ssl, do: options ++ tls_options(destination, uri.host), else: options

    case transport.connect(
           String.to_charlist(uri.host),
           uri.port,
           options,
           destination.timeout_ms
         ) do
      {:ok, socket} ->
        try do
          path =
            if(uri.path in [nil, ""], do: "/", else: uri.path) <>
              if(uri.query, do: "?" <> uri.query, else: "")

          host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host

          headers =
            [
              {"Host", "#{host}:#{uri.port}"},
              {"Connection", "close"},
              {"Content-Type", "application/json"},
              {"Content-Length", Integer.to_string(byte_size(body))},
              {"X-Mondek-Occurrence", id}
            ] ++ Map.to_list(destination.headers)

          request = [
            "POST ",
            path,
            " HTTP/1.1\r\n",
            Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end),
            "\r\n",
            body
          ]

          :ok = transport.send(socket, request)
          read_headers(transport, socket, "", destination.timeout_ms, 0, 0)
        after
          transport.close(socket)
        end

      _ ->
        {:error, :webhook_transport_failed}
    end
  catch
    _, _ -> {:error, :webhook_transport_failed}
  end

  defp tls_options(destination, host) do
    trust =
      if destination.cacertfile,
        do: [cacertfile: String.to_charlist(destination.cacertfile)],
        else: [cacerts: :public_key.cacerts_get()]

    trust ++
      [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
  end

  defp read_headers(transport, socket, bytes, timeout, consumed, interim) do
    case :binary.split(bytes, "\r\n\r\n") do
      [header, rest] ->
        if consumed + byte_size(header) + 4 > @header_limit or interim > 5, do: throw(:limit)
        [status | lines] = String.split(header, "\r\n")
        [_, code] = Regex.run(~r/\AHTTP\/1\.[01] ([1-5][0-9][0-9])(?: |$)/, status)
        code = String.to_integer(code)

        if code in 100..199 and code != 101 do
          read_headers(
            transport,
            socket,
            rest,
            timeout,
            consumed + byte_size(header) + 4,
            interim + 1
          )
        else
          headers =
            Enum.map(lines, fn line ->
              [key, value] = String.split(line, ":", parts: 2)
              {String.downcase(key), String.trim(value)}
            end)

          {:ok, code, headers}
        end

      [_] ->
        if consumed + byte_size(bytes) > @header_limit, do: throw(:limit)

        case transport.recv(socket, 0, timeout) do
          {:ok, chunk} ->
            read_headers(transport, socket, bytes <> chunk, timeout, consumed, interim)

          _ ->
            {:error, :webhook_transport_failed}
        end
    end
  end
end

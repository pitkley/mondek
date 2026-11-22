# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationDecisionHTTP do
  @moduledoc false
  @header_limit 16_384
  @body_limit 8192

  def post(uri, token, id, body, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    transport = if uri.scheme == "https", do: :ssl, else: :gen_tcp

    options = [
      mode: :binary,
      active: false,
      packet: :line,
      packet_size: @header_limit,
      send_timeout: timeout,
      send_timeout_close: true
    ]

    options = if transport == :ssl, do: tls_options(uri.host) ++ options, else: options

    case transport.connect(String.to_charlist(uri.host), uri.port, options, left(deadline)) do
      {:ok, socket} ->
        try do
          set_options(transport, socket, send_timeout: left(deadline))
          :ok = transport.send(socket, request(uri, token, id, body))
          {status_line, budget} = read_line(transport, socket, deadline, @header_limit)

          case Regex.run(~r/\AHTTP\/1\.[01] ([1-5][0-9]{2})(?: [^\r\n]*)?\z/, status_line) do
            [_, "200"] -> read_response(transport, socket, deadline, budget)
            [_, code] when code in ["408", "425", "429"] -> {:error, :retryable}
            [_, "5" <> _] -> {:error, :retryable}
            _ -> {:error, :invalid}
          end
        after
          transport.close(socket)
        end

      _ ->
        {:error, :retryable}
    end
  catch
    :throw, :invalid -> {:error, :invalid}
    _, _ -> {:error, :retryable}
  end

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp request(uri, token, id, body) do
    host = if String.contains?(uri.host, ":"), do: ["[", uri.host, "]"], else: uri.host
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    [
      "POST ",
      path,
      if(uri.query, do: ["?", uri.query], else: []),
      " HTTP/1.1\r\nHost: ",
      host,
      ":",
      Integer.to_string(uri.port),
      "\r\nConnection: close\r\n",
      "Accept: application/json\r\nContent-Type: application/json\r\nIdempotency-Key: ",
      id,
      "\r\n",
      if(token, do: ["Authorization: Bearer ", token, "\r\n"], else: []),
      "Content-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n\r\n",
      body
    ]
  end

  defp read_response(transport, socket, deadline, budget) do
    headers = headers(transport, socket, deadline, budget, %{})
    size = Map.get(headers, "content-length", "")

    type =
      Map.get(headers, "content-type", "")
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    unless Regex.match?(~r/\A[0-9]{1,4}\z/, size) and type == "application/json" and
             not Map.has_key?(headers, "transfer-encoding") and
             Map.get(headers, "content-encoding", "identity") == "identity",
           do: throw(:invalid)

    size = String.to_integer(size)
    unless size in 1..@body_limit, do: throw(:invalid)
    set_options(transport, socket, packet: :raw)

    case transport.recv(socket, size, left(deadline)) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> {:error, :retryable}
    end
  end

  defp headers(transport, socket, deadline, budget, acc) do
    case read_line(transport, socket, deadline, budget) do
      {"", _} ->
        acc

      {line, budget} ->
        case Regex.run(
               ~r/\A([A-Za-z0-9!#$%&'*+.^_`|~-]+):[ \t]*([^\x00-\x08\x0a-\x1f\x7f]*)\z/,
               line
             ) do
          [_, name, value] ->
            key = String.downcase(name)

            acc =
              if key in ~w(content-type content-length content-encoding transfer-encoding) do
                if Map.has_key?(acc, key), do: throw(:invalid)
                Map.put(acc, key, String.trim(value))
              else
                acc
              end

            headers(transport, socket, deadline, budget, acc)

          _ ->
            throw(:invalid)
        end
    end
  end

  defp read_line(transport, socket, deadline, budget) do
    case transport.recv(socket, 0, left(deadline)) do
      {:ok, line} when byte_size(line) <= budget ->
        size = byte_size(line) - 2

        case line do
          <<value::binary-size(^size), "\r\n">> -> {value, budget - byte_size(line)}
          _ -> throw(:invalid)
        end

      {:error, :emsgsize} ->
        throw(:invalid)

      {:ok, _} ->
        throw(:invalid)

      _ ->
        throw(:retryable)
    end
  end

  defp set_options(:ssl, socket, opts), do: :ok = :ssl.setopts(socket, opts)
  defp set_options(:gen_tcp, socket, opts), do: :ok = :inet.setopts(socket, opts)

  defp left(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> throw(:retryable)
    end
  end
end

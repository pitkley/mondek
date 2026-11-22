# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationDecisionProvider do
  @moduledoc "Deployment-configured advisory JSON provider. Configuration is reread on every lookup."

  @max_config 16_384
  @test_build Mix.env() == :test

  def configuration do
    path = Application.get_env(:mondek, :correlation_decisions_config)

    with true <- is_binary(path),
         {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, config} <- File.open(path, [:read, :raw, :binary], &read_config/1) do
      config
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_config(file) do
    {:ok, info} = :file.read_file_info(file)
    %{type: :regular, mode: mode, size: size} = File.Stat.from_record(info)
    true = Bitwise.band(mode, 0o077) == 0 and size <= @max_config
    {:ok, bytes} = :file.read(file, @max_config + 1)
    true = byte_size(bytes) <= @max_config
    raw = Jason.decode!(bytes)

    true =
      Enum.all?(Map.keys(raw), &(&1 in ~w(id url evidence binding_key bearer_token timeout_ms)))

    %{"id" => id, "url" => url, "binding_key" => key, "evidence" => evidence} = raw
    true = Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, id)
    true = Regex.match?(~r/\A[!-~]{32,1024}\z/, key)
    token = Map.get(raw, "bearer_token")
    true = is_nil(token) or Regex.match?(~r/\A[!-~]{1,2048}\z/, token)
    true = byte_size(url) <= 2048 and Regex.match?(~r/\A[!-~]+\z/, url)
    uri = URI.new!(url)
    true = is_binary(uri.host) and uri.host != "" and uri.port in 1..65_535
    true = is_nil(uri.userinfo) and is_nil(uri.fragment)
    true = uri.scheme == "https" or loopback_fixture?(uri)
    true = is_list(evidence) and Enum.all?(evidence, &(&1 in ~w(dimensions timing health)))
    true = Enum.uniq(evidence) == evidence
    timeout = Map.get(raw, "timeout_ms", 5000)
    true = is_integer(timeout) and timeout in 1..30_000

    {:ok,
     %{
       id: id,
       url: url,
       binding_key: key,
       evidence: Enum.sort(evidence),
       bearer_token: token,
       timeout_ms: timeout
     }}
  end

  defp loopback_fixture?(uri) do
    @test_build and Application.get_env(:mondek, :correlation_decisions_loopback, false) and
      uri.scheme == "http" and uri.host == "127.0.0.1"
  end

  def fingerprint(config) do
    fields = [
      "mondek/advisory-json/v1",
      config.id,
      config.url,
      config.evidence,
      config.bearer_token,
      config.timeout_ms
    ]

    :crypto.mac(:hmac, :sha256, config.binding_key, Jason.encode!(fields))
    |> Base.encode16(case: :lower)
  end

  def post(config, id, body, remaining_ms)
      when is_binary(id) and is_binary(body) and byte_size(body) <= 32_768 and
             is_integer(remaining_ms) and remaining_ms > 0 do
    uri = URI.new!(config.url)

    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id) and
         (uri.scheme == "https" or loopback_fixture?(uri)) do
      Mondek.CorrelationDecisionHTTP.post(
        uri,
        config.bearer_token,
        id,
        body,
        min(config.timeout_ms, remaining_ms)
      )
    else
      {:error, :invalid}
    end
  end

  def post(_, _, _, _), do: {:error, :invalid}
end

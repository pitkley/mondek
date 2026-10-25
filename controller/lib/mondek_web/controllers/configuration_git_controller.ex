# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationGitController do
  use MondekWeb, :controller
  alias Mondek.{ConfigurationGit, ConfigurationRepository}
  @limit 8_388_608

  plug :authenticate
  plug :no_cache

  def info(conn, %{"service" => service})
      when service in ["git-upload-pack", "git-receive-pack"] do
    with {:ok, %{head: head}} <- ConfigurationRepository.state(),
         {:ok, data} <-
           ConfigurationGit.advertise(ConfigurationRepository.objects(), head, service) do
      reply(conn, "application/x-#{service}-advertisement", data)
    else
      {:error, reason} when is_binary(reason) -> send_resp(conn, 503, reason)
      _ -> send_resp(conn, 503, "Configuration repository unavailable")
    end
  end

  def info(conn, _), do: send_resp(conn, 400, "Unsupported Git service")

  def upload(conn, _), do: rpc(conn, "git-upload-pack")
  def receive_pack(conn, _), do: rpc(conn, "git-receive-pack")

  defp rpc(conn, service) do
    expected = "application/x-#{service}-request"

    if get_req_header(conn, "content-type") == [expected] and
         get_req_header(conn, "content-encoding") in [[], ["identity"]] do
      case read_body(conn, length: @limit, read_length: 65_536, read_timeout: 15_000) do
        {:ok, body, conn} when byte_size(body) <= @limit -> execute(conn, service, body)
        {:more, _, conn} -> send_resp(conn, 413, "Git request exceeds limit")
        {:error, _} -> send_resp(conn, 400, "Could not read Git request")
        _ -> send_resp(conn, 413, "Git request exceeds limit")
      end
    else
      send_resp(conn, 415, "Use the matching Git request content type without content encoding")
    end
  end

  defp execute(conn, service, body) do
    with {:ok, %{head: head}} <- ConfigurationRepository.state() do
      objects = ConfigurationRepository.objects()

      case service do
        "git-upload-pack" ->
          case ConfigurationGit.upload(objects, head, body) do
            {:ok, response} -> reply(conn, "application/x-git-upload-pack-result", response)
            {:error, reason} -> send_resp(conn, 400, rejection_reason(reason))
          end

        "git-receive-pack" ->
          result =
            with {:ok, candidate} <- ConfigurationGit.receive(objects, head, body),
                 {:ok, _} <- ConfigurationRepository.accept_push(head, candidate),
                 do: {:ok, candidate.response}

          response =
            case result do
              {:ok, response} -> response
              {:error, reason} -> ConfigurationGit.rejection(body, rejection_reason(reason))
            end

          reply(conn, "application/x-git-receive-pack-result", response)
      end
    else
      _ -> send_resp(conn, 503, "Configuration repository unavailable")
    end
  end

  defp rejection_reason({:invalid, reason}) when is_binary(reason), do: reason
  defp rejection_reason(reason) when is_binary(reason), do: reason
  defp rejection_reason(%{message: message}) when is_binary(message), do: message

  defp rejection_reason(_),
    do:
      "Configuration rejected; fetch current configuration and review the supported format and parameter contracts"

  defp authenticate(conn, _) do
    token = Application.get_env(:mondek, :configuration_git_token)

    if is_binary(token) and byte_size(token) >= 32 do
      case Plug.BasicAuth.parse_basic_auth(conn) do
        {"mondek", password} ->
          if Plug.Crypto.secure_compare(token, password), do: conn, else: unauthorized(conn)

        _ ->
          unauthorized(conn)
      end
    else
      conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header(
      "www-authenticate",
      ~s(Basic realm="Mondek configuration", charset="UTF-8")
    )
    |> send_resp(401, "Git credentials required")
    |> halt()
  end

  defp no_cache(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

  defp reply(conn, type, body), do: conn |> put_resp_content_type(type) |> send_resp(200, body)
end

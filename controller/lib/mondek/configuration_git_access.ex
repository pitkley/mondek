# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationGitAccess do
  @moduledoc false

  @max_token_bytes 4096

  def token do
    case Application.get_env(:mondek, :configuration_git_token_file) do
      nil -> static_token()
      path when is_binary(path) -> file_token(path)
      _ -> :unavailable
    end
  end

  def status do
    case token() do
      {:ok, _token} -> :available
      status -> status
    end
  end

  def valid_token?(expected, provided) when is_binary(expected) and is_binary(provided),
    do: Plug.Crypto.secure_compare(expected, provided)

  def valid_token?(_, _), do: false

  defp static_token do
    case Application.get_env(:mondek, :configuration_git_token) do
      token when is_binary(token) and byte_size(token) >= 32 -> {:ok, token}
      _ -> :disabled
    end
  end

  defp file_token(path) do
    # Reject nonregular paths before opening and check the descriptor again
    # because an atomic replacement may occur between these operations.
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, result} <- File.open(path, [:read, :binary, :raw], &read_token/1) do
      result
    else
      _ -> :unavailable
    end
  end

  defp read_token(file) do
    # Allow one optional LF or CRLF beyond the credential itself.
    limit = @max_token_bytes + 2

    with {:ok, info} <- :file.read_file_info(file),
         %File.Stat{type: :regular, mode: mode, size: size} <- File.Stat.from_record(info),
         true <- Bitwise.band(mode, 0o077) == 0 and size <= limit,
         {:ok, bytes} <- :file.read(file, limit + 1),
         [token] <- Regex.run(~r/\A([\x21-\x7e]+)(?:\r?\n)?\z/, bytes, capture: :all_but_first),
         true <- byte_size(token) in 32..@max_token_bytes do
      {:ok, token}
    else
      _ -> :unavailable
    end
  end
end

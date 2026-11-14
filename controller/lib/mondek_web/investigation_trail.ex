# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationTrail do
  @moduledoc "Typed, bounded entity navigation inside a LiveView-owned investigation."
  @kinds ~w(result health loss)
  @limit 6
  @bytes 8192

  def identity({kind, id}) when kind in @kinds do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {kind, id}
      _ -> nil
    end
  end

  def identity(_), do: nil
  def token({kind, id}), do: kind <> ":" <> id

  def from_token(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [kind, id] -> identity({kind, id})
      _ -> nil
    end
  end

  def from_token(_), do: nil

  def parse(nil), do: {:ok, []}
  def parse(""), do: {:ok, []}

  def parse(value) when is_binary(value) and byte_size(value) <= @bytes do
    entries = String.split(value, ",")

    identities =
      Enum.map(entries, fn entry ->
        case String.split(entry, ":", parts: 2) do
          [kind, id] -> identity({kind, id})
          _ -> nil
        end
      end)

    if length(identities) <= @limit && Enum.all?(identities) &&
         length(Enum.uniq(identities)) == length(identities), do: {:ok, identities}, else: :error
  end

  def parse(_), do: :error

  def resolve(params, initial \\ []) do
    case Map.fetch(params, "inspect") do
      {:ok, value} ->
        case parse(value) do
          {:ok, trail} -> trail
          :error -> []
        end

      :error ->
        Enum.filter(initial, &identity/1)
    end
  end

  def open(trail, identity, root \\ nil) do
    cond do
      is_nil(identity(identity)) -> {:error, :invalid}
      identity == root -> {:ok, []}
      identity in trail -> {:ok, Enum.take(trail, Enum.find_index(trail, &(&1 == identity)) + 1)}
      length(trail) + if(root, do: 1, else: 0) >= @limit -> {:error, :limit}
      true -> {:ok, trail ++ [identity]}
    end
  end

  def path(host, trail, changes \\ %{}) do
    uri = URI.parse(host)

    if is_nil(uri.scheme) && is_nil(uri.host) && is_binary(uri.path) &&
         String.starts_with?(uri.path, "/") && !String.starts_with?(uri.path, "//") do
      params = URI.decode_query(uri.query || "")

      params =
        params |> Map.merge(changes) |> Map.put("inspect", Enum.map_join(trail, ",", &token/1))

      params =
        Map.reject(params, fn {key, value} ->
          is_nil(value) ||
            (key in ~w(member_page healthy_page notification_page) && value in [1, "1"])
        end)

      uri.path <> "?" <> URI.encode_query(Enum.sort(params))
    else
      "/next"
    end
  end

  def selection(params, initial \\ []) do
    selected = params |> resolve(initial) |> Enum.map_join(",", &token/1)

    page =
      case from_token(params["page_entity"]) do
        nil -> ""
        identity -> token(identity)
      end

    selected <> if(params["surface"] == "page", do: "|page:" <> page, else: "")
  end

  def heading(params, fallback) do
    if params["surface"] == "page" do
      case from_token(params["page_entity"]) do
        {"result", _} -> "full-result-heading"
        _ -> "incident-heading"
      end
    else
      fallback
    end
  end

  def initial(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["next", kind, id] when kind in ~w(results checks) -> List.wrap(identity({"result", id}))
      ["next", "incidents", kind, id] -> List.wrap(identity({kind, id}))
      _ -> []
    end
  end

  def root(path) when is_binary(path) do
    if String.ends_with?(path, "/full"),
      do: path |> String.replace_suffix("/full", "") |> initial() |> List.first()
  end
end

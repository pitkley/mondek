# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationTrail do
  @moduledoc "Typed, bounded entity navigation inside a LiveView-owned investigation."
  @kinds ~w(result health loss runner notification execution)
  @limit 6
  @bytes 8192

  def identity({"coverage", id}) when is_binary(id) and byte_size(id) == 64 do
    if Regex.match?(~r/\A[a-f0-9]{64}\z/, id), do: {"coverage", id}
  end

  def identity({"diagnostic", id}) when is_integer(id),
    do: identity({"diagnostic", to_string(id)})

  def identity({"diagnostic", id}) when is_binary(id) and byte_size(id) <= 19 do
    case Integer.parse(id) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 ->
        {"diagnostic", Integer.to_string(number)}

      _ ->
        nil
    end
  end

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
            (key in ~w(relationships_page member_page healthy_page notification_page) &&
               value in [1, "1"])
        end)

      uri.path <> "?" <> URI.encode_query(Enum.sort(params))
    else
      "/"
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

  def promoted(params, initial \\ []) do
    identity = from_token(params["page_entity"])

    if params["surface"] == "page" && identity && identity in resolve(params, initial),
      do: identity
  end

  def heading(params, fallback, initial \\ []) do
    case promoted(params, initial) do
      {"result", _} -> "full-result-heading"
      {"runner", _} -> "runner-heading"
      {"notification", _} -> "notification-heading"
      {"execution", _} -> "execution-heading"
      {kind, _} when kind in ~w(coverage diagnostic) -> "coverage-page-heading"
      {kind, _} when kind in ~w(health loss) -> "incident-heading"
      _ -> fallback
    end
  end

  def initial(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [kind, id] when kind in ~w(results checks) ->
        List.wrap(identity({"result", id}))

      ["incidents", kind, id] ->
        List.wrap(identity({kind, id}))

      ["coverage", "diagnostics", id] ->
        List.wrap(identity({"diagnostic", id}))

      [kind, id] when kind in ~w(coverage expected) ->
        List.wrap(identity({"coverage", id}))

      ["runners", id] ->
        List.wrap(identity({"runner", id}))

      ["notifications", id] ->
        List.wrap(identity({"notification", id}))

      ["executions", id] ->
        List.wrap(identity({"execution", id}))

      _ ->
        []
    end
  end

  def root(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/executions/") ->
        path |> initial() |> List.first()

      String.ends_with?(path, "/full") ->
        path |> String.replace_suffix("/full", "") |> initial() |> List.first()

      true ->
        nil
    end
  end
end

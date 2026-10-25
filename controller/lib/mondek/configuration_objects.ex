# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationObjects do
  @moduledoc "Pure Git object construction: safe inside the configuration transaction."

  def oid(kind, body),
    do: :crypto.hash(:sha, "#{kind} #{byte_size(body)}\0" <> body) |> Base.encode16(case: :lower)

  def commit(files, parent, message, at) do
    {tree, objects} =
      tree(Enum.map(files, fn {path, body} -> {String.split(path, "/"), body} end))

    parent_line = if parent, do: "parent #{parent}\n", else: ""
    identity = "Mondek <configuration@mondek.invalid> #{DateTime.to_unix(at)} +0000"

    body =
      "tree #{tree}\n" <>
        parent_line <> "author #{identity}\ncommitter #{identity}\n\n#{message}\n"

    head = oid("commit", body)
    {head, Map.put(objects, head, {"commit", body})}
  end

  def json(value),
    do:
      value
      |> encode()
      |> IO.iodata_to_binary()
      |> Jason.Formatter.pretty_print()
      |> Kernel.<>("\n")

  defp encode(value) when is_map(value),
    do: [
      "{",
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", encode(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp encode(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &encode/1), ","), "]"]

  defp encode(value), do: Jason.encode!(value)

  defp tree(entries) do
    {items, objects} =
      entries
      |> Enum.group_by(fn {[name | _], _} -> name end)
      |> Enum.reduce({[], %{}}, fn {name, group}, {items, objects} ->
        {mode, child, new} =
          case group do
            [{[_], body}] ->
              child = oid("blob", body)
              {"100644", child, %{child => {"blob", body}}}

            _ ->
              {child, new} = tree(Enum.map(group, fn {[_ | rest], body} -> {rest, body} end))
              {"40000", child, new}
          end

        {[{name, mode, child} | items], Map.merge(objects, new)}
      end)

    body =
      items
      |> Enum.sort_by(fn {name, mode, _} -> name <> if(mode == "40000", do: "/", else: "") end)
      |> Enum.map(fn {name, mode, child} ->
        [mode, " ", name, <<0>>, Base.decode16!(child, case: :lower)]
      end)
      |> IO.iodata_to_binary()

    id = oid("tree", body)
    {id, Map.put(objects, id, {"tree", body})}
  end
end

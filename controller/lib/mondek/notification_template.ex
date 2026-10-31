# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationTemplate do
  @moduledoc "Bounded JSON templates; data references never execute code or become JSON syntax."
  @limit 262_144

  def load!(path) do
    with {:ok, %{size: size, type: :regular}} when size <= 65_536 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, template} <- Jason.decode(bytes) do
      template
    else
      _ -> raise ArgumentError, "Invalid notification template file"
    end
  end

  def render!(template, document) do
    {value, _} = node(template, document, 0, 10_000)
    bytes = Jason.encode!(value)
    if byte_size(bytes) > @limit, do: invalid!()
    bytes
  rescue
    _ -> raise ArgumentError, "Invalid notification template or rendered body exceeds limits"
  end

  defp node(_, _, depth, budget) when depth > 20 or budget <= 0, do: invalid!()

  defp node(%{"$ref" => path} = value, context, _, budget) when map_size(value) == 1 do
    result = lookup!(context, path)
    if byte_size(Jason.encode!(result)) > @limit, do: invalid!()
    {result, budget - cost(result)}
  end

  defp node(%{"$concat" => parts} = value, context, depth, budget)
       when map_size(value) == 1 and is_list(parts) do
    {parts, budget} = children(parts, context, depth, budget - 1)
    unless Enum.all?(parts, &is_binary/1), do: invalid!()
    result = Enum.join(parts)
    if byte_size(result) > @limit, do: invalid!()
    {result, budget}
  end

  defp node(%{"$if" => path, "then" => yes, "else" => no} = value, context, depth, budget)
       when map_size(value) == 3 do
    branch = if lookup!(context, path) in [nil, false, "", []], do: no, else: yes
    node(branch, context, depth + 1, budget - 1)
  end

  defp node(%{"$each" => path, "template" => template} = value, context, depth, budget)
       when map_size(value) == 2 do
    items = lookup!(context, path)
    unless is_list(items) and length(items) <= 100, do: invalid!()

    Enum.map_reduce(items, budget - 1, fn item, remaining ->
      node(template, Map.put(context, "item", item), depth + 1, remaining)
    end)
  end

  defp node(value, context, depth, budget) when is_map(value) do
    if Enum.any?(["$ref", "$concat", "$if", "$each"], &Map.has_key?(value, &1)), do: invalid!()

    Enum.reduce(value, {%{}, budget - 1}, fn {key, child}, {result, remaining} ->
      {rendered, remaining} = node(child, context, depth + 1, remaining)
      {Map.put(result, key, rendered), remaining}
    end)
  end

  defp node(value, context, depth, budget) when is_list(value),
    do: children(value, context, depth, budget - 1)

  defp node(value, _, _, budget), do: {value, budget - cost(value)}

  defp children(values, context, depth, budget),
    do: Enum.map_reduce(values, budget, &node(&1, context, depth + 1, &2))

  defp cost(value), do: 1 + div(byte_size(Jason.encode!(value)), 64)

  defp lookup!(context, path) when is_binary(path) do
    Enum.reduce(String.split(path, "."), context, fn key, value ->
      case value do
        %{} -> Map.fetch!(value, key)
        _ -> invalid!()
      end
    end)
  end

  defp lookup!(_, _), do: invalid!()
  defp invalid!, do: raise(ArgumentError, "Invalid notification template")
end

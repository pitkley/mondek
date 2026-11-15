# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.JSON do
  @moduledoc "HTTP envelopes; operation projections are assembled by their domain adapter."
  def normalize(%DateTime{} = value), do: Mondek.Monitoring.iso(value)
  def normalize(%_{} = value), do: value |> Mondek.Monitoring.public() |> normalize()

  def normalize(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), normalize(v)} end)

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value), do: value
  def project(nil, _, _), do: nil

  def project(value, %OpenApiSpex.Reference{"$ref": ref}, definitions) do
    name = String.replace_prefix(ref, "#/components/schemas/", "")

    value =
      if name == "Incident" and is_map(value),
        do: Mondek.Investigation.health_summary(value),
        else: value

    project(value, definitions[name], definitions)
  end

  def project(value, %OpenApiSpex.Schema{allOf: [schema]}, definitions),
    do: project(value, schema, definitions)

  def project(value, %OpenApiSpex.Schema{type: :array, items: schema}, definitions)
      when is_list(value), do: Enum.map(value, &project(&1, schema, definitions))

  def project(
        value,
        %OpenApiSpex.Schema{type: :object, properties: properties, additionalProperties: false},
        definitions
      )
      when is_map(value) and is_map(properties) do
    Map.new(properties, fn {key, schema} -> {to_string(key), schema} end)
    |> Enum.flat_map(fn {key, schema} ->
      if Map.has_key?(value, key), do: [{key, project(value[key], schema, definitions)}], else: []
    end)
    |> Map.new()
  end

  def project(value, _, _), do: value

  def envelope(value, at) do
    value = normalize(value)
    meta = %{"as_of" => Mondek.Monitoring.iso(at)}

    if is_map(value) and is_list(value["items"]) do
      pagination = Map.take(value, ~w(total page page_size next_page))

      pagination =
        if pagination["page"] && pagination["page_size"] && pagination["total"],
          do:
            Map.put(
              pagination,
              "next_page",
              if(pagination["page"] * pagination["page_size"] < pagination["total"],
                do: pagination["page"] + 1
              )
            ),
          else: pagination

      %{
        data: value["items"],
        meta: Map.merge(meta, Map.merge(Map.delete(value, "items"), pagination))
      }
    else
      %{data: value, meta: meta}
    end
  end
end

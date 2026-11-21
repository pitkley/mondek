# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.RunnerSchemas do
  @moduledoc "Producer declarations and received runner assignments, distinct from read projections."
  alias OpenApiSpex.Schema
  alias MondekWeb.API.Schemas, as: S

  def definitions do
    output = %Schema{
      type: :object,
      required: [:key, :label, :target],
      properties: %{
        key: text(200),
        label: text(200),
        target: S.ref("Target"),
        condition:
          S.nullable(
            S.record(%{key: text(128), label: text(200), namespace: text(128)}, [:key, :label])
          ),
        group: S.nullable(S.record(%{key: text(128), label: text(200)}, [:key, :label]))
      },
      additionalProperties: true
    }

    check = %Schema{
      type: :object,
      required: [
        :key,
        :label,
        :definition_revision,
        :params_owner,
        :parameter_schema,
        :params,
        :interval_seconds,
        :timeout_seconds,
        :freshness_seconds,
        :outputs
      ],
      properties: %{
        key: text(200),
        label: text(200),
        definition_revision: text(64),
        environment: S.nullable(text(128)),
        environment_label: S.nullable(text(200)),
        params_owner: S.enum(~w(source ui)),
        parameter_schema: S.ref("ParameterSchema"),
        parameter_contract: text(128),
        params: S.ref("ParameterValues"),
        interval_seconds: %Schema{type: :number, minimum: 0.1, maximum: 86400},
        timeout_seconds: %Schema{type: :number, minimum: 0.1, maximum: 300},
        freshness_seconds: %Schema{
          type: :number,
          minimum: 0.1,
          maximum: Mondek.Protocol.max_freshness_seconds()
        },
        outputs: %Schema{type: :array, minItems: 1, maxItems: 16, items: S.ref("InventoryOutput")}
      },
      additionalProperties: true
    }

    assignment = %Schema{
      type: :object,
      required: [
        :id,
        :kind,
        :generation,
        :params,
        :interval_seconds,
        :timeout_seconds,
        :freshness_seconds,
        :expected_keys
      ],
      properties:
        Map.merge(Map.delete(check.properties, :key), %{
          id: S.uuid(),
          kind: S.string(),
          generation: %Schema{type: :integer, minimum: 1, maximum: 2_147_483_647},
          source_id: S.nullable(text(200)),
          source_key: S.nullable(text(200)),
          source_revision: S.nullable(text(64)),
          expected_keys: %Schema{type: :array, maxItems: 16, uniqueItems: true, items: text(200)}
        }),
      additionalProperties: false
    }

    %{
      "InventoryOutput" => output,
      "InventoryCheck" => check,
      "RunnerAssignment" => assignment,
      "DeferredOutputOwner" =>
        S.record(%{check_key: text(200), output_key: text(200)}, [:check_key, :output_key]),
      "CanonicalResult" => %Schema{
        type: :object,
        required: [:key, :health, :summary],
        properties: %{
          key: text(200),
          health: S.enum(~w(OK WARN CRIT UNKNOWN)),
          summary: text(2048),
          details: S.nullable(text(16384)),
          value: S.nullable(S.number()),
          source_at: S.time(),
          deferral: S.ref("DeferredOutputOwner"),
          impacts: %Schema{
            type: :array,
            maxItems: 16,
            items: S.record(%{key: text(128), label: text(200)}, [:key, :label])
          },
          discovery: S.object()
        },
        additionalProperties: true,
        description:
          "Canonical producer result. Environment overrides are forbidden by admission. Text limits are UTF-8 bytes; unknown extension fields retain their existing semantics."
      },
      "CoverageCatalogue" => %Schema{
        type: :object,
        required: [:version, :code_revision, :runtime_revision, :runner_context, :candidates],
        properties: %{
          version: %Schema{type: :integer, enum: [1]},
          code_revision: text(64),
          runtime_revision: text(64),
          runner_context: S.object(),
          candidates: %Schema{type: :array, maxItems: 512, items: S.object()}
        },
        additionalProperties: true,
        description:
          "Complete pre-selection intent. Context validates candidate selection and scoped metadata against executable checks."
      }
    }
  end

  defp text(maximum),
    do: %Schema{
      type: :string,
      minLength: 1,
      maxLength: maximum,
      description: "UTF-8 byte budget also enforced by domain validation."
    }
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.ConsumerStateSchemas do
  alias OpenApiSpex.Schema
  alias MondekWeb.API.Schemas, as: S

  def definitions do
    metadata =
      S.record(
        %{
          id: S.uuid(),
          source_id: S.string(),
          scope: S.string(),
          key: S.string(),
          version: S.uuid(),
          bytes: S.integer(),
          updated_at: S.time(),
          expires_at: S.time(),
          installation_id: S.uuid(),
          session_id: S.uuid(),
          assignment_id: S.string(),
          generation: S.integer()
        },
        ~w(id source_id scope key version bytes updated_at expires_at installation_id session_id assignment_id generation)a
      )

    entry = %{
      metadata
      | properties: Map.put(metadata.properties, :value, %Schema{nullable: true}),
        required: metadata.required ++ [:value]
    }

    %{
      "ConsumerStateMetadata" => metadata,
      "ConsumerStateEntry" => entry,
      "ConsumerStateReceipt" =>
        S.record(
          %{
            version: %Schema{type: :integer, enum: [1]},
            status: S.enum(~w(found missing stored deleted conflict)),
            observed_at: S.time(),
            entry: S.nullable(S.ref("ConsumerStateEntry"))
          },
          [:version, :status]
        ),
      "ConsumerStateRequest" =>
        S.record(
          %{
            version: %Schema{type: :integer, enum: [1]},
            operation: S.enum(~w(get put compare_and_set delete)),
            installation_id: S.uuid(),
            session_id: S.uuid(),
            boot: S.integer(),
            assignment_id: S.uuid(),
            generation: S.integer(),
            source_id: S.string(),
            scope: S.enum(~w(source check)),
            key: S.string(),
            value: %Schema{nullable: true},
            expected_version: S.string(),
            ttl_seconds: %Schema{type: :integer, minimum: 1, maximum: 2_592_000}
          },
          ~w(version operation installation_id session_id boot assignment_id generation source_id scope key)a
        )
    }
  end
end

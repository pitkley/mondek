# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.SchemaMigrationSchemas do
  @moduledoc false
  alias MondekWeb.API.Schemas, as: S
  alias OpenApiSpex.Schema

  def response do
    S.record(
      %{
        source_id: S.string(),
        installation_id: S.uuid(),
        accepted:
          S.record(%{
            publication_id: S.integer(),
            inventory_revision: S.integer(),
            source_revision: S.string(),
            lifecycle_revision: S.integer()
          }),
        candidate:
          S.record(%{
            inventory_revision: S.integer(),
            source_revision: S.string(),
            digest: S.string(),
            publication_status:
              S.enum(
                ~w(candidate accepted_replay inventory_conflict stale_inventory publisher_retired publication_refresh_required)
              )
          }),
        review_digest: S.string(),
        check_count: S.integer(),
        rule_match_count: S.integer(),
        page: S.integer(),
        page_size: S.integer(),
        total: S.integer(),
        rows: S.array(%Schema{oneOf: [check_row(), rule_row()]})
      },
      ~w(source_id installation_id accepted candidate review_digest check_count rule_match_count page page_size total rows)a
    )
  end

  defp check_row do
    S.record(
      %{
        kind: S.enum(["check"]),
        check_key: S.string(),
        change: S.enum(~w(added withdrawn updated)),
        accepted: S.nullable(configuration()),
        candidate: S.nullable(configuration()),
        fields:
          S.array(
            S.record(%{
              field: S.string(),
              change: S.enum(~w(added withdrawn updated)),
              attributes: S.array(S.string()),
              type_before: S.nullable(S.string()),
              type_after: S.nullable(S.string()),
              unit_before: S.nullable(S.string()),
              unit_after: S.nullable(S.string())
            })
          ),
        comparisons_changed: S.boolean(),
        defaults_changed_fields: S.array(S.string()),
        saved_default_findings: S.nullable(findings()),
        instance_exception:
          S.nullable(
            S.record(%{
              saved_fields: S.array(S.string()),
              findings: S.nullable(findings())
            })
          ),
        blockers: S.array(S.string()),
        rule_resolution:
          S.nullable(
            S.record(%{
              origin: S.object(),
              diagnostic: S.string(),
              rule_ids: S.array(S.uuid())
            })
          )
      },
      ~w(kind check_key change accepted candidate fields comparisons_changed defaults_changed_fields saved_default_findings instance_exception blockers rule_resolution)a
    )
  end

  defp rule_row do
    S.record(
      %{
        kind: S.enum(["rule"]),
        check_key: S.string(),
        assignment_id: S.nullable(S.string()),
        rule_id: S.uuid(),
        rule_revision: S.integer(),
        rule_name: S.string(),
        enabled: S.boolean(),
        priority: S.integer(),
        scope_before: S.enum(~w(none partial full)),
        scope_after: S.enum(~w(none partial full)),
        captured_schema_fingerprint: S.string(),
        candidate_schema_changed: S.boolean(),
        rule_value_findings: S.nullable(findings()),
        other_matching_assignments: S.integer(),
        other_publisher_count: S.integer(),
        other_publisher_sample: S.array(S.uuid())
      },
      ~w(kind check_key assignment_id rule_id rule_revision rule_name enabled priority scope_before scope_after captured_schema_fingerprint candidate_schema_changed rule_value_findings other_matching_assignments other_publisher_count other_publisher_sample)a
    )
  end

  defp configuration do
    S.record(%{
      assignment_id: S.nullable(S.string()),
      installation_id: S.nullable(S.uuid()),
      revision: S.nullable(S.integer()),
      desired_generation: S.nullable(S.integer()),
      definition_revision: S.string(),
      schema_fingerprint: S.string(),
      params_owner: S.enum(~w(ui source)),
      parameter_contract: S.nullable(S.string()),
      environment: S.nullable(S.string())
    })
  end

  defp findings do
    S.record(%{
      missing_fields: S.array(S.string()),
      removed_fields: S.array(S.string()),
      invalid_fields: S.array(S.string()),
      failed_comparisons:
        S.array(S.record(%{left: S.string(), right: S.string(), op: S.enum(~w(lt lte))})),
      valid: S.boolean()
    })
  end
end

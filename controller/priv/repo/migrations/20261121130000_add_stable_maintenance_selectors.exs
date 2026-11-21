# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.Repo.Migrations.AddStableMaintenanceSelectors do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION public.maintenance_selections_valid(items jsonb[]) RETURNS boolean
        LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
        AS $$
    DECLARE item jsonb;
    BEGIN
      IF cardinality(items) NOT BETWEEN 1 AND 512 OR array_ndims(items) <> 1
        OR cardinality(items) <> (SELECT count(DISTINCT value) FROM unnest(items) value)
      THEN RETURN false; END IF;
      FOREACH item IN ARRAY items LOOP
        IF item IS NULL OR jsonb_typeof(item) <> 'object'
          OR NOT (item ?& ARRAY['scope','assignment_id','source_id','environment','target_kind','target_key'])
          OR item - ARRAY['scope','assignment_id','source_id','environment','target_kind','target_key']
              - (CASE WHEN item->>'scope'='stable_check' THEN 'source_key' ELSE 'scope' END) <> '{}'::jsonb
        THEN RETURN false; END IF;
        IF NOT COALESCE(
          (item->>'scope'='check' AND jsonb_typeof(item->'assignment_id')='string'
            AND octet_length(item->>'assignment_id') BETWEEN 1 AND 200
            AND btrim(item->>'assignment_id') <> ''
            AND item->'source_id'='null'::jsonb AND item->'environment'='null'::jsonb
            AND item->'target_kind'='null'::jsonb AND item->'target_key'='null'::jsonb)
          OR (item->>'scope'='target' AND item->'assignment_id'='null'::jsonb
            AND jsonb_typeof(item->'source_id')='string' AND octet_length(item->>'source_id') BETWEEN 1 AND 200
            AND btrim(item->>'source_id') <> ''
            AND jsonb_typeof(item->'target_kind')='string' AND octet_length(item->>'target_kind') BETWEEN 1 AND 64
            AND btrim(item->>'target_kind') <> ''
            AND jsonb_typeof(item->'target_key')='string' AND octet_length(item->>'target_key') BETWEEN 1 AND 200
            AND btrim(item->>'target_key') <> ''
            AND (item->'environment'='null'::jsonb OR (jsonb_typeof(item->'environment')='string'
              AND octet_length(item->>'environment') BETWEEN 1 AND 128 AND btrim(item->>'environment') <> '')))
          OR (item->>'scope'='stable_check' AND item->'assignment_id'='null'::jsonb
            AND jsonb_typeof(item->'source_id')='string' AND octet_length(item->>'source_id') BETWEEN 1 AND 200
            AND btrim(item->>'source_id') <> ''
            AND jsonb_typeof(item->'source_key')='string' AND octet_length(item->>'source_key') BETWEEN 1 AND 200
            AND btrim(item->>'source_key') <> ''
            AND (item->'environment'='null'::jsonb OR (jsonb_typeof(item->'environment')='string'
              AND octet_length(item->>'environment') BETWEEN 1 AND 128 AND btrim(item->>'environment') <> ''))
            AND ((item->'target_kind'='null'::jsonb AND item->'target_key'='null'::jsonb)
              OR (jsonb_typeof(item->'target_kind')='string' AND octet_length(item->>'target_kind') BETWEEN 1 AND 64
                AND btrim(item->>'target_kind') <> ''
                AND jsonb_typeof(item->'target_key')='string' AND octet_length(item->>'target_key') BETWEEN 1 AND 200
                AND btrim(item->>'target_key') <> ''))), false)
        THEN RETURN false; END IF;
      END LOOP;
      RETURN true;
    END $$;
    """)

    execute("""
    CREATE FUNCTION public.maintenance_selections_match(
      items jsonb[], check_id text, source text, source_key text, env text, kind text, target text
    ) RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT public.maintenance_selections_match(items, check_id, source, env, kind, target)
        OR (source IS NOT NULL AND source_key IS NOT NULL AND items && ARRAY[
          jsonb_build_object('scope','stable_check','assignment_id',NULL,'source_id',source,
            'source_key',source_key,'environment',env,'target_kind',NULL,'target_key',NULL),
          jsonb_build_object('scope','stable_check','assignment_id',NULL,'source_id',source,
            'source_key',source_key,'environment',env,'target_kind',kind,'target_key',target)
        ])
    $$;
    """)

    execute("""
    CREATE FUNCTION public.maintenance_stable_selections_overlap(left_items jsonb[], right_items jsonb[])
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
      SELECT EXISTS (
        SELECT 1 FROM unnest(left_items) l JOIN unnest(right_items) r
          ON l->>'source_id'=r->>'source_id'
          AND (l->>'environment') IS NOT DISTINCT FROM (r->>'environment')
        WHERE (l->>'scope'='stable_check' OR r->>'scope'='stable_check')
          AND (l->>'scope' IN ('target','stable_check') AND r->>'scope' IN ('target','stable_check'))
          AND ((l->>'scope'='stable_check' AND r->>'scope'='stable_check'
                AND l->>'source_key'=r->>'source_key'
                AND (l->>'target_kind' IS NULL OR r->>'target_kind' IS NULL))
            OR (l->>'target_kind'=r->>'target_kind' AND l->>'target_key'=r->>'target_key'
                AND (l->>'scope'='target' OR r->>'scope'='target' OR l->>'source_key'=r->>'source_key')))
      )
    $$;
    """)

    execute("""
    UPDATE monitoring_gaps g
    SET details=jsonb_set(g.details, '{source_key}', to_jsonb(a.source_key))
    FROM assignments a
    WHERE a.id=g.details->>'assignment_id' AND a.source_id=g.details->>'source_id'
      AND a.source_key IS NOT NULL AND NOT g.details ? 'source_key'
    """)

    execute("""
    UPDATE monitoring_gaps g
    SET details=jsonb_set(g.details, '{source_key}', to_jsonb(d.source_key))
    FROM (
      SELECT scope_id, source_id, min(source_key) AS source_key
      FROM coverage_declarations
      WHERE scope_id IS NOT NULL
      GROUP BY scope_id, source_id
      HAVING count(DISTINCT source_key)=1
    ) d
    WHERE g.key=d.scope_id AND g.details->>'coverage_id'=d.scope_id
      AND g.scope_key='coverage:' || d.source_id AND g.details->>'source_id'=d.source_id
      AND NOT g.details ? 'source_key'
    """)
  end

  def down do
    raise "Stable maintenance selectors require this schema. Restore a pre-upgrade backup to roll back."
  end
end

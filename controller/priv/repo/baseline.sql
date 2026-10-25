-- Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
-- SPDX-License-Identifier: Apache-2.0
-- Current application schema. Statements are separated explicitly so function bodies
-- may contain semicolons. Oban owns its schema through Oban.Migration.

-- mondek:statement
CREATE FUNCTION public.maintenance_selections_match(items jsonb[], check_id text, source text, env text, kind text, target text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  SELECT items && ARRAY[
    jsonb_build_object('scope','check','assignment_id',check_id,'source_id',NULL,'environment',NULL,'target_kind',NULL,'target_key',NULL),
    jsonb_build_object('scope','target','assignment_id',NULL,'source_id',source,'environment',env,'target_kind',kind,'target_key',target)
  ]
$$;

-- mondek:statement
CREATE FUNCTION public.maintenance_selections_valid(items jsonb[]) RETURNS boolean
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
      OR item - ARRAY['scope','assignment_id','source_id','environment','target_kind','target_key'] <> '{}'::jsonb
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
          AND octet_length(item->>'environment') BETWEEN 1 AND 128 AND btrim(item->>'environment') <> ''))), false)
    THEN RETURN false; END IF;
  END LOOP;
  RETURN true;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_condition_fact() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE receipt occurrences;
BEGIN
  IF TG_OP='UPDATE' AND (NEW.condition_incident_id IS DISTINCT FROM OLD.condition_incident_id OR NEW.kind IS DISTINCT FROM OLD.kind OR NEW.key IS DISTINCT FROM OLD.key OR NEW.label IS DISTINCT FROM OLD.label OR NEW.opened_at IS DISTINCT FROM OLD.opened_at OR NEW.opening_observation_id IS DISTINCT FROM OLD.opening_observation_id OR NEW.opening_incident_id IS DISTINCT FROM OLD.opening_incident_id OR (OLD.ended_at IS NOT NULL AND (NEW.ended_at IS DISTINCT FROM OLD.ended_at OR NEW.end_reason IS DISTINCT FROM OLD.end_reason)) OR (OLD.covered_by_occurrence_id IS NOT NULL AND (NEW.covered_by_occurrence_id IS DISTINCT FROM OLD.covered_by_occurrence_id OR NEW.covered_at IS DISTINCT FROM OLD.covered_at))) THEN
    RAISE EXCEPTION 'condition fact identity, ended lifetimes and accepted coverage are immutable';
  END IF;
  IF NEW.covered_by_occurrence_id IS NOT NULL THEN
    SELECT * INTO receipt FROM occurrences WHERE id=NEW.covered_by_occurrence_id;
    IF receipt.covered_warn_fact_id IS DISTINCT FROM NEW.id OR NOT EXISTS (SELECT 1 FROM attempts WHERE occurrence_id=receipt.id AND status='accepted') THEN
      RAISE EXCEPTION 'accepted coverage must reference this exact warning lifetime';
    END IF;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM incidents WHERE id=NEW.opening_incident_id AND condition_incident_id=NEW.condition_incident_id) THEN
    RAISE EXCEPTION 'fact opening evidence must belong to this condition';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_condition_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.namespace IS DISTINCT FROM OLD.namespace OR NEW.key IS DISTINCT FROM OLD.key OR NEW.environment IS DISTINCT FROM OLD.environment OR NEW.opened_at IS DISTINCT FROM OLD.opened_at OR (OLD.status='closed' AND NEW IS DISTINCT FROM OLD) THEN
    RAISE EXCEPTION 'condition episode identity and closed history are immutable';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_contribution_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='UPDATE' AND (NEW.condition_incident_id IS DISTINCT FROM OLD.condition_incident_id OR NEW.opening_observation_id IS DISTINCT FROM OLD.opening_observation_id) THEN
    RAISE EXCEPTION 'contribution episode ownership and opening evidence are immutable';
  END IF;
  IF NEW.condition_incident_id IS NOT NULL AND (
    NOT EXISTS (SELECT 1 FROM observations WHERE id=NEW.opening_observation_id AND assignment_id=NEW.assignment_id AND generation=NEW.opening_generation)
    OR NOT EXISTS (SELECT 1 FROM observations WHERE id=NEW.latest_observation_id AND assignment_id=NEW.assignment_id)) THEN
    RAISE EXCEPTION 'contribution evidence must belong to its assignment and opening generation';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_monitoring_incident() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.scope_key IS DISTINCT FROM OLD.scope_key OR NEW.scope_kind IS DISTINCT FROM OLD.scope_kind OR NEW.runner_id IS DISTINCT FROM OLD.runner_id OR NEW.source_id IS DISTINCT FROM OLD.source_id OR NEW.opened_at IS DISTINCT FROM OLD.opened_at OR (OLD.status='closed' AND NEW IS DISTINCT FROM OLD) THEN
    RAISE EXCEPTION 'monitoring episode identity and closed history are immutable';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_monitoring_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.monitoring_incident_id IS DISTINCT FROM OLD.monitoring_incident_id THEN
    RAISE EXCEPTION 'monitoring notification ownership is immutable';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_occurrence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE fact condition_facts; covered condition_facts;
BEGIN
  IF TG_OP='UPDATE' AND (NEW.payload IS DISTINCT FROM OLD.payload OR NEW.destination IS DISTINCT FROM OLD.destination OR NEW.incident_id IS DISTINCT FROM OLD.incident_id OR NEW.kind IS DISTINCT FROM OLD.kind OR NEW.attention_revision IS DISTINCT FROM OLD.attention_revision OR NEW.condition_incident_id IS DISTINCT FROM OLD.condition_incident_id OR NEW.condition_fact_id IS DISTINCT FROM OLD.condition_fact_id OR NEW.covered_warn_fact_id IS DISTINCT FROM OLD.covered_warn_fact_id) THEN
    RAISE EXCEPTION 'notification occurrence identity and payload are immutable';
  END IF;
  IF NEW.covered_warn_fact_id IS NOT NULL THEN
    SELECT * INTO fact FROM condition_facts WHERE id=NEW.condition_fact_id;
    SELECT * INTO covered FROM condition_facts WHERE id=NEW.covered_warn_fact_id;
    IF fact.kind<>'severity' OR fact.key<>'CRIT' OR covered.kind<>'severity' OR covered.key<>'WARN' THEN
      RAISE EXCEPTION 'only a critical occurrence can cover its warning threshold lifetime';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_immutable_occurrence_evidence() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP='UPDATE' THEN RAISE EXCEPTION 'notification evidence is immutable'; END IF;
  IF NOT EXISTS (SELECT 1 FROM occurrences o JOIN incidents i ON i.condition_incident_id=o.condition_incident_id JOIN observations v ON v.assignment_id=i.assignment_id WHERE o.id=NEW.occurrence_id AND i.id=NEW.incident_id AND v.id=NEW.observation_id AND v.generation=NEW.generation AND i.result_key=NEW.result_key) THEN
    RAISE EXCEPTION 'notification evidence must belong to its condition contribution and generation';
  END IF;
  RETURN NEW;
END $$;

-- mondek:statement
CREATE FUNCTION public.mondek_impact_keys_valid(items text[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $_$
  SELECT items IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM unnest(items) k WHERE k IS NULL OR k !~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$')
    AND cardinality(items)=(SELECT count(DISTINCT k) FROM unnest(items) k)
$_$;

-- mondek:statement
CREATE FUNCTION public.mondek_impacts_valid(items jsonb[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $_$
  SELECT items IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM unnest(items) v WHERE NOT COALESCE(
      jsonb_typeof(v)='object' AND v ?& ARRAY['key','label']
      AND v - ARRAY['key','label']='{}'::jsonb
      AND jsonb_typeof(v->'key')='string'
      AND (v->>'key') ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'
      AND jsonb_typeof(v->'label')='string'
      AND octet_length(v->>'label') BETWEEN 1 AND 200
      AND btrim(v->>'label')<>'' AND (v->>'label') !~ ('[' || chr(1) || '-' || chr(31) || chr(127) || ']'), false)
  ) AND cardinality(items)=(SELECT count(DISTINCT v->>'key') FROM unnest(items) v)
$_$;

-- mondek:statement
CREATE TABLE public.assignments (
    id text NOT NULL,
    kind text NOT NULL,
    label text NOT NULL,
    runner_id uuid,
    revision integer DEFAULT 1 NOT NULL,
    desired_generation integer DEFAULT 1 NOT NULL,
    prepared_generation integer,
    authorized_generation integer,
    active_generation integer,
    observed_generation integer,
    params jsonb NOT NULL,
    interval_seconds double precision DEFAULT 3.0 NOT NULL,
    timeout_seconds double precision DEFAULT 2.0 NOT NULL,
    freshness_seconds double precision DEFAULT 12.0 NOT NULL,
    expected_keys text[] NOT NULL,
    last_sequence bigint DEFAULT 0 NOT NULL,
    current jsonb DEFAULT '{}'::jsonb NOT NULL,
    retired_at timestamp without time zone,
    retirement_reason text,
    source_id text,
    source_key text,
    source_revision text,
    definition_revision text,
    environment text,
    params_owner text DEFAULT 'ui'::text NOT NULL,
    parameter_schema jsonb DEFAULT '{}'::jsonb NOT NULL,
    outputs jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    environment_label text,
    parameter_contract text,
    parameter_schema_fingerprint text,
    source_defaults jsonb DEFAULT '{}'::jsonb NOT NULL,
    instance_exception jsonb,
    configuration_origin jsonb DEFAULT '{}'::jsonb NOT NULL,
    configuration_exception_key text,
    discovery jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT explicit_delegated_parameter_contract CHECK (((parameter_contract IS NULL) OR ((params_owner = 'ui'::text) AND (source_id IS NOT NULL) AND (parameter_contract ~ '^[A-Za-z0-9_.:/@-]{1,128}$'::text) AND (parameter_schema_fingerprint IS NOT NULL) AND (parameter_schema_fingerprint ~ '^[0-9a-f]{64}$'::text) AND COALESCE(((jsonb_typeof((parameter_schema -> 'fields'::text)) = 'object'::text) AND ((parameter_schema -> 'fields'::text) <> '{}'::jsonb)), false)))),
    CONSTRAINT parameter_owner CHECK ((params_owner = ANY (ARRAY['source'::text, 'ui'::text]))),
    CONSTRAINT positive_assignment_bounds CHECK (((revision > 0) AND (desired_generation > 0) AND (interval_seconds > (0)::double precision) AND (timeout_seconds > (0)::double precision) AND (freshness_seconds > (0)::double precision) AND (last_sequence >= 0))),
    CONSTRAINT retirement_has_reason CHECK ((((retired_at IS NULL) AND (retirement_reason IS NULL)) OR ((retired_at IS NOT NULL) AND (retirement_reason IS NOT NULL) AND ((length(btrim(retirement_reason)) >= 1) AND (length(btrim(retirement_reason)) <= 500)))))
);

-- mondek:statement
CREATE TABLE public.attempts (
    id uuid NOT NULL,
    occurrence_id uuid NOT NULL,
    status text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    finished_at timestamp without time zone,
    http_status integer,
    error text
);

-- mondek:statement
CREATE TABLE public.condition_facts (
    id uuid NOT NULL,
    condition_incident_id uuid NOT NULL,
    kind text NOT NULL,
    key text NOT NULL,
    label text NOT NULL,
    opened_at timestamp(6) without time zone NOT NULL,
    opening_observation_id uuid NOT NULL,
    opening_incident_id uuid NOT NULL,
    ended_at timestamp(6) without time zone,
    end_reason text,
    covered_by_occurrence_id uuid,
    covered_at timestamp(6) without time zone,
    CONSTRAINT condition_fact_coverage CHECK ((((covered_by_occurrence_id IS NULL) AND (covered_at IS NULL)) OR ((kind = 'severity'::text) AND (key = 'WARN'::text) AND (covered_by_occurrence_id IS NOT NULL) AND (covered_at IS NOT NULL) AND (covered_at >= opened_at)))),
    CONSTRAINT condition_fact_identity CHECK ((((kind = 'severity'::text) AND (key = ANY (ARRAY['WARN'::text, 'CRIT'::text]))) OR ((kind = 'impact'::text) AND (key ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'::text)))),
    CONSTRAINT condition_fact_lifetime CHECK ((((ended_at IS NULL) AND (end_reason IS NULL)) OR ((ended_at IS NOT NULL) AND (ended_at >= opened_at) AND (end_reason IS NOT NULL)))),
    CONSTRAINT condition_facts_kind_check CHECK ((kind = ANY (ARRAY['severity'::text, 'impact'::text]))),
    CONSTRAINT condition_facts_label_check CHECK ((((octet_length(label) >= 1) AND (octet_length(label) <= 200)) AND (btrim(label) <> ''::text) AND (label !~ ((((('['::text || chr(1)) || '-'::text) || chr(31)) || chr(127)) || ']'::text))))
);

-- mondek:statement
CREATE TABLE public.condition_incidents (
    id uuid NOT NULL,
    namespace text NOT NULL,
    key text NOT NULL,
    environment text,
    label text NOT NULL,
    health text NOT NULL,
    impacts jsonb[] DEFAULT '{}'::jsonb[] NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    opened_at timestamp(6) without time zone NOT NULL,
    closed_at timestamp(6) without time zone,
    closure_reason text,
    closure_reasons text[] DEFAULT '{}'::text[] NOT NULL,
    closing_observation_id uuid,
    attention_revision bigint DEFAULT 1 NOT NULL,
    support_fingerprint text,
    acknowledgement_mode text,
    acknowledgement_revision bigint DEFAULT 0 NOT NULL,
    acknowledgement_ceiling text,
    acknowledgement_impacts text[] DEFAULT '{}'::text[] NOT NULL,
    acknowledged_until timestamp(6) without time zone,
    acknowledged_by text,
    acknowledgement_note text,
    CONSTRAINT condition_acknowledgement_shape CHECK (COALESCE((((acknowledgement_mode IS NULL) AND (acknowledged_until IS NULL) AND (acknowledgement_ceiling IS NULL) AND (cardinality(acknowledgement_impacts) = 0)) OR ((status = 'open'::text) AND (acknowledgement_ceiling = ANY (ARRAY['WARN'::text, 'CRIT'::text])) AND (((acknowledgement_mode = 'until'::text) AND (acknowledged_until IS NOT NULL)) OR ((acknowledgement_mode = 'until_incident_ends'::text) AND (acknowledged_until IS NULL))))), false)),
    CONSTRAINT condition_incidents_acknowledgement_impacts_check CHECK (public.mondek_impact_keys_valid(acknowledgement_impacts)),
    CONSTRAINT condition_incidents_acknowledgement_revision_check CHECK ((acknowledgement_revision >= 0)),
    CONSTRAINT condition_incidents_attention_revision_check CHECK ((attention_revision > 0)),
    CONSTRAINT condition_incidents_health_check CHECK ((health = ANY (ARRAY['WARN'::text, 'CRIT'::text]))),
    CONSTRAINT condition_incidents_impacts_check CHECK (public.mondek_impacts_valid(impacts)),
    CONSTRAINT condition_incidents_key_check CHECK ((key ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'::text)),
    CONSTRAINT condition_incidents_label_check CHECK ((((octet_length(label) >= 1) AND (octet_length(label) <= 200)) AND (btrim(label) <> ''::text) AND (label !~ ((((('['::text || chr(1)) || '-'::text) || chr(31)) || chr(127)) || ']'::text)))),
    CONSTRAINT condition_incidents_namespace_check CHECK ((namespace ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'::text)),
    CONSTRAINT condition_incidents_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text]))),
    CONSTRAINT condition_lifecycle CHECK ((((status = 'open'::text) AND (closed_at IS NULL) AND (closure_reason IS NULL)) OR ((status = 'closed'::text) AND (closed_at IS NOT NULL) AND (closed_at >= opened_at) AND (closure_reason IS NOT NULL))))
);

-- mondek:statement
CREATE TABLE public.configuration_git_objects (
    oid text NOT NULL,
    kind text NOT NULL,
    body bytea NOT NULL
);

-- mondek:statement
CREATE TABLE public.configuration_policy_projects (
    id text NOT NULL,
    revision bigint DEFAULT 0 NOT NULL
);

-- mondek:statement
CREATE TABLE public.configuration_policy_receipts (
    id text NOT NULL,
    project text NOT NULL,
    project_revision bigint NOT NULL,
    manifest_hash text NOT NULL,
    response jsonb NOT NULL,
    applied_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE TABLE public.configuration_repository (
    id integer NOT NULL,
    installation_id uuid NOT NULL,
    head text
);

-- mondek:statement
CREATE TABLE public.configuration_revisions (
    id bigint NOT NULL,
    head text NOT NULL,
    parent text,
    channel text NOT NULL,
    message text NOT NULL,
    files jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE SEQUENCE public.configuration_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.configuration_revisions_id_seq OWNED BY public.configuration_revisions.id;

-- mondek:statement
CREATE TABLE public.configuration_rule_diagnostics (
    id bigint NOT NULL,
    source_id text NOT NULL,
    runner_id uuid NOT NULL,
    source_key text NOT NULL,
    source_revision text NOT NULL,
    inventory_revision bigint NOT NULL,
    rule_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    message text NOT NULL,
    recorded_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE SEQUENCE public.configuration_rule_diagnostics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.configuration_rule_diagnostics_id_seq OWNED BY public.configuration_rule_diagnostics.id;

-- mondek:statement
CREATE TABLE public.configuration_rules (
    id uuid NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    name text NOT NULL,
    source_id text NOT NULL,
    parameter_contract text NOT NULL,
    environment text,
    target_kind text,
    target_key text,
    priority integer DEFAULT 0 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    parameter_schema jsonb NOT NULL,
    params jsonb NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    managed_project text,
    managed_key text,
    repository_key text,
    CONSTRAINT configuration_rule_management CHECK (((managed_project IS NULL) = (managed_key IS NULL))),
    CONSTRAINT configuration_rule_priority CHECK (((priority >= '-10000'::integer) AND (priority <= 10000))),
    CONSTRAINT configuration_rule_revision CHECK ((revision > 0)),
    CONSTRAINT configuration_rule_target CHECK (((target_kind IS NULL) = (target_key IS NULL)))
);

-- mondek:statement
CREATE TABLE public.configurations (
    id bigint NOT NULL,
    assignment_id text NOT NULL,
    generation integer NOT NULL,
    params jsonb NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    definition jsonb DEFAULT '{}'::jsonb NOT NULL
);

-- mondek:statement
CREATE SEQUENCE public.configurations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.configurations_id_seq OWNED BY public.configurations.id;

-- mondek:statement
CREATE TABLE public.controls (
    id bigint NOT NULL,
    assignment_id text,
    incident_id uuid,
    kind text NOT NULL,
    actor text NOT NULL,
    reason text NOT NULL,
    until timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    occurrence_id uuid,
    stream_id uuid,
    acknowledgement_mode text,
    acknowledgement_revision bigint,
    acknowledgement_ceiling text,
    condition_incident_id uuid,
    acknowledgement_impacts text[] DEFAULT ARRAY[]::text[] NOT NULL,
    monitoring_incident_id uuid,
    CONSTRAINT control_condition_owner CHECK ((((monitoring_incident_id IS NULL) AND (public.mondek_impact_keys_valid(acknowledgement_impacts) AND (((assignment_id IS NOT NULL) AND (condition_incident_id IS NULL)) OR ((assignment_id IS NULL) AND (condition_incident_id IS NOT NULL) AND (incident_id IS NULL) AND (stream_id IS NULL))))) OR ((monitoring_incident_id IS NOT NULL) AND (assignment_id IS NULL) AND (incident_id IS NULL) AND (condition_incident_id IS NULL) AND (stream_id IS NULL) AND (cardinality(acknowledgement_impacts) = 0))))
);

-- mondek:statement
CREATE SEQUENCE public.controls_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.controls_id_seq OWNED BY public.controls.id;

-- mondek:statement
CREATE TABLE public.coverage_declarations (
    id bigint NOT NULL,
    source_inventory_id bigint NOT NULL,
    runner_id uuid NOT NULL,
    source_id text NOT NULL,
    source_key text NOT NULL,
    result_key text NOT NULL,
    scope_id text,
    environment text,
    environment_label text,
    target_kind text,
    target_key text,
    target_label text,
    check_label text NOT NULL,
    result_label text NOT NULL,
    selected boolean NOT NULL,
    exclusion_reason text,
    scope_resolved boolean NOT NULL,
    scope_reason text,
    definition_revision text NOT NULL,
    assignment_id text,
    check_group jsonb,
    CONSTRAINT coverage_declaration_shape CHECK ((((octet_length(source_id) >= 1) AND (octet_length(source_id) <= 200)) AND ((octet_length(source_key) >= 1) AND (octet_length(source_key) <= 200)) AND ((octet_length(result_key) >= 1) AND (octet_length(result_key) <= 200)) AND ((octet_length(check_label) >= 1) AND (octet_length(check_label) <= 200)) AND ((octet_length(result_label) >= 1) AND (octet_length(result_label) <= 200)) AND (definition_revision ~ '^[a-f0-9]{64}$'::text) AND ((environment IS NULL) OR ((octet_length(environment) >= 1) AND (octet_length(environment) <= 128))) AND ((environment_label IS NULL) OR ((octet_length(environment_label) >= 1) AND (octet_length(environment_label) <= 200))) AND (((target_key IS NULL) AND (target_kind IS NULL) AND (target_label IS NULL)) OR ((target_key IS NOT NULL) AND (target_kind IS NOT NULL) AND (target_label IS NOT NULL) AND ((octet_length(target_key) >= 1) AND (octet_length(target_key) <= 200)) AND ((octet_length(target_kind) >= 1) AND (octet_length(target_kind) <= 64)) AND ((octet_length(target_label) >= 1) AND (octet_length(target_label) <= 200)))) AND ((scope_resolved AND (scope_id ~ '^[a-f0-9]{64}$'::text) AND (target_key IS NOT NULL) AND (scope_reason IS NULL)) OR ((NOT scope_resolved) AND (scope_id IS NULL) AND (scope_reason IS NOT NULL) AND ((octet_length(scope_reason) >= 1) AND (octet_length(scope_reason) <= 200)))) AND ((selected AND scope_resolved AND (exclusion_reason IS NULL)) OR ((NOT selected) AND (exclusion_reason IS NOT NULL) AND ((octet_length(exclusion_reason) >= 1) AND (octet_length(exclusion_reason) <= 2048)) AND (assignment_id IS NULL))))),
    CONSTRAINT coverage_scope_presence CHECK ((scope_resolved = (scope_id IS NOT NULL)))
);

-- mondek:statement
CREATE SEQUENCE public.coverage_declarations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.coverage_declarations_id_seq OWNED BY public.coverage_declarations.id;

-- mondek:statement
CREATE TABLE public.discovery_changes (
    id uuid NOT NULL,
    assignment_id text NOT NULL,
    source_id text NOT NULL,
    scope text NOT NULL,
    params jsonb NOT NULL,
    members jsonb[] NOT NULL,
    resource jsonb DEFAULT '{}'::jsonb NOT NULL,
    pending boolean DEFAULT true NOT NULL,
    saved_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE TABLE public.incidents (
    id uuid NOT NULL,
    assignment_id text NOT NULL,
    health text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    opened_at timestamp without time zone NOT NULL,
    closed_at timestamp without time zone,
    closure_reason text,
    opening_generation integer NOT NULL,
    attention_revision integer DEFAULT 1 NOT NULL,
    acknowledged_until timestamp without time zone,
    acknowledgement_note text,
    acknowledged_by text,
    acknowledgement_ceiling text,
    closing_observation_id uuid,
    result_key text,
    stream_id uuid,
    environment text,
    environment_label text,
    acknowledgement_mode text,
    acknowledgement_revision bigint DEFAULT 0 NOT NULL,
    condition_incident_id uuid,
    opening_observation_id uuid,
    latest_observation_id uuid,
    impacts jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    acknowledgement_impacts text[] DEFAULT ARRAY[]::text[] NOT NULL,
    CONSTRAINT acknowledgement_mode_consistent CHECK (((acknowledgement_revision >= 0) AND COALESCE((((acknowledgement_mode IS NULL) AND (acknowledged_until IS NULL)) OR ((acknowledgement_mode = 'until'::text) AND (acknowledged_until IS NOT NULL) AND (status = 'open'::text)) OR ((acknowledgement_mode = 'until_incident_ends'::text) AND (acknowledged_until IS NULL) AND (status = 'open'::text))), false))),
    CONSTRAINT closing_evidence_requires_closed_incident CHECK (((closing_observation_id IS NULL) OR (status = 'closed'::text))),
    CONSTRAINT contribution_evidence_shape CHECK ((public.mondek_impacts_valid(impacts) AND (cardinality(impacts) <= 16) AND public.mondek_impact_keys_valid(acknowledgement_impacts) AND ((condition_incident_id IS NULL) OR ((opening_observation_id IS NOT NULL) AND (latest_observation_id IS NOT NULL) AND (stream_id IS NOT NULL)))))
);

-- mondek:statement
CREATE TABLE public.maintenance_events (
    id bigint NOT NULL,
    window_id uuid NOT NULL,
    revision bigint NOT NULL,
    kind text NOT NULL,
    actor text NOT NULL,
    reason text NOT NULL,
    snapshot jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE SEQUENCE public.maintenance_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.maintenance_events_id_seq OWNED BY public.maintenance_events.id;

-- mondek:statement
CREATE TABLE public.maintenance_series (
    id uuid NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    name text NOT NULL,
    reason text NOT NULL,
    actor text NOT NULL,
    proposal jsonb NOT NULL,
    resolved_windows jsonb[] NOT NULL,
    tzdata_version text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT maintenance_series_shape CHECK (((revision > 0) AND (jsonb_typeof(proposal) = 'object'::text) AND ((cardinality(resolved_windows) >= 2) AND (cardinality(resolved_windows) <= 52))))
);

-- mondek:statement
CREATE TABLE public.maintenance_series_events (
    id bigint NOT NULL,
    series_id uuid NOT NULL,
    revision bigint NOT NULL,
    kind text NOT NULL,
    actor text NOT NULL,
    reason text NOT NULL,
    snapshot jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);

-- mondek:statement
CREATE SEQUENCE public.maintenance_series_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.maintenance_series_events_id_seq OWNED BY public.maintenance_series_events.id;

-- mondek:statement
CREATE TABLE public.maintenance_windows (
    id uuid NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    name text NOT NULL,
    reason text NOT NULL,
    actor text NOT NULL,
    scope text NOT NULL,
    assignment_id text,
    source_id text,
    environment text,
    target_kind text,
    target_key text,
    timezone text DEFAULT 'Etc/UTC'::text NOT NULL,
    tzdata_version text,
    starts_local text,
    ends_local text,
    start_fold text DEFAULT 'reject'::text NOT NULL,
    end_fold text DEFAULT 'reject'::text NOT NULL,
    starts_at timestamp without time zone NOT NULL,
    ends_at timestamp without time zone NOT NULL,
    cancelled_at timestamp without time zone,
    cancelled_by text,
    cancellation_reason text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    selections jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    series_id uuid,
    series_index integer,
    CONSTRAINT maintenance_series_membership CHECK (COALESCE((((series_id IS NULL) AND (series_index IS NULL)) OR ((series_id IS NOT NULL) AND ((series_index >= 1) AND (series_index <= 52)))), false)),
    CONSTRAINT maintenance_window_shape CHECK (((revision > 0) AND (starts_at < ends_at) AND COALESCE((((scope = 'check'::text) AND (cardinality(selections) = 0) AND (assignment_id IS NOT NULL) AND (source_id IS NULL) AND (environment IS NULL) AND (target_kind IS NULL) AND (target_key IS NULL)) OR ((scope = 'target'::text) AND (cardinality(selections) = 0) AND (assignment_id IS NULL) AND (source_id IS NOT NULL) AND (target_kind IS NOT NULL) AND (target_key IS NOT NULL)) OR ((scope = 'selection'::text) AND (assignment_id IS NULL) AND (source_id IS NULL) AND (environment IS NULL) AND (target_kind IS NULL) AND (target_key IS NULL) AND public.maintenance_selections_valid(selections))), false)))
);

-- mondek:statement
CREATE TABLE public.monitoring_gaps (
    key text NOT NULL,
    identity uuid NOT NULL,
    scope_key text NOT NULL,
    details jsonb NOT NULL,
    since_at timestamp without time zone NOT NULL,
    ready_at timestamp without time zone NOT NULL,
    CONSTRAINT monitoring_gap_order CHECK ((ready_at >= since_at))
);

-- mondek:statement
CREATE TABLE public.monitoring_incidents (
    id uuid NOT NULL,
    scope_key text NOT NULL,
    scope_kind text NOT NULL,
    runner_id uuid,
    source_id text,
    label text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    opened_at timestamp without time zone NOT NULL,
    closed_at timestamp without time zone,
    closure_reason text,
    had_withdrawals boolean DEFAULT false NOT NULL,
    member_count integer NOT NULL,
    member_snapshot jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    closing_evidence jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attention_revision bigint DEFAULT 1 NOT NULL,
    acknowledgement_mode text,
    acknowledgement_revision bigint DEFAULT 0 NOT NULL,
    acknowledged_until timestamp without time zone,
    acknowledgement_note text,
    acknowledged_by text,
    CONSTRAINT monitoring_acknowledgement CHECK (COALESCE((((acknowledgement_mode IS NULL) AND (acknowledged_until IS NULL)) OR ((status = 'open'::text) AND (((acknowledgement_mode = 'until'::text) AND (acknowledged_until IS NOT NULL)) OR ((acknowledgement_mode = 'until_incident_ends'::text) AND (acknowledged_until IS NULL))))), false)),
    CONSTRAINT monitoring_lifecycle CHECK (((member_count > 0) AND (attention_revision > 0) AND (acknowledgement_revision >= 0) AND (((status = 'open'::text) AND (closed_at IS NULL) AND (closure_reason IS NULL)) OR ((status = 'closed'::text) AND (closed_at IS NOT NULL) AND (closure_reason IS NOT NULL) AND (closed_at >= opened_at) AND (closure_reason = ANY (ARRAY['monitoring_restored'::text, 'scope_withdrawn'::text])))))),
    CONSTRAINT monitoring_scope CHECK ((((scope_kind = 'runner'::text) AND (runner_id IS NOT NULL) AND (source_id IS NULL) AND (scope_key = ('runner:'::text || (runner_id)::text))) OR ((scope_kind = 'coverage'::text) AND (runner_id IS NULL) AND (source_id IS NOT NULL) AND (scope_key = ('coverage:'::text || source_id))))),
    CONSTRAINT monitoring_snapshot_bound CHECK (((cardinality(member_snapshot) <= 100) AND (cardinality(closing_evidence) <= 100)))
);

-- mondek:statement
CREATE TABLE public.observations (
    id uuid NOT NULL,
    assignment_id text NOT NULL,
    installation_id uuid NOT NULL,
    session_id uuid NOT NULL,
    generation integer NOT NULL,
    sequence bigint NOT NULL,
    started_at timestamp without time zone NOT NULL,
    evaluated_at timestamp without time zone NOT NULL,
    received_at timestamp without time zone NOT NULL,
    payload jsonb NOT NULL,
    disposition text NOT NULL,
    CONSTRAINT positive_evidence_order CHECK (((sequence > 0) AND (generation > 0) AND (evaluated_at >= started_at)))
);

-- mondek:statement
CREATE TABLE public.occurrence_evidence (
    occurrence_id uuid NOT NULL,
    observation_id uuid NOT NULL,
    incident_id uuid NOT NULL,
    result_key text NOT NULL,
    generation bigint NOT NULL,
    role text NOT NULL,
    CONSTRAINT occurrence_evidence_generation_check CHECK ((generation > 0)),
    CONSTRAINT occurrence_evidence_role_check CHECK ((role = ANY (ARRAY['fact'::text, 'closure'::text])))
);

-- mondek:statement
CREATE TABLE public.occurrences (
    id uuid NOT NULL,
    incident_id uuid,
    kind text NOT NULL,
    attention_revision integer NOT NULL,
    payload jsonb NOT NULL,
    destination text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    delivered_at timestamp without time zone,
    gate_revision bigint DEFAULT 0 NOT NULL,
    condition_incident_id uuid,
    condition_fact_id uuid,
    covered_warn_fact_id uuid,
    monitoring_incident_id uuid,
    CONSTRAINT gate_revision_nonnegative CHECK ((gate_revision >= 0)),
    CONSTRAINT occurrence_owner CHECK ((((monitoring_incident_id IS NULL) AND (((incident_id IS NOT NULL) AND (condition_incident_id IS NULL) AND (condition_fact_id IS NULL) AND (covered_warn_fact_id IS NULL)) OR ((incident_id IS NULL) AND (condition_incident_id IS NOT NULL) AND (((kind = 'resolved'::text) AND (condition_fact_id IS NULL) AND (covered_warn_fact_id IS NULL)) OR ((kind = 'firing'::text) AND (condition_fact_id IS NOT NULL)))))) OR ((monitoring_incident_id IS NOT NULL) AND (incident_id IS NULL) AND (condition_incident_id IS NULL) AND (condition_fact_id IS NULL) AND (covered_warn_fact_id IS NULL) AND (kind = ANY (ARRAY['firing'::text, 'resolved'::text])))))
);

-- mondek:statement
CREATE TABLE public.publisher_lifecycle_events (
    id bigint NOT NULL,
    publisher_id bigint NOT NULL,
    lifecycle_revision bigint NOT NULL,
    action text NOT NULL,
    reason text NOT NULL,
    actor text NOT NULL,
    successor_id bigint,
    review_digest text NOT NULL,
    proposal jsonb NOT NULL,
    snapshot jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT publisher_lifecycle_event_shape CHECK (((lifecycle_revision > 1) AND (action = ANY (ARRAY['retire'::text, 'replace'::text, 'restore'::text])) AND ((octet_length(btrim(reason)) >= 1) AND (octet_length(btrim(reason)) <= 500)) AND (reason !~ '[\x01-\x1f\x7f]'::text) AND ((octet_length(actor) >= 1) AND (octet_length(actor) <= 200)) AND (review_digest ~ '^[a-f0-9]{64}$'::text) AND (jsonb_typeof(proposal) = 'object'::text) AND (jsonb_typeof(snapshot) = 'object'::text) AND (((action = 'replace'::text) AND (successor_id IS NOT NULL) AND (successor_id <> publisher_id)) OR ((action <> 'replace'::text) AND (successor_id IS NULL)))))
);

-- mondek:statement
CREATE SEQUENCE public.publisher_lifecycle_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.publisher_lifecycle_events_id_seq OWNED BY public.publisher_lifecycle_events.id;

-- mondek:statement
CREATE TABLE public.publisher_lifecycle_evidence (
    event_id bigint NOT NULL,
    observation_id uuid NOT NULL
);

-- mondek:statement
CREATE TABLE public.result_streams (
    id uuid NOT NULL,
    assignment_id text NOT NULL,
    result_key text NOT NULL,
    label text NOT NULL,
    target jsonb NOT NULL,
    current jsonb DEFAULT '{}'::jsonb NOT NULL,
    retired_at timestamp without time zone,
    retirement_reason text,
    admission_generation integer DEFAULT 1 NOT NULL,
    retirement_generation integer,
    environment text,
    environment_label text,
    condition jsonb,
    check_group jsonb,
    CONSTRAINT condition_metadata_shape CHECK (((condition IS NULL) OR COALESCE(((jsonb_typeof(condition) = 'object'::text) AND (condition ?& ARRAY['namespace'::text, 'key'::text, 'label'::text]) AND ((condition - ARRAY['namespace'::text, 'key'::text, 'label'::text]) = '{}'::jsonb) AND (jsonb_typeof((condition -> 'namespace'::text)) = 'string'::text) AND ((condition ->> 'namespace'::text) ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'::text) AND (jsonb_typeof((condition -> 'key'::text)) = 'string'::text) AND ((condition ->> 'key'::text) ~ '^[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}$'::text) AND (jsonb_typeof((condition -> 'label'::text)) = 'string'::text) AND ((octet_length((condition ->> 'label'::text)) >= 1) AND (octet_length((condition ->> 'label'::text)) <= 200)) AND (btrim((condition ->> 'label'::text)) <> ''::text) AND ((condition ->> 'label'::text) !~ ((((('['::text || chr(1)) || '-'::text) || chr(31)) || chr(127)) || ']'::text))), false))),
    CONSTRAINT positive_stream_admission CHECK ((admission_generation > 0))
);

-- mondek:statement
CREATE TABLE public.runners (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    boot bigint NOT NULL,
    last_seen_at timestamp without time zone NOT NULL,
    status jsonb DEFAULT '{}'::jsonb NOT NULL,
    label text,
    CONSTRAINT positive_runner_boot CHECK ((boot > 0))
);

-- mondek:statement
CREATE TABLE public.source_inventories (
    id bigint NOT NULL,
    runner_id uuid NOT NULL,
    source_id text NOT NULL,
    revision bigint NOT NULL,
    source_revision text NOT NULL,
    payload jsonb NOT NULL,
    received_at timestamp without time zone NOT NULL,
    coverage_version integer,
    coverage_revision bigint,
    coverage_received_at timestamp without time zone,
    coverage_source_revision text,
    coverage_code_revision text,
    coverage_runtime_revision text,
    coverage_context jsonb,
    coverage_confirmed boolean DEFAULT false NOT NULL,
    lifecycle_revision bigint DEFAULT 1 NOT NULL,
    retired_at timestamp without time zone,
    retirement_reason text,
    replacement_id bigint,
    resume_after_revision bigint,
    CONSTRAINT coverage_metadata_presence CHECK ((((coverage_version IS NOT NULL) = (coverage_revision IS NOT NULL)) AND ((coverage_version IS NOT NULL) = (coverage_received_at IS NOT NULL)) AND ((coverage_version IS NOT NULL) = (coverage_source_revision IS NOT NULL)) AND ((coverage_version IS NOT NULL) = (coverage_code_revision IS NOT NULL)) AND ((coverage_version IS NOT NULL) = (coverage_runtime_revision IS NOT NULL)) AND ((coverage_version IS NOT NULL) = (coverage_context IS NOT NULL)))),
    CONSTRAINT coverage_metadata_shape CHECK ((((coverage_version IS NULL) AND (coverage_revision IS NULL) AND (coverage_source_revision IS NULL) AND (coverage_code_revision IS NULL) AND (coverage_runtime_revision IS NULL) AND (coverage_context IS NULL) AND (NOT coverage_confirmed)) OR ((coverage_version = 1) AND (coverage_revision > 0) AND (coverage_revision <= revision) AND (coverage_source_revision ~ '^[a-f0-9]{64}$'::text) AND (coverage_code_revision ~ '^[a-f0-9]{64}$'::text) AND (coverage_runtime_revision ~ '^[a-f0-9]{64}$'::text) AND (jsonb_typeof(coverage_context) = 'object'::text) AND ((NOT coverage_confirmed) OR ((coverage_revision = revision) AND (coverage_source_revision = source_revision)))))),
    CONSTRAINT publisher_lifecycle_shape CHECK (((lifecycle_revision >= 1) AND ((replacement_id IS NULL) OR (replacement_id <> id)) AND (((retired_at IS NULL) AND (retirement_reason IS NULL) AND (replacement_id IS NULL)) OR ((retired_at IS NOT NULL) AND (retirement_reason IS NOT NULL) AND ((octet_length(btrim(retirement_reason)) >= 1) AND (octet_length(btrim(retirement_reason)) <= 500)) AND (retirement_reason !~ '[\x01-\x1f\x7f]'::text) AND (resume_after_revision IS NULL))) AND ((resume_after_revision IS NULL) OR ((resume_after_revision > 0) AND (resume_after_revision = revision) AND (retired_at IS NULL)))))
);

-- mondek:statement
CREATE SEQUENCE public.source_inventories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

-- mondek:statement
ALTER SEQUENCE public.source_inventories_id_seq OWNED BY public.source_inventories.id;

-- mondek:statement
ALTER TABLE ONLY public.configuration_revisions ALTER COLUMN id SET DEFAULT nextval('public.configuration_revisions_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.configuration_rule_diagnostics ALTER COLUMN id SET DEFAULT nextval('public.configuration_rule_diagnostics_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.configurations ALTER COLUMN id SET DEFAULT nextval('public.configurations_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.controls ALTER COLUMN id SET DEFAULT nextval('public.controls_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.coverage_declarations ALTER COLUMN id SET DEFAULT nextval('public.coverage_declarations_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_events ALTER COLUMN id SET DEFAULT nextval('public.maintenance_events_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_series_events ALTER COLUMN id SET DEFAULT nextval('public.maintenance_series_events_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_events ALTER COLUMN id SET DEFAULT nextval('public.publisher_lifecycle_events_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.source_inventories ALTER COLUMN id SET DEFAULT nextval('public.source_inventories_id_seq'::regclass);

-- mondek:statement
ALTER TABLE ONLY public.assignments
    ADD CONSTRAINT assignments_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_facts_id_condition_incident_id_key UNIQUE (id, condition_incident_id);

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_facts_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.condition_incidents
    ADD CONSTRAINT condition_incidents_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_git_objects
    ADD CONSTRAINT configuration_git_objects_pkey PRIMARY KEY (oid);

-- mondek:statement
ALTER TABLE ONLY public.configuration_policy_projects
    ADD CONSTRAINT configuration_policy_projects_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_policy_receipts
    ADD CONSTRAINT configuration_policy_receipts_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_repository
    ADD CONSTRAINT configuration_repository_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_revisions
    ADD CONSTRAINT configuration_revisions_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_rule_diagnostics
    ADD CONSTRAINT configuration_rule_diagnostics_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_rules
    ADD CONSTRAINT configuration_rules_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.configurations
    ADD CONSTRAINT configurations_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.controls
    ADD CONSTRAINT controls_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.coverage_declarations
    ADD CONSTRAINT coverage_declarations_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.discovery_changes
    ADD CONSTRAINT discovery_changes_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_events
    ADD CONSTRAINT maintenance_events_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_series_events
    ADD CONSTRAINT maintenance_series_events_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_series
    ADD CONSTRAINT maintenance_series_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_windows
    ADD CONSTRAINT maintenance_windows_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.monitoring_gaps
    ADD CONSTRAINT monitoring_gaps_pkey PRIMARY KEY (key);

-- mondek:statement
ALTER TABLE ONLY public.monitoring_incidents
    ADD CONSTRAINT monitoring_incidents_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.occurrence_evidence
    ADD CONSTRAINT occurrence_evidence_pkey PRIMARY KEY (occurrence_id, observation_id, incident_id);

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_events
    ADD CONSTRAINT publisher_lifecycle_events_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_evidence
    ADD CONSTRAINT publisher_lifecycle_evidence_pkey PRIMARY KEY (event_id, observation_id);

-- mondek:statement
ALTER TABLE ONLY public.result_streams
    ADD CONSTRAINT result_streams_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.runners
    ADD CONSTRAINT runners_pkey PRIMARY KEY (id);

-- mondek:statement
ALTER TABLE ONLY public.source_inventories
    ADD CONSTRAINT source_inventories_pkey PRIMARY KEY (id);

-- mondek:statement
CREATE INDEX active_result_condition ON public.result_streams USING btree (((condition ->> 'namespace'::text)), ((condition ->> 'key'::text)), environment) WHERE ((condition IS NOT NULL) AND (retired_at IS NULL));

-- mondek:statement
CREATE UNIQUE INDEX active_result_key ON public.result_streams USING btree (assignment_id, result_key) WHERE (retired_at IS NULL);

-- mondek:statement
CREATE UNIQUE INDEX active_source_check ON public.assignments USING btree (runner_id, source_id, source_key) WHERE ((retired_at IS NULL) AND (source_id IS NOT NULL));

-- mondek:statement
CREATE UNIQUE INDEX assignments_configuration_exception_key_index ON public.assignments USING btree (configuration_exception_key);

-- mondek:statement
CREATE INDEX assignments_retired_at_index ON public.assignments USING btree (retired_at);

-- mondek:statement
CREATE INDEX assignments_runner_id_retired_at_index ON public.assignments USING btree (runner_id, retired_at);

-- mondek:statement
CREATE INDEX assignments_source_id_parameter_contract_parameter_schema_finge ON public.assignments USING btree (source_id, parameter_contract, parameter_schema_fingerprint) WHERE ((retired_at IS NULL) AND (parameter_contract IS NOT NULL));

-- mondek:statement
CREATE INDEX attempts_occurrence_id_started_at_index ON public.attempts USING btree (occurrence_id, started_at);

-- mondek:statement
CREATE INDEX condition_facts_evidence ON public.condition_facts USING btree (opening_observation_id);

-- mondek:statement
CREATE INDEX condition_incidents_history ON public.condition_incidents USING btree (opened_at, id);

-- mondek:statement
CREATE UNIQUE INDEX configuration_revisions_head_index ON public.configuration_revisions USING btree (head);

-- mondek:statement
CREATE UNIQUE INDEX configuration_rule_diagnostics_source_id_runner_id_source_key_i ON public.configuration_rule_diagnostics USING btree (source_id, runner_id, source_key);

-- mondek:statement
CREATE UNIQUE INDEX configuration_rules_managed_project_managed_key_index ON public.configuration_rules USING btree (managed_project, managed_key);

-- mondek:statement
CREATE UNIQUE INDEX configuration_rules_repository_key_index ON public.configuration_rules USING btree (repository_key);

-- mondek:statement
CREATE INDEX configuration_rules_source_id_parameter_contract_index ON public.configuration_rules USING btree (source_id, parameter_contract);

-- mondek:statement
CREATE UNIQUE INDEX configurations_assignment_id_generation_index ON public.configurations USING btree (assignment_id, generation);

-- mondek:statement
CREATE INDEX controls_condition_incident_id_inserted_at_index ON public.controls USING btree (condition_incident_id, inserted_at);

-- mondek:statement
CREATE INDEX controls_monitoring_incident_id_inserted_at_index ON public.controls USING btree (monitoring_incident_id, inserted_at);

-- mondek:statement
CREATE INDEX coverage_declarations_assignment_id_index ON public.coverage_declarations USING btree (assignment_id);

-- mondek:statement
CREATE INDEX coverage_declarations_scope_id_runner_id_index ON public.coverage_declarations USING btree (scope_id, runner_id);

-- mondek:statement
CREATE INDEX coverage_declarations_source_id_environment_index ON public.coverage_declarations USING btree (source_id, environment);

-- mondek:statement
CREATE UNIQUE INDEX coverage_declarations_source_inventory_id_source_key_result_key ON public.coverage_declarations USING btree (source_inventory_id, source_key, result_key);

-- mondek:statement
CREATE INDEX discovery_changes_assignment_id_saved_at_index ON public.discovery_changes USING btree (assignment_id, saved_at);

-- mondek:statement
CREATE INDEX discovery_changes_source_id_index ON public.discovery_changes USING btree (source_id) WHERE (pending = true);

-- mondek:statement
CREATE INDEX incidents_closed_at_index ON public.incidents USING btree (closed_at) WHERE (status = 'closed'::text);

-- mondek:statement
CREATE INDEX incidents_closing_observation_id_index ON public.incidents USING btree (closing_observation_id) WHERE (closing_observation_id IS NOT NULL);

-- mondek:statement
CREATE INDEX incidents_condition_incident_id_status_index ON public.incidents USING btree (condition_incident_id, status);

-- mondek:statement
CREATE INDEX incidents_environment_index ON public.incidents USING btree (environment);

-- mondek:statement
CREATE INDEX incidents_latest_observation_id_index ON public.incidents USING btree (latest_observation_id);

-- mondek:statement
CREATE INDEX incidents_opening_observation_id_index ON public.incidents USING btree (opening_observation_id);

-- mondek:statement
CREATE INDEX incidents_stream_id_opened_at_index ON public.incidents USING btree (stream_id, opened_at);

-- mondek:statement
CREATE UNIQUE INDEX maintenance_events_window_id_revision_index ON public.maintenance_events USING btree (window_id, revision);

-- mondek:statement
CREATE UNIQUE INDEX maintenance_series_events_series_id_revision_index ON public.maintenance_series_events USING btree (series_id, revision);

-- mondek:statement
CREATE INDEX maintenance_windows_selections_index ON public.maintenance_windows USING gin (selections);

-- mondek:statement
CREATE UNIQUE INDEX maintenance_windows_series_id_series_index_index ON public.maintenance_windows USING btree (series_id, series_index);

-- mondek:statement
CREATE INDEX maintenance_windows_source_id_environment_target_kind_target_ke ON public.maintenance_windows USING btree (source_id, environment, target_kind, target_key);

-- mondek:statement
CREATE INDEX maintenance_windows_starts_at_ends_at_index ON public.maintenance_windows USING btree (starts_at, ends_at) WHERE (cancelled_at IS NULL);

-- mondek:statement
CREATE UNIQUE INDEX monitoring_gaps_identity_index ON public.monitoring_gaps USING btree (identity);

-- mondek:statement
CREATE INDEX monitoring_gaps_scope_key_ready_at_key_index ON public.monitoring_gaps USING btree (scope_key, ready_at, key);

-- mondek:statement
CREATE INDEX monitoring_incidents_opened_at_id_index ON public.monitoring_incidents USING btree (opened_at, id);

-- mondek:statement
CREATE UNIQUE INDEX monitoring_incidents_scope_key_index ON public.monitoring_incidents USING btree (scope_key) WHERE (status = 'open'::text);

-- mondek:statement
CREATE INDEX observations_assignment_id_received_at_index ON public.observations USING btree (assignment_id, received_at);

-- mondek:statement
CREATE INDEX observations_received_at_id_index ON public.observations USING btree (received_at, id);

-- mondek:statement
CREATE INDEX occurrence_evidence_observation ON public.occurrence_evidence USING btree (observation_id);

-- mondek:statement
CREATE UNIQUE INDEX occurrences_condition_fact_id_index ON public.occurrences USING btree (condition_fact_id) WHERE (condition_fact_id IS NOT NULL);

-- mondek:statement
CREATE INDEX occurrences_condition_incident_id_inserted_at_index ON public.occurrences USING btree (condition_incident_id, inserted_at);

-- mondek:statement
CREATE UNIQUE INDEX occurrences_incident_id_kind_attention_revision_index ON public.occurrences USING btree (incident_id, kind, attention_revision);

-- mondek:statement
CREATE UNIQUE INDEX occurrences_monitoring_incident_id_kind_attention_revision_inde ON public.occurrences USING btree (monitoring_incident_id, kind, attention_revision);

-- mondek:statement
CREATE INDEX occurrences_observation_reference ON public.occurrences USING btree (((payload ->> 'observation_id'::text)));

-- mondek:statement
CREATE INDEX occurrences_terminal_order ON public.occurrences USING btree (inserted_at) WHERE (status = ANY (ARRAY['delivered'::text, 'superseded'::text]));

-- mondek:statement
CREATE INDEX occurrences_unresolved_order ON public.occurrences USING btree (inserted_at, id) WHERE (status <> ALL (ARRAY['delivered'::text, 'superseded'::text]));

-- mondek:statement
CREATE UNIQUE INDEX one_active_condition_fact ON public.condition_facts USING btree (condition_incident_id, kind, key) WHERE (ended_at IS NULL);

-- mondek:statement
CREATE UNIQUE INDEX one_condition_resolution ON public.occurrences USING btree (condition_incident_id) WHERE ((condition_incident_id IS NOT NULL) AND (kind = 'resolved'::text));

-- mondek:statement
CREATE UNIQUE INDEX one_open_condition ON public.condition_incidents USING btree (namespace, key, environment) NULLS NOT DISTINCT WHERE (status = 'open'::text);

-- mondek:statement
CREATE UNIQUE INDEX one_open_result_stream ON public.incidents USING btree (stream_id) WHERE (status = 'open'::text);

-- mondek:statement
CREATE UNIQUE INDEX publisher_lifecycle_events_publisher_id_lifecycle_revision_inde ON public.publisher_lifecycle_events USING btree (publisher_id, lifecycle_revision);

-- mondek:statement
CREATE UNIQUE INDEX publisher_lifecycle_events_review_digest_index ON public.publisher_lifecycle_events USING btree (review_digest);

-- mondek:statement
CREATE INDEX publisher_lifecycle_evidence_observation_id_index ON public.publisher_lifecycle_evidence USING btree (observation_id);

-- mondek:statement
CREATE INDEX result_streams_assignment_id_retired_at_index ON public.result_streams USING btree (assignment_id, retired_at);

-- mondek:statement
CREATE INDEX result_streams_environment_index ON public.result_streams USING btree (environment);

-- mondek:statement
CREATE UNIQUE INDEX source_inventories_id_runner_id_source_id_index ON public.source_inventories USING btree (id, runner_id, source_id);

-- mondek:statement
CREATE UNIQUE INDEX source_inventories_runner_id_source_id_index ON public.source_inventories USING btree (runner_id, source_id);

-- mondek:statement
CREATE TRIGGER immutable_condition_fact BEFORE INSERT OR UPDATE ON public.condition_facts FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_condition_fact();

-- mondek:statement
CREATE TRIGGER immutable_condition_identity BEFORE UPDATE ON public.condition_incidents FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_condition_identity();

-- mondek:statement
CREATE TRIGGER immutable_contribution_identity BEFORE INSERT OR UPDATE ON public.incidents FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_contribution_identity();

-- mondek:statement
CREATE TRIGGER immutable_monitoring_incident BEFORE UPDATE ON public.monitoring_incidents FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_monitoring_incident();

-- mondek:statement
CREATE TRIGGER immutable_monitoring_owner BEFORE UPDATE ON public.occurrences FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_monitoring_owner();

-- mondek:statement
CREATE TRIGGER immutable_occurrence BEFORE UPDATE ON public.occurrences FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_occurrence();

-- mondek:statement
CREATE TRIGGER immutable_occurrence_evidence BEFORE INSERT OR UPDATE ON public.occurrence_evidence FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_occurrence_evidence();

-- mondek:statement
CREATE TRIGGER valid_condition_occurrence BEFORE INSERT ON public.occurrences FOR EACH ROW EXECUTE FUNCTION public.mondek_immutable_occurrence();

-- mondek:statement
ALTER TABLE ONLY public.assignments
    ADD CONSTRAINT assignments_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.runners(id);

-- mondek:statement
ALTER TABLE ONLY public.attempts
    ADD CONSTRAINT attempts_occurrence_id_fkey FOREIGN KEY (occurrence_id) REFERENCES public.occurrences(id);

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_fact_accepted_occurrence FOREIGN KEY (covered_by_occurrence_id) REFERENCES public.occurrences(id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_facts_condition_incident_id_fkey FOREIGN KEY (condition_incident_id) REFERENCES public.condition_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_facts_opening_incident_id_fkey FOREIGN KEY (opening_incident_id) REFERENCES public.incidents(id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.condition_facts
    ADD CONSTRAINT condition_facts_opening_observation_id_fkey FOREIGN KEY (opening_observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.condition_incidents
    ADD CONSTRAINT condition_incidents_closing_observation_id_fkey FOREIGN KEY (closing_observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.configuration_policy_receipts
    ADD CONSTRAINT configuration_policy_receipts_project_fkey FOREIGN KEY (project) REFERENCES public.configuration_policy_projects(id);

-- mondek:statement
ALTER TABLE ONLY public.configurations
    ADD CONSTRAINT configurations_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.controls
    ADD CONSTRAINT controls_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.controls
    ADD CONSTRAINT controls_condition_incident_id_fkey FOREIGN KEY (condition_incident_id) REFERENCES public.condition_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.controls
    ADD CONSTRAINT controls_monitoring_incident_id_fkey FOREIGN KEY (monitoring_incident_id) REFERENCES public.monitoring_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.controls
    ADD CONSTRAINT controls_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.result_streams(id);

-- mondek:statement
ALTER TABLE ONLY public.coverage_declarations
    ADD CONSTRAINT coverage_declarations_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id) ON DELETE SET NULL;

-- mondek:statement
ALTER TABLE ONLY public.coverage_declarations
    ADD CONSTRAINT coverage_publisher_owner FOREIGN KEY (source_inventory_id, runner_id, source_id) REFERENCES public.source_inventories(id, runner_id, source_id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_condition_incident_id_fkey FOREIGN KEY (condition_incident_id) REFERENCES public.condition_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_latest_observation_id_fkey FOREIGN KEY (latest_observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_opening_observation_id_fkey FOREIGN KEY (opening_observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_stream_id_fkey FOREIGN KEY (stream_id) REFERENCES public.result_streams(id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_events
    ADD CONSTRAINT maintenance_events_window_id_fkey FOREIGN KEY (window_id) REFERENCES public.maintenance_windows(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.maintenance_series_events
    ADD CONSTRAINT maintenance_series_events_series_id_fkey FOREIGN KEY (series_id) REFERENCES public.maintenance_series(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.maintenance_windows
    ADD CONSTRAINT maintenance_windows_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.maintenance_windows
    ADD CONSTRAINT maintenance_windows_series_id_fkey FOREIGN KEY (series_id) REFERENCES public.maintenance_series(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.monitoring_incidents
    ADD CONSTRAINT monitoring_incidents_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.runners(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.observations
    ADD CONSTRAINT observations_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.occurrence_evidence
    ADD CONSTRAINT occurrence_evidence_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.incidents(id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.occurrence_evidence
    ADD CONSTRAINT occurrence_evidence_observation_id_fkey FOREIGN KEY (observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.occurrence_evidence
    ADD CONSTRAINT occurrence_evidence_occurrence_id_fkey FOREIGN KEY (occurrence_id) REFERENCES public.occurrences(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrence_fact_owner FOREIGN KEY (condition_fact_id, condition_incident_id) REFERENCES public.condition_facts(id, condition_incident_id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrence_warn_owner FOREIGN KEY (covered_warn_fact_id, condition_incident_id) REFERENCES public.condition_facts(id, condition_incident_id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_condition_fact_id_fkey FOREIGN KEY (condition_fact_id) REFERENCES public.condition_facts(id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_condition_incident_id_fkey FOREIGN KEY (condition_incident_id) REFERENCES public.condition_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_covered_warn_fact_id_fkey FOREIGN KEY (covered_warn_fact_id) REFERENCES public.condition_facts(id) DEFERRABLE INITIALLY DEFERRED;

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.incidents(id);

-- mondek:statement
ALTER TABLE ONLY public.occurrences
    ADD CONSTRAINT occurrences_monitoring_incident_id_fkey FOREIGN KEY (monitoring_incident_id) REFERENCES public.monitoring_incidents(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_events
    ADD CONSTRAINT publisher_lifecycle_events_publisher_id_fkey FOREIGN KEY (publisher_id) REFERENCES public.source_inventories(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_events
    ADD CONSTRAINT publisher_lifecycle_events_successor_id_fkey FOREIGN KEY (successor_id) REFERENCES public.source_inventories(id);

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_evidence
    ADD CONSTRAINT publisher_lifecycle_evidence_event_id_fkey FOREIGN KEY (event_id) REFERENCES public.publisher_lifecycle_events(id) ON DELETE CASCADE;

-- mondek:statement
ALTER TABLE ONLY public.publisher_lifecycle_evidence
    ADD CONSTRAINT publisher_lifecycle_evidence_observation_id_fkey FOREIGN KEY (observation_id) REFERENCES public.observations(id);

-- mondek:statement
ALTER TABLE ONLY public.result_streams
    ADD CONSTRAINT result_streams_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.assignments(id);

-- mondek:statement
ALTER TABLE ONLY public.source_inventories
    ADD CONSTRAINT source_inventories_replacement_id_fkey FOREIGN KEY (replacement_id) REFERENCES public.source_inventories(id);

-- mondek:statement
ALTER TABLE ONLY public.source_inventories
    ADD CONSTRAINT source_inventories_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.runners(id);

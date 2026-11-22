# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.API.CorrelationSchemas do
  alias OpenApiSpex.Schema
  alias MondekWeb.API.Schemas, as: S
  def episode, do: S.record(%{id: S.uuid(), type: S.enum(~w(individual condition))}, [:id, :type])

  def proposal do
    S.record(
      %{
        action: S.enum(~w(create attach detach merge split anchor)),
        request_id: S.uuid(),
        case_id: S.uuid(),
        other_case_id: S.uuid(),
        episodes: %Schema{type: :array, maxItems: 250, items: episode()},
        anchor: S.nullable(episode()),
        title: %Schema{type: :string, minLength: 1, maxLength: 200},
        reason: %Schema{type: :string, minLength: 1, maxLength: 2000}
      },
      [:action, :request_id, :reason]
    )
  end

  def response(:case_control_preview),
    do:
      S.record(
        %{case_id: S.uuid(), proposal: control(), scope: S.object(), review_token: S.string()},
        [
          :case_id,
          :proposal,
          :review_token
        ]
      )

  def response(:case_control_apply), do: response(:correlation_apply)

  def response(:correlation_preview),
    do:
      S.record(
        %{
          proposal: proposal(),
          review_token: S.string(),
          notification_effect: S.enum(["unchanged", "case_policy"]),
          cases: S.array(S.ref("CorrelationCase")),
          as_of: S.time()
        },
        [:proposal, :review_token, :notification_effect, :cases, :as_of]
      )

  def response(:correlation_apply),
    do: S.record(%{case_id: S.uuid(), replayed: S.boolean()}, [:case_id, :replayed])

  def response(:correlation_rules), do: S.array(S.ref("CorrelationAutomationRule"))
  def response(:correlation_rule), do: S.ref("CorrelationAutomationRule")

  def response(:correlation_override_preview),
    do:
      S.record(
        %{
          proposal: override_proposal(),
          review_token: S.string(),
          override: S.ref("CorrelationAutomationOverride"),
          as_of: S.time()
        },
        ~w(proposal review_token override as_of)a
      )

  def response(:correlation_override_apply), do: override_state(%{replayed: S.boolean()})

  def response(:correlation_relationship_preview),
    do:
      S.record(
        %{
          proposal: relationship_proposal(),
          review_token: S.string(),
          matches: S.array(S.ref("HintCandidateMatch")),
          relationship: S.nullable(S.ref("CorrelationRelationship")),
          notification_effect: S.enum(["none"]),
          as_of: S.time()
        },
        ~w(proposal review_token matches relationship notification_effect as_of)a
      )

  def response(:correlation_relationship_apply),
    do:
      S.record(%{relationship_id: S.uuid(), replayed: S.boolean()}, [:relationship_id, :replayed])

  def response(:correlation_candidates), do: S.array(S.ref("IncidentSummary"))

  def response(:correlation_cases), do: S.array(S.ref("CorrelationCase"))

  def response(:correlation_case),
    do:
      S.record(
        %{
          delivery: S.ref("CaseDelivery"),
          case: S.ref("CorrelationCase"),
          members: page(S.ref("CorrelationMember")),
          decisions: page(S.ref("CorrelationDecision"))
        },
        [:case, :members, :decisions]
      )

  def request(:case_control_preview), do: control()
  def request(:case_control_apply), do: request(:correlation_apply)

  def request(:correlation_preview), do: proposal()
  def request(:correlation_rule), do: rule()
  def request(:correlation_override_preview), do: override_proposal()
  def request(:correlation_override_apply), do: request(:correlation_apply)
  def request(:correlation_relationship_preview), do: relationship_proposal()
  def request(:correlation_relationship_apply), do: request(:correlation_apply)

  def request(:correlation_apply),
    do:
      S.record(%{review_token: %Schema{type: :string, minLength: 1, maxLength: 65536}}, [
        :review_token
      ])

  defp page(item),
    do:
      S.record(
        %{items: S.array(item), page: S.integer(), page_size: S.integer(), total: S.integer()},
        [:items, :page, :page_size, :total]
      )

  defp reason, do: %Schema{type: :string, minLength: 1, maxLength: 2_000}

  defp rule(extra \\ %{}) do
    fields = %{
      source_id: S.string(),
      check_id: S.string(),
      output_key: S.string(),
      hint: S.ref("CorrelationHint"),
      enabled: S.boolean(),
      revision: %Schema{type: :integer, minimum: 0},
      reason: reason()
    }

    fields = Map.merge(fields, extra)
    S.record(fields, fields |> Map.keys() |> Enum.sort_by(&Atom.to_string/1))
  end

  defp override_proposal do
    S.record(
      %{
        action: S.enum(~w(keep_standalone allow_grouping)),
        request_id: S.uuid(),
        subject: episode(),
        reason: reason()
      },
      ~w(action request_id subject reason)a
    )
  end

  defp override_state(extra \\ %{}) do
    fields =
      Map.merge(
        %{
          subject: episode(),
          active: S.boolean(),
          revision: S.integer(),
          reason: S.nullable(S.string()),
          updated_at: S.time()
        },
        extra
      )

    S.record(fields, fields |> Map.keys() |> Enum.sort_by(&Atom.to_string/1))
  end

  defp relationship_proposal do
    common = %{
      request_id: S.uuid(),
      subject: episode(),
      reason: %Schema{type: :string, minLength: 1, maxLength: 2_000}
    }

    %Schema{
      oneOf: [
        S.record(
          Map.merge(common, %{
            action: S.enum(["add"]),
            target: episode(),
            dimension: %Schema{type: :string, minLength: 1, maxLength: 128}
          }),
          ~w(action request_id subject target dimension reason)a
        ),
        S.record(
          Map.merge(common, %{action: S.enum(["remove"]), relationship_id: S.uuid()}),
          ~w(action request_id subject relationship_id reason)a
        )
      ]
    }
  end

  defp control,
    do:
      S.record(
        %{
          action: S.enum(~w(enable disable acknowledge end)),
          request_id: S.uuid(),
          note: %OpenApiSpex.Schema{type: :string, maxLength: 2000, minLength: 1},
          seconds: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 31_536_000}
        },
        [:action, :request_id, :note]
      )

  def definitions do
    %{
      "CorrelationAutomationRule" => rule(%{id: S.uuid(), updated_at: S.time()}),
      "CorrelationAutomationOverride" => override_state(),
      "CorrelationAutomaticEvaluation" =>
        S.record(
          %{
            disposition: S.enum(~w(review created)),
            reason: S.string(),
            case_id: S.nullable(S.uuid()),
            evidence: S.object(),
            evaluated_at: S.time()
          },
          ~w(disposition reason case_id evidence evaluated_at)a
        ),
      "CorrelationRelationshipPage" =>
        S.record(
          %{
            subject: episode(),
            items: S.array(S.ref("CorrelationRelationship")),
            page: S.integer(),
            page_size: S.integer(),
            total: S.integer()
          },
          ~w(subject items page page_size total)a
        ),
      "CorrelationRelationship" =>
        S.record(
          %{
            id: S.uuid(),
            subject: S.ref("CorrelationRelationshipEndpoint"),
            target: S.ref("CorrelationRelationshipEndpoint"),
            dimension: S.string(),
            matches: S.array(S.ref("HintCandidateMatch")),
            revision: S.integer(),
            status: S.enum(~w(active removed endpoint_closed)),
            actor: S.string(),
            reason: S.string(),
            inserted_at: S.time(),
            removed_at: S.time(),
            removed_by: S.nullable(S.string()),
            removal_reason: S.nullable(S.string())
          },
          ~w(id subject target dimension matches revision status actor reason inserted_at)a
        ),
      "CorrelationRelationshipEndpoint" =>
        S.record(
          %{
            id: S.uuid(),
            type: S.enum(~w(individual condition)),
            status: S.enum(~w(open closed))
          },
          ~w(id type status)a
        ),
      "CorrelationCandidateInspection" =>
        S.record(
          %{
            subject: episode(),
            status: S.enum(~w(complete incomplete unavailable)),
            hint_count: S.integer(),
            truncated: S.boolean(),
            conflicting_hints: S.boolean(),
            candidates: %Schema{type: :array, maxItems: 20, items: S.ref("HintCandidate")}
          },
          ~w(subject status hint_count truncated conflicting_hints candidates)a
        ),
      "HintCandidate" =>
        S.record(
          %{
            type: S.enum(~w(individual condition)),
            id: S.uuid(),
            label: S.string(),
            health: S.enum(~w(WARN CRIT)),
            opened_at: S.time(),
            matches: %Schema{type: :array, maxItems: 4, items: S.ref("HintCandidateMatch")}
          },
          ~w(type id label health opened_at matches)a
        ),
      "HintCandidateMatch" =>
        S.record(
          %{
            dimension: S.string(),
            depends_on: %Schema{
              oneOf: [S.ref("CorrelationConditionRef"), S.ref("CorrelationTargetRef")]
            },
            window_seconds: %Schema{type: :integer, minimum: 1, maximum: 86_400},
            timing: S.enum(~w(overlap later_opening)),
            contributors: %Schema{
              type: :array,
              maxItems: 4,
              items:
                S.record(
                  %{incident_id: S.uuid(), assignment_id: S.string(), generation: S.integer()},
                  ~w(incident_id assignment_id generation)a
                )
            }
          },
          ~w(dimension depends_on window_seconds timing contributors)a
        ),
      "CaseDelivery" =>
        S.record(
          %{
            delivery_enabled: S.boolean(),
            batching_enabled: S.boolean(),
            acknowledgement: S.ref("CaseAcknowledgement"),
            batch_page:
              S.record(%{page: S.integer(), page_size: S.integer(), total: S.integer()}, [
                :page,
                :page_size,
                :total
              ]),
            batches: S.array(S.ref("CaseBatch"))
          },
          [:delivery_enabled, :batching_enabled, :acknowledgement, :batch_page, :batches]
        ),
      "CaseAcknowledgement" =>
        S.record(
          %{
            active: S.boolean(),
            id: S.uuid(),
            revision: S.integer(),
            mode: S.string(),
            until: S.time(),
            ceiling: S.string(),
            note: S.string(),
            ended_at: S.time(),
            end_reason: S.nullable(S.string()),
            inserted_at: S.time()
          },
          [:active, :revision]
        ),
      "CaseBatch" =>
        S.record(
          %{
            id: S.uuid(),
            status: S.enum(~w(pending delivering released accepted)),
            attempts: S.integer(),
            accepted_at: S.time(),
            deadline: S.time(),
            inserted_at: S.time(),
            terminal_id: S.uuid(),
            terminal_status: S.enum(~w(none waiting pending delivering exhausted accepted)),
            terminal_attempts: S.integer(),
            members:
              S.array(
                S.record(
                  %{occurrence_id: S.uuid(), status: S.enum(~w(reserved released accepted))},
                  [:occurrence_id, :status]
                )
              )
          },
          [:id, :status, :attempts, :terminal_status, :members]
        ),
      "CorrelationCase" =>
        S.record(
          %{
            id: S.uuid(),
            title: S.string(),
            environment: S.nullable(S.string()),
            revision: S.integer(),
            status: S.enum(~w(open closed)),
            closed_at: S.time(),
            closure_reason: S.nullable(S.string()),
            health: S.nullable(S.enum(~w(WARN CRIT))),
            member_count: S.integer(),
            open_count: S.integer(),
            inserted_at: S.time(),
            anchor: S.nullable(episode()),
            notification_effect: S.enum(["unchanged", "case_policy"])
          },
          [
            :id,
            :title,
            :revision,
            :status,
            :member_count,
            :open_count,
            :inserted_at,
            :notification_effect
          ]
        ),
      "CorrelationMember" =>
        S.record(
          %{
            id: S.uuid(),
            episode: episode(),
            anchor: S.boolean(),
            inserted_at: S.time(),
            ended_at: S.time(),
            end_reason: S.nullable(S.string()),
            incident: S.ref("IncidentSummary")
          },
          [:id, :episode, :anchor, :inserted_at, :ended_at, :incident]
        ),
      "CorrelationDecision" =>
        S.record(
          %{
            id: S.uuid(),
            action:
              S.enum(~w(create attach detach merge split anchor enable disable acknowledge end)),
            provenance: S.enum(~w(operator deterministic_rule)),
            actor: S.string(),
            reason: S.string(),
            confidence: S.nullable(S.number()),
            inserted_at: S.time(),
            change: S.object()
          },
          [:id, :action, :provenance, :actor, :reason, :inserted_at, :change]
        ),
      "CorrelationMembership" =>
        S.record(
          %{
            case_id: S.uuid(),
            episode: episode(),
            provenance: S.enum(~w(operator deterministic_rule)),
            notification_effect: S.enum(["unchanged", "case_policy"])
          },
          [:case_id, :episode, :provenance, :notification_effect]
        )
    }
  end
end

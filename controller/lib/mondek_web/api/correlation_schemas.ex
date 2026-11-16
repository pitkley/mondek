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
      "CaseDelivery" =>
        S.record(
          %{
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
          [:batching_enabled, :acknowledgement, :batch_page, :batches]
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
            provenance: S.enum(["operator"]),
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
            provenance: S.enum(["operator"]),
            notification_effect: S.enum(["unchanged", "case_policy"])
          },
          [:case_id, :episode, :provenance, :notification_effect]
        )
    }
  end
end

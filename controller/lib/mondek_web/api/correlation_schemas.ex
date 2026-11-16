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

  def response(:correlation_preview),
    do:
      S.record(
        %{
          proposal: proposal(),
          review_token: S.string(),
          notification_effect: S.enum(["unchanged"]),
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
          case: S.ref("CorrelationCase"),
          members: page(S.ref("CorrelationMember")),
          decisions: page(S.ref("CorrelationDecision"))
        },
        [:case, :members, :decisions]
      )

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

  def definitions do
    %{
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
            notification_effect: S.enum(["unchanged"])
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
            action: S.enum(~w(create attach detach merge split anchor)),
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
            notification_effect: S.enum(["unchanged"])
          },
          [:case_id, :episode, :provenance, :notification_effect]
        )
    }
  end
end

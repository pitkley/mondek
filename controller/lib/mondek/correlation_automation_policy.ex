# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationAutomationRule do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "correlation_automation_rules" do
    field :source_id, :string
    field :check_id, :string
    field :output_key, :string
    field :hint, :map
    field :enabled, :boolean
    field :revision, :integer
    field :reason, :string
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Mondek.CorrelationAutomationOverride do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "correlation_automation_overrides" do
    field :incident_id, Ecto.UUID
    field :condition_id, Ecto.UUID
    field :active, :boolean
    field :revision, :integer
    field :reason, :string
    field :updated_at, :utc_datetime_usec
    field :request_id, Ecto.UUID
  end
end

defmodule Mondek.CorrelationAutomationPolicy do
  @moduledoc "Operator approval of exact source hints and reviewed episode-level overrides."
  import Ecto.Query

  alias Mondek.{
    CaseControls,
    ConditionIncident,
    CorrelationAutomationOverride,
    CorrelationAutomationRule,
    CorrelationGrouping,
    Correlations,
    Incident,
    Monitoring,
    Parameters,
    Protocol,
    Repo
  }

  @salt "correlation-override-review-v1"
  @rule_limit 100

  def enabled?, do: Repo.exists?(from r in CorrelationAutomationRule, where: r.enabled)

  def approved_rules([]), do: %{}

  def approved_rules(scopes) do
    sources = Enum.map(scopes, &Map.fetch!(&1, "source_id")) |> Enum.uniq()
    requested = MapSet.new(scopes)

    Repo.all(from r in CorrelationAutomationRule, where: r.enabled and r.source_id in ^sources)
    |> Enum.reduce(%{}, fn rule, approved ->
      scope = %{
        "source_id" => rule.source_id,
        "check_id" => rule.check_id,
        "output_key" => rule.output_key,
        "hint" => rule.hint
      }

      if MapSet.member?(requested, scope),
        do: Map.put(approved, scope, %{id: rule.id, revision: rule.revision}),
        else: approved
    end)
  end

  def rules do
    from(r in CorrelationAutomationRule, order_by: [r.source_id, r.check_id, r.output_key])
    |> Repo.all()
    |> Enum.map(&rule_view/1)
  end

  def set_rule(id, proposal, at \\ nil) do
    transact(fn ->
      id = uuid!(id)
      p = rule!(proposal)
      old = Repo.get(CorrelationAutomationRule, id)
      revision = if old, do: old.revision, else: 0
      if p["revision"] != revision, do: Repo.rollback(:review_changed)

      scope = Map.take(p, ~w(source_id check_id output_key))

      if old && Map.take(rule_view(old), Map.keys(scope)) != scope,
        do: invalid!("A rule's source, check and output are fixed.")

      occupied? =
        Repo.exists?(
          from r in CorrelationAutomationRule,
            where:
              r.source_id == ^p["source_id"] and r.check_id == ^p["check_id"] and
                r.output_key == ^p["output_key"] and r.id != ^id
        )

      if occupied?, do: invalid!("This output already has a rule.")

      if is_nil(old) && Repo.aggregate(CorrelationAutomationRule, :count) >= @rule_limit,
        do: invalid!("The installation already has 100 rules.")

      attrs = %{
        source_id: p["source_id"],
        check_id: p["check_id"],
        output_key: p["output_key"],
        hint: p["hint"],
        enabled: p["enabled"],
        revision: revision + 1,
        reason: p["reason"],
        updated_at: at || Monitoring.now()
      }

      if old do
        old |> Monitoring.change(attrs) |> rule_view()
      else
        %CorrelationAutomationRule{id: id}
        |> Ecto.Changeset.change(attrs)
        |> Repo.insert!()
        |> rule_view()
      end
    end)
  end

  defp rule!(
         %{"revision" => revision, "enabled" => enabled, "hint" => hint, "reason" => reason} = p
       ) do
    unless map_size(p) == 7 and is_integer(revision) and revision >= 0 and is_boolean(enabled) and
             Enum.all?(~w(source_id check_id output_key), &Parameters.text?(p[&1], 200)) and
             Protocol.correlation_hints?([hint]) and valid_reason?(reason),
           do: invalid!("Supply an exact source, check, output, hint, revision and reason.")

    p
  end

  defp rule!(_), do: invalid!("Supply a rule.")

  defp rule_view(row) do
    row
    |> Monitoring.public()
    |> Map.take(~w(id source_id check_id output_key hint enabled revision reason updated_at))
  end

  def overridden?(ref) do
    case row(ref) do
      %{active: true} -> true
      _ -> false
    end
  end

  def override(%{"type" => type, "id" => id} = ref) when type in ~w(individual condition) do
    case row(ref) do
      nil ->
        %{
          "subject" => %{"type" => type, "id" => id},
          "active" => false,
          "revision" => 0,
          "reason" => nil,
          "updated_at" => nil
        }

      state ->
        %{
          "subject" => ref,
          "active" => state.active and episode_open?(type, id),
          "revision" => state.revision,
          "reason" => state.reason,
          "updated_at" => Monitoring.iso(state.updated_at)
        }
    end
  end

  def override(_), do: nil

  defp episode_open?(type, id) do
    schema = if type == "condition", do: ConditionIncident, else: Incident
    Repo.exists?(from e in schema, where: e.id == ^id and e.status == "open")
  end

  # Caller already holds the exclusive topology gate and the episode's owner.
  def set_override!(ref, active, reason, at, request_id \\ nil) do
    attrs = %{active: active, reason: reason, updated_at: at, request_id: request_id}

    case row(ref) do
      nil ->
        %CorrelationAutomationOverride{}
        |> Ecto.Changeset.change(Map.merge(attrs, Map.put(endpoint(ref), :revision, 1)))
        |> Repo.insert!()

      old ->
        Monitoring.change(old, Map.put(attrs, :revision, old.revision + 1))
    end
  end

  def preview_override(proposal, at \\ nil) do
    transact(fn ->
      p = override_proposal!(proposal)
      state = override_state!(p, :preview)

      %{
        "proposal" => p,
        "override" => override(p["subject"]),
        "review_token" => Phoenix.Token.sign(MondekWeb.Endpoint, @salt, {p, state}),
        "as_of" => Monitoring.iso(at || Monitoring.now())
      }
    end)
  end

  def apply_override(token, at \\ nil)

  def apply_override(token, at) when is_binary(token) do
    result =
      case Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: 900) do
        {:ok, {p, expected}} ->
          transact(fn ->
            subject = p["subject"]
            request_id = p["request_id"]
            active = p["action"] == "keep_standalone"
            reason = p["reason"]

            case row(subject) do
              %{request_id: ^request_id, active: ^active, reason: ^reason} ->
                Map.put(override(subject), "replayed", true)

              %{request_id: ^request_id} ->
                Repo.rollback(:review_changed)

              _ ->
                if override_state!(p, :apply) != expected, do: Repo.rollback(:review_changed)
                set_override!(subject, active, reason, at || Monitoring.now(), request_id)
                if not active and enabled?(), do: CorrelationGrouping.enqueue_resume!(subject)
                Map.put(override(subject), "replayed", false)
            end
          end)

        {:error, :expired} ->
          {:error, :review_expired}

        _ ->
          {:error, :invalid_review}
      end

    if match?({:ok, %{"replayed" => false}}, result), do: Monitoring.notify()
    result
  end

  def apply_override(_, _), do: {:error, :invalid_review}

  defp override_state!(p, mode) do
    subject = p["subject"]
    CaseControls.lock_owners!([subject])

    episode =
      Repo.get(
        if(subject["type"] == "condition", do: ConditionIncident, else: Incident),
        subject["id"]
      )

    state = override(subject)
    action_blocks? = p["action"] == "keep_standalone"

    with %{status: "open"} <- episode,
         true <- is_nil(Map.get(episode, :condition_incident_id)),
         true <- is_nil(Correlations.membership(subject["type"], subject["id"])),
         true <- state["active"] != action_blocks? do
      state["revision"]
    else
      _ when mode == :apply -> Repo.rollback(:review_changed)
      _ -> invalid!("Choose an open standalone episode and a different override state.")
    end
  end

  defp override_proposal!(
         %{"action" => action, "subject" => ref, "request_id" => request, "reason" => reason} = p
       )
       when action in ~w(keep_standalone allow_grouping) and map_size(p) == 4 do
    unless valid_reason?(reason), do: invalid!("Provide a reason of at most 2000 bytes.")

    case ref do
      %{"type" => type, "id" => id}
      when type in ~w(individual condition) and map_size(ref) == 2 ->
        %{p | "subject" => %{"type" => type, "id" => uuid!(id)}, "request_id" => uuid!(request)}

      _ ->
        invalid!("Choose a canonical health episode.")
    end
  end

  defp override_proposal!(_), do: invalid!("Supply an override proposal.")

  defp row(ref), do: Repo.get_by(CorrelationAutomationOverride, Map.to_list(endpoint(ref)))
  defp endpoint(%{"type" => "individual", "id" => id}), do: %{incident_id: id}
  defp endpoint(%{"type" => "condition", "id" => id}), do: %{condition_id: id}

  defp transact(fun) do
    Repo.transaction(fn ->
      Correlations.lock!()
      fun.()
    end)
  end

  defp valid_reason?(reason),
    do:
      is_binary(reason) and byte_size(reason) <= 2000 and Protocol.json_text?(reason) and
        String.trim(reason) != ""

  defp uuid!(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      _ -> invalid!("Invalid identity.")
    end
  end

  defp invalid!(message), do: Repo.rollback({:invalid, message})
end

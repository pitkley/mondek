# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationProviderDecision do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "correlation_provider_decisions" do
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :subject_revision, :map
    field :provider_id, :string
    field :config_revision, :string
    field :request_bytes, :binary
    field :candidates, {:array, :map}
    field :resolved_at, :utc_datetime_usec
    field :requested_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :status, :string
    field :attempts, :integer, default: 0
    field :lease, Ecto.UUID
    field :leased_until, :utc_datetime_usec
    field :reply_digest, :string
    field :selected_handle, :string
    field :reason, :string
    field :confidence, :float
    field :case_id, Ecto.UUID
  end
end

defmodule Mondek.CorrelationProviderDecisions do
  @moduledoc "Durable proposals from an explicitly authorized correlation decision provider."
  import Ecto.Query

  alias Mondek.{
    CorrelationAutomationPolicy,
    CorrelationCandidates,
    Correlations,
    Monitoring,
    Repo
  }

  alias Mondek.CorrelationDecisionProvider, as: Provider
  alias Mondek.CorrelationProviderDecision, as: Decision
  alias Mondek.CorrelationProviderWorker, as: Worker

  @salt "provider-grouping-review-v1"
  @ttl 300
  @attempts 3

  def request(proposal, at \\ nil), do: request_bound(proposal, :current, at)

  def request_reviewed(proposal, fingerprint, at \\ nil)

  def request_reviewed(proposal, fingerprint, at) when is_binary(fingerprint),
    do: request_bound(proposal, fingerprint, at)

  def request_reviewed(_, _, _), do: {:error, :review_changed}

  defp request_bound(
         %{"request_id" => id, "subject" => %{"type" => type, "id" => episode} = ref} = p,
         expected,
         at
       )
       when map_size(p) == 2 and map_size(ref) == 2 and type in ~w(condition individual) do
    with {:ok, id} <- uuid(id), {:ok, episode} <- uuid(episode) do
      subject = %{"type" => type, "id" => episode}

      transaction(fn ->
        case Repo.get(Decision, id) do
          %Decision{subject_type: ^type, subject_id: ^episode} = row -> view(row)
          %Decision{} -> Repo.rollback(:review_changed)
          nil -> create!(id, subject, expected, at || Monitoring.now()) |> view()
        end
      end)
    end
  end

  defp request_bound(_, _, _), do: {:error, :invalid_request}

  defp create!(id, subject, expected, at) do
    config =
      case Provider.configuration() do
        {:ok, config} -> config
        _ when expected == :current -> Repo.rollback(:unavailable)
        _ -> Repo.rollback(:review_changed)
      end

    if expected != :current and Provider.fingerprint(config) != expected,
      do: Repo.rollback(:review_changed)

    pending = from d in Decision, where: d.status == "pending" and d.expires_at > ^at

    if Repo.exists?(
         from d in pending,
           where: d.subject_id == ^subject["id"] and d.subject_type == ^subject["type"]
       ),
       do: Repo.rollback(:already_pending)

    if Repo.exists?(from d in pending, offset: 99), do: Repo.rollback(:capacity)
    episode = open_episode(subject) || Repo.rollback(:episode_closed)
    search = search(subject)
    health? = "health" in config.evidence
    revision = eligibility(subject, :subject, health?)
    if is_nil(revision) or is_nil(search), do: Repo.rollback(:ineligible)

    candidates =
      for c <- search["candidates"],
          ref = Map.take(c, ~w(type id)),
          revision = eligibility(ref, :parent, health?),
          do: %{
            "ref" => ref,
            "revision" => revision,
            "handle" => Ecto.UUID.generate(),
            "matches" => c["matches"],
            "health" => c["health"]
          }

    expiry = DateTime.add(at, @ttl)

    payload = %{
      "version" => 1,
      "request_id" => id,
      "expires_at" => Monitoring.iso(expiry),
      "subject" => if("health" in config.evidence, do: %{"health" => episode.health}, else: %{}),
      "search" => Map.take(search, ~w(status conflicting_hints truncated)),
      "candidates" => Enum.map(candidates, &disclose(&1, config.evidence))
    }

    bytes = Jason.encode!(payload)
    if byte_size(bytes) > 32768, do: Repo.rollback(:too_large)

    row =
      Repo.insert!(%Decision{
        id: id,
        subject_id: subject["id"],
        subject_type: subject["type"],
        subject_revision: revision,
        provider_id: config.id,
        config_revision: Provider.fingerprint(config),
        request_bytes: bytes,
        candidates: candidates,
        requested_at: at,
        expires_at: expiry,
        status: "pending"
      })

    %{"request_id" => id} |> Worker.new() |> Oban.insert!()
    row
  end

  defp disclose(c, categories) do
    Enum.reduce(categories, Map.take(c, ["handle"]), fn
      "health", acc -> Map.put(acc, "health", c["health"])
      "dimensions", acc -> Map.put(acc, "dimensions", values(c, "dimension"))
      "timing", acc -> Map.put(acc, "timing", values(c, "timing"))
    end)
  end

  defp values(c, key),
    do: c["matches"] |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> Enum.sort()

  defp eligibility(%{"type" => type, "id" => id} = ref, role, health?) do
    with %{status: "open"} = episode <- open_episode(ref),
         %{"active" => false, "revision" => revision} <- CorrelationAutomationPolicy.override(ref) do
      membership = Correlations.membership(type, id)

      if role == :parent or is_nil(membership) do
        target =
          if membership do
            c = Repo.get!(Mondek.CorrelationCase, membership["case_id"])

            %{
              "case_id" => c.id,
              "revision" => c.revision,
              "topology_revision" => c.topology_revision
            }
          end

        %{
          "override" => revision,
          "case" => target,
          "attention_revision" => if(health?, do: episode.attention_revision)
        }
      end
    else
      _ -> nil
    end
  end

  defp open_episode(%{"type" => type, "id" => id}) do
    schema = if type == "individual", do: Mondek.Incident, else: Mondek.ConditionIncident

    case Repo.get(schema, id) do
      %Mondek.Incident{condition_incident_id: grouped} when not is_nil(grouped) -> nil
      %{status: "open"} = episode -> episode
      _ -> nil
    end
  end

  defp search(%{"type" => type, "id" => id} = ref) do
    case CorrelationCandidates.for_episode(type, id) do
      %{"subject" => ^ref} = search -> search
      _ -> nil
    end
  end

  defp subject(row), do: %{"type" => row.subject_type, "id" => row.subject_id}
  defp selected(row), do: Enum.find(row.candidates, &(&1["handle"] == row.selected_handle))

  defp view(row) do
    %{
      "request_id" => row.id,
      "subject" => subject(row),
      "provider_id" => row.provider_id,
      "status" => row.status,
      "reason" => row.reason,
      "confidence" => row.confidence,
      "selected" => get_in(selected(row), ["ref"]),
      "requested_at" => Monitoring.iso(row.requested_at),
      "resolved_at" => Monitoring.iso(row.resolved_at),
      "expires_at" => Monitoring.iso(row.expires_at),
      "case_id" => row.case_id
    }
  end

  def list(type, id, page \\ 1, at \\ Monitoring.now()) do
    page = if is_integer(page), do: min(max(page, 1), 10000), else: 1

    rows =
      with {:ok, uuid} <- uuid(id) do
        Repo.all(
          from d in Decision,
            where: d.subject_type == ^type and d.subject_id == ^uuid,
            order_by: [desc: d.requested_at, desc: d.id],
            limit: 21,
            offset: ^((page - 1) * 20)
        )
      else
        _ -> []
      end

    %{
      "page" => page,
      "has_more" => length(rows) > 20,
      "items" => Enum.take(rows, 20) |> Enum.map(&history(&1, at))
    }
  end

  defp history(%{status: s} = row, at) when s in ["pending", "proposed"] do
    status =
      cond do
        not DateTime.after?(row.expires_at, at) -> "expired"
        not match?({:ok, _}, approved(row)) -> "revoked"
        true -> s
      end

    view(%{row | status: status})
  end

  defp history(row, _), do: view(row)

  def admit(id, at \\ nil) do
    with_row(id, fn row ->
      at = at || Monitoring.now()

      cond do
        row.status != "pending" ->
          :done

        problem = invalidation(row, at) ->
          finish(row, problem, at)

        row.leased_until && DateTime.after?(row.leased_until, at) ->
          {:wait, DateTime.diff(row.leased_until, at) + 1}

        row.attempts >= @attempts ->
          finish(row, "unavailable", at)

        true ->
          case approved(row) do
            {:ok, config} ->
              lease = Ecto.UUID.generate()

              Monitoring.change(row, %{
                lease: lease,
                leased_until: DateTime.add(at, 30),
                attempts: row.attempts + 1
              })

              {:post, config, lease, row.request_bytes, row.expires_at}

            _ ->
              finish(row, "revoked", at)
          end
      end
    end)
  end

  def complete(id, lease, result, at \\ nil) do
    with_row(id, fn row ->
      at = at || Monitoring.now()

      digest =
        case result do
          {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 8192 ->
            Base.encode16(:crypto.hash(:sha256, bytes))

          _ ->
            nil
        end

      cond do
        row.reply_digest && digest == row.reply_digest ->
          view(row)

        row.reply_digest ->
          Repo.rollback(:conflicting_reply)

        row.status != "pending" ->
          view(row)

        is_nil(lease) or lease != row.lease ->
          Repo.rollback(:stale_attempt)

        problem = invalidation(row, at) ->
          finish(row, problem, at, digest)

        not DateTime.after?(row.leased_until, at) ->
          Repo.rollback(:stale_attempt)

        result == {:error, :retryable} and row.attempts < @attempts ->
          Monitoring.change(row, %{leased_until: nil, lease: nil})
          :retry

        result == {:error, :retryable} ->
          finish(row, "unavailable", at)

        is_nil(digest) ->
          finish(row, "invalid", at)

        true ->
          accept(row, elem(result, 1), digest, at)
      end
    end)
  end

  defp accept(row, bytes, digest, at) do
    with {:ok, %{"version" => 1, "request_id" => id, "outcome" => outcome} = reply} <-
           Jason.decode(bytes),
         true <- id == row.id and outcome in ~w(suggest standalone abstain),
         [] <- Map.keys(reply) -- ~w(version request_id outcome candidate reason confidence),
         true <- valid_reason?(reply) and valid_confidence?(reply),
         true <- candidate_valid?(row, outcome, reply) do
      status =
        %{"suggest" => "proposed", "standalone" => "standalone", "abstain" => "abstained"}[
          outcome
        ]

      row = %{row | selected_handle: reply["candidate"]}
      status = invalidation(row, at) || status

      Monitoring.change(Repo.get!(Decision, row.id), %{
        status: status,
        resolved_at: at,
        reply_digest: digest,
        selected_handle: row.selected_handle,
        reason: reply["reason"],
        confidence: if(is_number(reply["confidence"]), do: reply["confidence"] / 1),
        lease: nil,
        leased_until: nil
      })
      |> view()
    else
      _ -> finish(row, "invalid", at, digest)
    end
  end

  defp valid_reason?(%{"reason" => reason}) do
    with true <-
           is_binary(reason) and byte_size(reason) in 1..512 and
             Mondek.Protocol.json_text?(reason),
         {:ok, config} <- Provider.configuration() do
      not Enum.any?(
        [config.binding_key, config.bearer_token],
        &(is_binary(&1) and String.contains?(reason, &1))
      )
    else
      _ -> false
    end
  end

  defp valid_reason?(_), do: true
  defp valid_confidence?(%{"confidence" => n}), do: is_number(n) and n >= 0 and n <= 1
  defp valid_confidence?(_), do: true

  defp candidate_valid?(row, "suggest", reply),
    do: Enum.any?(row.candidates, &(&1["handle"] == reply["candidate"]))

  defp candidate_valid?(_, _, reply), do: not Map.has_key?(reply, "candidate")

  defp approved(row) do
    with {:ok, c} <- Provider.configuration(),
         true <- Provider.fingerprint(c) == row.config_revision do
      {:ok, c}
    else
      _ -> {:error, :revoked}
    end
  end

  defp invalidation(row, at) do
    ref = subject(row)

    cond do
      not DateTime.after?(row.expires_at, at) ->
        "expired"

      not match?({:ok, _}, approved(row)) ->
        "revoked"

      eligibility(ref, :subject, not is_nil(row.subject_revision["attention_revision"])) !=
          row.subject_revision ->
        "stale"

      row.selected_handle && not current_candidate?(row) ->
        "stale"

      true ->
        nil
    end
  end

  defp current_candidate?(row) do
    c = selected(row)
    current = search(subject(row))

    c && current &&
      eligibility(c["ref"], :parent, not is_nil(c["revision"]["attention_revision"])) ==
        c["revision"] &&
      Enum.any?(
        current["candidates"],
        &(Map.take(&1, ~w(type id)) == c["ref"] and &1["matches"] == c["matches"])
      )
  end

  defp finish(row, status, at, digest \\ nil) do
    row
    |> Monitoring.change(%{
      status: status,
      resolved_at: at,
      lease: nil,
      leased_until: nil,
      reply_digest: digest
    })
    |> view()
  end

  def preview(id, at \\ nil) do
    with_review(id, at, fn row, at ->
      candidate = selected(row)
      parent = candidate["ref"]

      proposal =
        case candidate["revision"]["case"] do
          nil ->
            %{
              "action" => "create",
              "episodes" => [parent, subject(row)],
              "anchor" => parent,
              "title" => "Correlated health episodes"
            }

          %{"case_id" => case_id} ->
            %{"action" => "attach", "episodes" => [subject(row)], "case_id" => case_id}
        end
        |> Map.merge(%{
          "request_id" => row.id,
          "reason" => "Reviewed proposal from " <> row.provider_id
        })

      review = unwrap!(Correlations.preview_provider(proposal, at))

      Map.put(
        review,
        "review_token",
        Phoenix.Token.sign(MondekWeb.Endpoint, @salt, {row.id, review["review_token"]})
      )
    end)
  end

  def apply(token, at \\ nil)

  def apply(token, at) when is_binary(token) and byte_size(token) < 16384 do
    with {:ok, {id, native}} <-
           Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: @ttl) do
      with_review(
        id,
        at,
        fn row, at ->
          result = unwrap!(Correlations.apply_provider(native, at))
          Monitoring.change(row, %{status: "applied", case_id: result["case_id"]})
          result
        end,
        true
      )
    end
  end

  def apply(_, _), do: {:error, :invalid_review}

  defp with_review(id, clock, fun, replay? \\ false) do
    result =
      with_row(id, fn row ->
        if row.status == "proposed" do
          candidate = selected(row)
          case_ids = List.wrap(get_in(candidate, ["revision", "case", "case_id"]))
          Correlations.lock_episode_owners!(case_ids, [subject(row), candidate["ref"]])
        end

        at = clock || Monitoring.now()

        cond do
          replay? and row.status == "applied" ->
            %{"case_id" => row.case_id, "replayed" => true}

          row.status != "proposed" ->
            Repo.rollback(:not_reviewable)

          problem = invalidation(row, at) ->
            Monitoring.change(row, %{status: problem})
            {:invalidated, if(problem == "expired", do: :review_expired, else: :review_changed)}

          true ->
            fun.(row, at)
        end
      end)

    case result do
      {:ok, {:invalidated, reason}} -> {:error, reason}
      other -> other
    end
  end

  def prune!(cutoff, limit) do
    ids =
      from d in Decision,
        where: d.expires_at < ^cutoff,
        order_by: d.expires_at,
        limit: ^limit,
        select: d.id

    {count, _} = Repo.delete_all(from d in Decision, where: d.id in subquery(ids))
    count
  end

  defp uuid(id) when is_binary(id) and byte_size(id) == 36 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      _ -> {:error, :invalid_request}
    end
  end

  defp uuid(_), do: {:error, :invalid_request}

  defp with_row(id, fun) do
    with {:ok, id} <- uuid(id) do
      transaction(fn -> fun.(Repo.get(Decision, id) || Repo.rollback(:not_found)) end)
    end
  end

  defp transaction(fun),
    do:
      Repo.transaction(fn ->
        Correlations.lock!()
        fun.()
      end)

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end

defmodule Mondek.CorrelationProviderWorker do
  use Oban.Worker, queue: :provider_decisions, max_attempts: 20
  alias Mondek.{CorrelationDecisionProvider, CorrelationProviderDecisions, Monitoring}

  @impl true
  def perform(%Oban.Job{args: %{"request_id" => id}}) do
    case CorrelationProviderDecisions.admit(id) do
      {:ok, {:post, config, lease, bytes, expires}} ->
        remaining = DateTime.diff(expires, Monitoring.now(), :millisecond)

        result =
          with {:ok, fresh} <- CorrelationDecisionProvider.configuration(),
               true <-
                 CorrelationDecisionProvider.fingerprint(fresh) ==
                   CorrelationDecisionProvider.fingerprint(config),
               true <- remaining > 0 do
            CorrelationDecisionProvider.post(fresh, id, bytes, min(remaining, 29000))
          else
            _ -> {:error, :retryable}
          end

        case CorrelationProviderDecisions.complete(id, lease, result) do
          {:ok, :retry} -> {:snooze, 3}
          {:error, :stale_attempt} -> {:snooze, 1}
          _ -> :ok
        end

      {:ok, {:wait, seconds}} ->
        {:snooze, seconds}

      _ ->
        :ok
    end
  end
end

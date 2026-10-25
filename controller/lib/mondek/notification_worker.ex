# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationWorker do
  @moduledoc "Durable at-least-once notification delivery; an attempt starts before external I/O."
  use Oban.Worker, queue: :notifications, max_attempts: 100
  import Ecto.Query
  alias Mondek.{Repo, Monitoring, Conditions, Occurrence, Attempt}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def backoff(%Oban.Job{args: %{"delivery_channel" => "smtp"}, attempt: attempt}),
    do: min(900, 30 * attempt)

  def backoff(%Oban.Job{attempt: attempt}), do: min(30, attempt * 2)
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"occurrence_id" => id}} = job) do
    case begin_attempt(id, nil, job) do
      {:ok, :superseded} ->
        :ok

      {:ok, :delivered} ->
        :ok

      {:ok, {:gated, seconds}} ->
        {:snooze, seconds}

      {:ok, {occurrence, attempt}} ->
        # Delivery is deliberately outside the database transaction. Crash after this point
        # leaves a visible ambiguous "started" attempt; Oban Lifeline rescues the job.
        result = Mondek.NotificationDelivery.deliver(occurrence)

        finish_attempt(
          occurrence,
          attempt,
          result,
          Monitoring.now(),
          job.attempt >= job.max_attempts
        )

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def begin_attempt(id, at, job \\ nil) do
    Repo.transaction(fn ->
      Mondek.Maintenance.lock!(:shared)
      occurrence = Repo.get!(Occurrence, id)
      context = Monitoring.lock_delivery_context!(occurrence, at)
      occurrence = Repo.one!(from o in Occurrence, where: o.id == ^id, lock: "FOR UPDATE")
      # Production dispatch samples the clock after lock waits; tests may inject
      # a controlled instant to exercise exact boundaries.
      at = at || Monitoring.now()

      eligibility = Monitoring.delivery_context_eligibility(occurrence, context, at)

      if job && job.id && not match?({:gated, _, _}, eligibility),
        do:
          Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
            set: [args: Map.delete(job.args, "mondek_hold_revision")]
          )

      case eligibility do
        :delivered ->
          :delivered

        :superseded ->
          Monitoring.change(occurrence, %{status: "superseded"})
          :superseded

        {:gated, _gates, until} ->
          if job && job.id do
            # Oban overwrites meta while snoozing; args retain our durable gate
            # revision so a concurrent cancellation cannot strand a long hold.
            Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
              set: [args: Map.put(job.args, "mondek_hold_revision", occurrence.gate_revision)]
            )
          end

          seconds =
            if until,
              do: max(1, div(DateTime.diff(until, at, :microsecond) + 999_999, 1_000_000)),
              else: 86_400

          {:gated, min(86_400, seconds)}

        :eligible ->
          attempt = Repo.insert!(%Attempt{occurrence_id: id, status: "started", started_at: at})
          occurrence = Monitoring.change(occurrence, %{status: "delivering"})
          {occurrence, attempt}
      end
    end)
  end

  defp finish_attempt(occurrence, attempt, result, at, exhausted?) do
    {success?, status, error} =
      case result do
        {:ok, :smtp} -> {true, nil, nil}
        {:ok, {{_, code, _}, _, _}} when code in 200..299 -> {true, code, nil}
        {:ok, {{_, code, _}, _, _}} -> {false, code, "Receiver rejected delivery"}
        {:error, reason} -> {false, nil, failure_message(reason)}
      end

    Repo.transaction(fn ->
      # Individual delivery locks its assignment; grouped delivery locks the
      # condition identity and never takes another observer's assignment lock.
      context = Monitoring.lock_delivery_context!(occurrence, at)
      current = Repo.one!(from o in Occurrence, where: o.id == ^occurrence.id, lock: "FOR UPDATE")

      Monitoring.change(attempt, %{
        status: if(success?, do: "accepted", else: "failed_or_ambiguous"),
        http_status: status,
        error: error,
        finished_at: at
      })

      # A rescued execution may finish after a newer attempt was accepted.
      # Retain each attempt's result without erasing known delivery or its time.
      unless current.status in ["superseded", "delivered"],
        do:
          Monitoring.change(current, %{
            status:
              cond do
                success? -> "delivered"
                exhausted? -> "exhausted"
                true -> "retrying"
              end,
            delivered_at: if(success?, do: at, else: nil)
          })

      if context.kind == :condition do
        if success?, do: Conditions.delivery_accepted!(current, at)
        Conditions.request_gate_wake!(context.incident.id)
      end
    end)

    Monitoring.notify()
    if success?, do: :ok, else: {:error, error}
  end

  defp failure_message(:smtp_authentication_rejected), do: "SMTP authentication was rejected"

  defp failure_message(:smtp_authentication_unavailable),
    do: "SMTP relay does not offer the required authentication"

  defp failure_message(:smtp_tls_required),
    do: "SMTP relay does not offer the required TLS encryption"

  defp failure_message(:smtp_tls_rejected),
    do: "SMTP TLS negotiation or certificate verification failed"

  defp failure_message(:smtp_connection_refused), do: "SMTP connection was refused"

  defp failure_message(:smtp_timeout_or_ambiguous),
    do: "SMTP attempt timed out; relay acceptance is uncertain"

  defp failure_message(:smtp_configuration_unavailable),
    do: "SMTP configuration is unavailable for this queued notification"

  defp failure_message(:smtp_rejected_or_unavailable),
    do: "SMTP relay rejected delivery or the connection failed; acceptance may be uncertain"

  defp failure_message(reason), do: inspect(reason, limit: 20, printable_limit: 300)
end

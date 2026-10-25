# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.NotificationDelivery do
  @moduledoc "Immutable notification addressing and bounded, credential-safe transport."

  @mailbox ~r/\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/

  def validate_config!(options) do
    valid_host? =
      is_binary(options[:host]) && byte_size(options[:host]) in 1..253 &&
        Regex.match?(~r/\A[a-zA-Z0-9.:-]+\z/, options[:host])

    username = options[:username]
    password = options[:password]
    credentials? = is_binary(username) && username != "" && is_binary(password) && password != ""
    anonymous? = is_nil(username) && is_nil(password)

    unless valid_host? && valid_mailbox?(options[:from]) && valid_mailbox?(options[:to]) &&
             options[:port] in 1..65_535 && options[:transport] in [:plain, :starttls, :tls] &&
             options[:timeout_ms] in 1000..30_000 && (anonymous? || credentials?) &&
             (anonymous? || options[:transport] != :plain) do
      raise ArgumentError,
            "Invalid SMTP configuration: require host, one bare sender/recipient address, valid port/timeout, and paired credentials with TLS"
    end

    options
  end

  def snapshot(payload, label, summary, measured_health) do
    if Application.get_env(:mondek, :notification_adapter, :webhook) == :smtp do
      options = Application.fetch_env!(:mondek, :smtp)

      metadata = %{
        "from" => options[:from],
        "public_url" => Application.get_env(:mondek, :public_url) || MondekWeb.Endpoint.url(),
        "label" => label,
        "summary" => summary,
        "measured_health" => measured_health
      }

      destination = "mailto:" <> options[:to]
      payload = Map.put(payload, "email", metadata)
      {:ok, inserted_at, _} = DateTime.from_iso8601(payload["created_at"])

      # Persist the rendered message as well as its provenance. A later code
      # upgrade must not rewrite an already attempted notification on retry.
      frozen =
        message(%{
          payload: payload,
          id: payload["occurrence_id"],
          destination: destination,
          inserted_at: inserted_at
        })

      {put_in(payload, ["email", "message"], frozen), destination}
    else
      {payload, Application.fetch_env!(:mondek, :webhook_url)}
    end
  end

  def deliver(%{destination: "mailto:" <> recipient} = occurrence) do
    options = Application.get_env(:mondek, :smtp)
    metadata = occurrence.payload["email"] || %{}

    if options && valid_mailbox?(recipient) && valid_mailbox?(metadata["from"]) do
      email = {metadata["from"], [recipient], message(occurrence)}

      # Disable the library's own retries: every network attempt must have its
      # own committed database record. Linking also stops I/O if its owner dies.
      task =
        Task.async(fn ->
          # Bound hostile multi-line replies as well as elapsed time. A killed
          # task also terminates its linked Oban execution, leaving the committed
          # attempt ambiguous and recoverable, without logging process contents.
          Process.flag(:max_heap_size, %{
            size: 2_000_000,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          try do
            case :gen_smtp_client.send_blocking(email, smtp_options(options)) do
              receipt when is_binary(receipt) -> {:ok, :smtp}
              result -> {:error, smtp_error(result)}
            end
          catch
            _, _ -> {:error, :smtp_rejected_or_unavailable}
          end
        end)

      case Task.yield(task, options[:timeout_ms]) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :smtp_timeout_or_ambiguous}
      end
    else
      {:error, :smtp_configuration_unavailable}
    end
  end

  def deliver(occurrence) do
    uri = URI.parse(occurrence.destination)

    if uri.scheme == "http" and uri.host in ["target", "127.0.0.1", "localhost", "::1"] and
         is_nil(uri.userinfo) do
      :httpc.request(
        :post,
        {String.to_charlist(occurrence.destination),
         [{~c"x-mondek-occurrence", String.to_charlist(occurrence.id)}], ~c"application/json",
         Jason.encode!(occurrence.payload)},
        [timeout: 3000, connect_timeout: 1000, autoredirect: false],
        body_format: :binary
      )
    else
      {:error, :nonlocal_destination}
    end
  end

  @doc "The same occurrence always renders the same message, including its Message-ID."
  def message(%{payload: %{"email" => %{"message" => frozen}}}) when is_binary(frozen), do: frozen

  def message(occurrence) do
    payload = occurrence.payload
    metadata = payload["email"]
    recipient = String.replace_prefix(occurrence.destination, "mailto:", "")
    health = payload["health"] || payload["group_health_at_creation"] || "UNKNOWN"
    heading = heading(payload)
    label = metadata["label"] || payload["result_key"] || "Monitoring condition"

    subject_health =
      case heading do
        "MONITORING LOST" -> ""
        "MONITORING RESTORED" -> ""
        "RECOVERED" -> " #{metadata["measured_health"] || "OK"}"
        "CLOSED" -> ""
        _ -> " #{health}"
      end

    subject = "[Mondek] #{heading}#{subject_health}: #{label}" |> String.slice(0, 180)

    incident_id =
      payload["monitoring_incident_id"] || payload["condition_incident_id"] ||
        payload["incident_id"]

    incident_path =
      if payload["incident_type"] == "monitoring_loss",
        do: "/monitoring-incidents/",
        else: "/incidents/"

    url = String.trim_trailing(metadata["public_url"], "/") <> incident_path <> incident_id
    target = payload["target"] || %{}

    body =
      [
        "#{heading}: #{label}",
        severity_line(payload, health),
        if(heading == "RECOVERED",
          do: "Recovery measurement: #{metadata["measured_health"] || "OK"}"
        ),
        if(payload["incident_type"] != "monitoring_loss",
          do:
            "Environment: #{payload["environment_label"] || payload["environment"] || "Unspecified"}"
        ),
        if(map_size(target) > 0, do: "Target: #{target["label"] || target["key"]}"),
        monitoring_scope(payload),
        monitoring_restoration(payload),
        metadata["summary"] && "\n#{metadata["summary"]}",
        closure(payload),
        "\nOpen incident: #{url}",
        "\nNotification created: #{payload["created_at"]}",
        if(payload["incident_type"] != "monitoring_loss",
          do: "Measurement source time: #{payload["source_at"] || "Unavailable"}"
        ),
        "Notification ID: #{occurrence.id}",
        if(payload["incident_type"] == "monitoring_loss",
          do:
            "\nThis is a snapshot. Open the incident for current monitoring coverage and affected results. Target health remains separate.",
          else:
            "\nThis is a snapshot. Open the incident for current health and contributing checks."
        ),
        "Retries preserve this notification ID; duplicate delivery is possible."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.slice(0, 24_000)

    [
      "From: #{metadata["from"]}",
      "To: #{recipient}",
      "Date: #{mail_date(occurrence.inserted_at)}",
      "Subject: #{encoded_subject(subject)}",
      "Message-ID: <#{occurrence.id}@mondek.invalid>",
      "X-Mondek-Occurrence: #{occurrence.id}",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: base64",
      "",
      body
      |> Base.encode64()
      |> String.codepoints()
      |> Enum.chunk_every(76)
      |> Enum.map_join("\r\n", &Enum.join/1),
      ""
    ]
    |> Enum.join("\r\n")
  end

  defp valid_mailbox?(value),
    do: is_binary(value) && byte_size(value) in 3..254 && Regex.match?(@mailbox, value)

  # Never return peer-supplied response text: relays may echo AUTH material or
  # other secrets. These atoms are safe to persist in both attempts and Oban.
  defp smtp_error({:error, _, {:permanent_failure, _, :auth_failed}}),
    do: :smtp_authentication_rejected

  defp smtp_error({:error, _, {:missing_requirement, _, :auth}}),
    do: :smtp_authentication_unavailable

  defp smtp_error({:error, _, {:missing_requirement, _, :tls}}),
    do: :smtp_tls_required

  defp smtp_error({:error, _, {:temporary_failure, _, :tls_failed}}), do: :smtp_tls_rejected

  defp smtp_error({:error, _, {:network_failure, _, {:error, {:tls_alert, _}}}}),
    do: :smtp_tls_rejected

  defp smtp_error({:error, _, {:network_failure, _, {:error, :econnrefused}}}),
    do: :smtp_connection_refused

  defp smtp_error(_), do: :smtp_rejected_or_unavailable

  defp severity_line(%{"incident_type" => "monitoring_loss", "kind" => "resolved"}, _health),
    do: "This monitoring episode ended. Target-health incidents remain independent."

  defp severity_line(%{"incident_type" => "monitoring_loss"}, _health),
    do: "Monitoring visibility is affected; this is not a measured target-health failure."

  defp severity_line(%{"kind" => "resolved"}, health), do: "Previous incident severity: #{health}"
  defp severity_line(_, health), do: "Incident severity at notification creation: #{health}"

  defp monitoring_scope(%{"incident_type" => "monitoring_loss"} = payload) do
    members = Enum.take(payload["member_snapshot"] || [], 20)

    rows =
      Enum.map_join(members, "\n", fn member ->
        target = member["target"] || %{}

        "- #{member["label"] || member["key"]}: #{monitoring_reason(member["knowledge"])} · #{target["label"] || target["key"] || "Target not declared"} · #{member["environment"] || "Environment not declared"}"
      end)

    count = payload["member_count"] || length(members)

    excerpt =
      if count > length(members),
        do:
          "\nShowing #{length(members)} of #{count} affected results. Open the incident for current membership.",
        else: ""

    "Affected results in this notification: #{count}\n" <> rows <> excerpt
  end

  defp monitoring_scope(_), do: nil

  defp monitoring_restoration(
         %{"incident_type" => "monitoring_loss", "closure_reason" => "monitoring_restored"} =
           payload
       ) do
    times =
      (payload["closing_evidence"] || [])
      |> Enum.map(& &1["source_at"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.take(3)

    if times != [],
      do:
        "Restoration measurement source times (sample): #{Enum.join(times, ", ")}. Open the incident for retained evidence."
  end

  defp monitoring_restoration(_), do: nil

  defp monitoring_reason("control_contact_overdue"), do: "Control contact overdue"
  defp monitoring_reason("awaiting_new_measurement"), do: "Awaiting a new measurement"
  defp monitoring_reason("awaiting_coverage_measurement"), do: "Awaiting coverage measurement"
  defp monitoring_reason("no_selected_runner"), do: "No selected runner"
  defp monitoring_reason("stale"), do: "Overdue"
  defp monitoring_reason("awaiting"), do: "Awaiting measurement"
  defp monitoring_reason("unavailable"), do: "Unavailable"
  defp monitoring_reason(_), do: "Measurement unavailable"

  defp heading(%{
         "incident_type" => "monitoring_loss",
         "kind" => "resolved",
         "closure_reason" => "monitoring_restored"
       }),
       do: "MONITORING RESTORED"

  defp heading(%{"incident_type" => "monitoring_loss", "kind" => "resolved"}), do: "CLOSED"
  defp heading(%{"incident_type" => "monitoring_loss"}), do: "MONITORING LOST"
  defp heading(%{"kind" => "resolved", "closure_reason" => "measured_recovery"}), do: "RECOVERED"
  defp heading(%{"kind" => "resolved"}), do: "CLOSED"
  defp heading(%{"kind" => "update"}), do: "UPDATED"
  defp heading(%{"requested_fact" => %{"kind" => "impact"}}), do: "UPDATED"
  defp heading(_), do: "PROBLEM"

  defp closure(%{
         "incident_type" => "monitoring_loss",
         "kind" => "resolved",
         "closure_reason" => "monitoring_restored"
       }),
       do:
         "\nClosure: Fresh measurements restored monitoring. This does not establish healthy targets."

  defp closure(%{"incident_type" => "monitoring_loss", "kind" => "resolved"}),
    do:
      "\nClosure: Monitoring scope withdrawn. This administrative closure does not establish restored monitoring or target recovery."

  defp closure(%{"kind" => "resolved", "closure_reason" => "measured_recovery"}),
    do: "\nClosure: Measured recovery."

  defp closure(%{"kind" => "resolved", "closure_reason" => "configuration_changed"}),
    do:
      "\nClosure: Configuration changed. This does not establish recovery under the previous settings."

  defp closure(%{"kind" => "resolved"} = payload),
    do:
      "\nClosure: #{String.replace(payload["closure_reason"] || "see incident history", "_", " ")}. Recovery was not established for all contributing checks."

  defp closure(_), do: nil

  defp mail_date(at), do: Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S +0000")

  defp encoded_subject(value) do
    {chunks, last} =
      Enum.reduce(String.codepoints(value), {[], ""}, fn point, {chunks, current} ->
        if byte_size(current <> point) > 42,
          do: {[current | chunks], point},
          else: {chunks, current <> point}
      end)

    [last | chunks]
    |> Enum.reverse()
    |> Enum.map_join("\r\n ", &("=?UTF-8?B?" <> Base.encode64(&1) <> "?="))
  end

  defp smtp_options(options) do
    tls_options = [
      verify: :verify_peer,
      packet_size: 8192,
      cacerts: :public_key.cacerts_get(),
      depth: 10,
      server_name_indication: String.to_charlist(options[:host]),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    [
      relay: String.to_charlist(options[:host]),
      port: options[:port],
      hostname: ~c"mondek",
      no_mx_lookups: true,
      retries: 0,
      timeout: min(options[:timeout_ms], 5000),
      tls: if(options[:transport] == :starttls, do: :always, else: :never),
      ssl: options[:transport] == :tls,
      tls_options: tls_options,
      sockopts: [packet_size: 8192] ++ if(options[:transport] == :tls, do: tls_options, else: []),
      auth: if(options[:username], do: :always, else: :never)
    ] ++
      if(options[:username],
        do: [username: options[:username], password: options[:password]],
        else: []
      )
  end
end

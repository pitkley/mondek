# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.WebhookNotification do
  @moduledoc "One active webhook destination, with immutable non-secret delivery snapshots."
  alias Mondek.NotificationTemplate
  @max_body 262_144

  def load!(path) do
    try do
      %{mode: mode} = File.stat!(path)
      true = Bitwise.band(mode, 0o077) == 0
      raw = read_json!(path, 65_536)
      true = Map.keys(raw) |> Enum.sort() == ["active", "destinations"]
      %{"active" => active, "destinations" => destinations} = raw
      true = is_map(destinations) and map_size(destinations) in 1..16

      destinations =
        Map.new(destinations, fn {id, options} ->
          true =
            Enum.all?(
              Map.keys(options),
              &(&1 in ["url", "headers", "timeout_ms", "template", "cacertfile"])
            )

          true = Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, id)
          true = not Regex.match?(~r/[\x00-\x20\x7f]/, options["url"])
          uri = URI.new!(options["url"])

          true =
            is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
              is_nil(uri.fragment)

          true =
            uri.scheme == "https" or
              (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1", "localhost"])

          true = uri.port in 1..65_535
          headers = options["headers"] || %{}
          true = is_map(headers) and map_size(headers) <= 16
          names = Enum.map(Map.keys(headers), &String.downcase/1)
          true = length(Enum.uniq(names)) == length(names)

          true =
            Enum.all?(headers, fn {key, value} ->
              Regex.match?(~r/\A[a-zA-Z0-9!#$%&'*+.^_`|~-]+\z/, key) and
                String.downcase(key) not in [
                  "host",
                  "content-type",
                  "content-length",
                  "transfer-encoding",
                  "connection",
                  "x-mondek-occurrence"
                ] and
                is_binary(value) and byte_size(value) <= 8192 and
                not Regex.match?(~r/[\x00-\x1f\x7f]/, value)
            end)

          timeout = Map.get(options, "timeout_ms", 10_000)
          true = is_integer(timeout) and timeout in 1000..30_000

          template =
            case options["template"] do
              nil ->
                nil

              "teams" ->
                NotificationTemplate.load!(teams_path())

              file when is_binary(file) ->
                NotificationTemplate.load!(Path.expand(file, Path.dirname(path)))
            end

          for document <- Map.values(examples()), do: render!(template, document)
          ca = options["cacertfile"]

          true =
            is_nil(ca) or (is_binary(ca) and File.regular?(Path.expand(ca, Path.dirname(path))))

          {id,
           %{
             url: options["url"],
             headers: headers,
             timeout_ms: timeout,
             template: template,
             cacertfile: ca && Path.expand(ca, Path.dirname(path))
           }}
        end)

      true = Map.has_key?(destinations, active)
      %{active: active, destinations: destinations}
    rescue
      _ ->
        raise ArgumentError,
              "Invalid webhook configuration; check destination, headers, timeout and template files"
    end
  end

  @doc "Synthetic normalized documents for local previews and startup template validation."
  def examples do
    for {event, extra} <- [
          {"problem", %{"kind" => "firing", "health" => "CRIT"}},
          {"updated", %{"kind" => "update", "health" => "WARN"}},
          {"recovered",
           %{"kind" => "resolved", "health" => "CRIT", "closure_reason" => "measured_recovery"}},
          {"closed", %{"kind" => "resolved", "closure_reason" => "configuration_changed"}},
          {"monitoring_lost",
           %{"incident_type" => "monitoring_loss", "kind" => "firing", "member_count" => 3}},
          {"monitoring_restored",
           %{
             "incident_type" => "monitoring_loss",
             "kind" => "resolved",
             "closure_reason" => "monitoring_restored",
             "member_count" => 3
           }}
        ],
        into: %{} do
      payload =
        Map.merge(
          %{
            "occurrence_id" => "00000000-0000-4000-8000-000000000001",
            "incident_id" => "00000000-0000-4000-8000-000000000002",
            "created_at" => "2026-01-01T00:00:00Z",
            "source_at" => "2026-01-01T00:00:00Z",
            "environment" => "Example",
            "target" => %{"key" => "example", "label" => "Example target", "kind" => "node"}
          },
          extra
        )

      payload =
        if event in ["monitoring_lost", "monitoring_restored"],
          do: Map.merge(payload, %{"source_at" => nil, "target" => nil, "environment" => nil}),
          else: payload

      {event,
       document(
         payload,
         "Example condition",
         "Example finding",
         if(event == "recovered", do: "OK", else: nil),
         "https://mondek.example.invalid"
       )}
    end
  end

  def teams_path, do: Application.app_dir(:mondek, "priv/notification_templates/teams.json")

  defp read_json!(path, limit) do
    %{type: :regular, size: size} = File.stat!(path)
    true = size <= limit
    Jason.decode!(File.read!(path))
  end

  def document(payload, label, summary, measured_health, public_url) do
    monitoring? = payload["incident_type"] == "monitoring_loss"

    id =
      payload["monitoring_incident_id"] || payload["condition_incident_id"] ||
        payload["incident_id"]

    heading = Mondek.NotificationDelivery.heading(payload)

    %{
      "version" => 1,
      "notification" => %{
        "id" => payload["occurrence_id"],
        "event" => heading |> String.downcase() |> String.replace(" ", "_"),
        "title" => heading <> ": " <> bounded(label, 240),
        "summary" => bounded(summary, 4000),
        "created_at" => payload["created_at"]
      },
      "incident" => %{
        "id" => id,
        "type" => if(monitoring?, do: "monitoring_loss", else: "health"),
        "url" =>
          String.trim_trailing(public_url, "/") <>
            if(monitoring?, do: "/monitoring-incidents/", else: "/incidents/") <> id,
        "closure_reason" => payload["closure_reason"]
      },
      "evidence" => %{
        "health" =>
          if(monitoring?, do: nil, else: payload["health"] || payload["group_health_at_creation"]),
        "measured_health" => measured_health,
        "display_health" =>
          if(heading == "RECOVERED",
            do: measured_health || "OK",
            else:
              if(monitoring?,
                do: nil,
                else: payload["health"] || payload["group_health_at_creation"]
              )
          ),
        "source_at" => payload["source_at"],
        "environment" => payload["environment_label"] || payload["environment"],
        "target" => target(payload["target"]),
        "scope" =>
          if(monitoring?,
            do: "#{payload["member_count"] || 0} affected monitoring result(s)",
            else: "See incident for contributing checks"
          ),
        "affected_count" => payload["member_count"]
      },
      "notice" =>
        if(monitoring?,
          do:
            "Monitoring coverage is separate from target health. This is a snapshot; open the incident for current evidence.",
          else:
            "This is a snapshot. Administrative closure does not establish measured recovery; open the incident for current evidence."
        )
    }
  end

  defp target(nil), do: nil

  defp target(value),
    do: %{
      "key" => value["key"],
      "kind" => value["kind"],
      "label" => bounded(value["label"] || value["key"], 512)
    }

  defp bounded(value, limit), do: String.slice(value || "", 0, limit)

  def snapshot(payload, label, summary, measured_health) do
    config = Application.fetch_env!(:mondek, :webhook)
    destination = Map.fetch!(config.destinations, config.active)
    public_url = Application.get_env(:mondek, :public_url) || MondekWeb.Endpoint.url()
    document = document(payload, label, summary, measured_health, public_url)

    {body, render_error} =
      try do
        {render!(destination.template, document), false}
      rescue
        _ -> {nil, true}
      end

    envelope = %{
      "version" => 1,
      "destination_id" => config.active,
      "destination_hash" => fingerprint(destination.url),
      "document" => document,
      "body" => body,
      "render_error" => render_error,
      "content_type" => "application/json"
    }

    {Map.put(payload, "webhook_delivery", envelope), "webhook:" <> config.active}
  end

  def render!(nil, document) do
    body = Jason.encode!(document)
    if byte_size(body) > @max_body, do: raise(ArgumentError, "Webhook body exceeds limit")
    body
  end

  def render!(template, document), do: NotificationTemplate.render!(template, document)

  def deliver(occurrence) do
    envelope = occurrence.payload["webhook_delivery"]
    config = Application.get_env(:mondek, :webhook)
    destination = config && config.destinations[envelope["destination_id"]]

    cond do
      envelope["render_error"] ->
        {:error, :webhook_template_failed}

      destination && fingerprint(destination.url) == envelope["destination_hash"] ->
        request(destination, occurrence.id, envelope["body"])

      true ->
        {:error, :webhook_configuration_unavailable}
    end
  end

  defp fingerprint(url), do: :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)

  defp retry_after(headers) do
    value =
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(to_string(key)) == "retry-after", do: to_string(value)
      end)

    case value && Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> min(900, max(30, seconds))
      _ -> 30
    end
  end

  defp request(destination, id, body) do
    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{
          size: 2_000_000,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        try do
          case Mondek.WebhookHTTP.post(destination, id, body) do
            {:ok, code, response_headers} when code in [429, 503] ->
              {:error, {:webhook_retry_after, code, retry_after(response_headers)}}

            {:ok, code, _} ->
              {:ok, {{~c"HTTP/1.1", code, ~c""}, [], ""}}

            _ ->
              {:error, :webhook_transport_failed}
          end
        catch
          _, _ -> {:error, :webhook_transport_failed}
        end
      end)

    case Task.yield(task, destination.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :webhook_timeout_or_ambiguous}
    end
  end
end

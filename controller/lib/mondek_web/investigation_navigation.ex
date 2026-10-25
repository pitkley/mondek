# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.InvestigationNavigation do
  @moduledoc "Bounded result and incident investigation URLs; nested returns retain domain-specific allowlists."
  alias MondekWeb.{CheckNavigation, NotificationNavigation}

  def filter_path(:checks, filters), do: CheckNavigation.path(filters)

  def filter_path(mode, filters) do
    base =
      case mode do
        :configuration -> "/configuration"
        :incidents -> "/incidents"
        :runners -> "/runners"
        :notifications -> "/notifications"
        _ -> "/checks"
      end

    query =
      filters |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  def inventory_params(params, mode) when mode in [:notifications, :notification],
    do: NotificationNavigation.filters(params)

  def inventory_params(params, :checks), do: CheckNavigation.normalize(params)

  def inventory_params(params, mode) do
    params
    |> Map.take(
      ~w(search runner_id environment health freshness status configuration_stage page notification_status notification_page)
    )
    |> Map.merge(result_page_size_filter(params, mode))
    |> Map.merge(if(mode == :incident, do: condition_filters(params), else: %{}))
  end

  defp condition_filters(params) do
    params
    |> Map.take(
      ~w(state page contradiction_page notification_status notification_page notification_id)
    )
    |> Enum.filter(fn {_key, value} ->
      (is_binary(value) && byte_size(value) <= 128) || is_integer(value)
    end)
    |> Map.new()
  end

  def condition_path(id, filters, return_to) do
    query = condition_filters(filters)
    query = if return_to, do: Map.put(query, "return_to", return_to), else: query
    query = URI.encode_query(query)
    "/incidents/" <> id <> if(query == "", do: "", else: "?" <> query)
  end

  def parent_incident_path(incident, return_to) do
    path = "/incidents/" <> (incident["condition_incident_id"] || incident["id"])

    if return_to && URI.parse(return_to).path == path,
      do: return_to,
      else: detail_path(path, return_to)
  end

  def parent_notification_path(incident, return_to) do
    uri = incident |> parent_incident_path(return_to) |> URI.parse()

    query =
      URI.decode_query(uri.query || "")
      |> Map.drop(["notification_page", "notification_id"])
      |> Map.put("notification_status", "all")
      |> URI.encode_query()

    URI.to_string(%{uri | query: query, fragment: "incident-occurrences"})
  end

  def condition_page_filters(filters, field, page, projection) do
    filters =
      if field == "notification_page",
        do:
          filters
          |> Map.delete("notification_id")
          |> Map.put("notification_status", projection["status"]),
        else: filters

    Map.put(filters, field, page)
  end

  def result_page_size(value) when value in ["10", "25", "100"], do: value
  def result_page_size(_), do: "50"

  def result_page_size_filter(filters, :checks) do
    case result_page_size(filters["page_size"]) do
      "50" -> %{}
      size -> %{"page_size" => size}
    end
  end

  def result_page_size_filter(_, _), do: %{}

  def comparable_inventory_filters(filters, mode) do
    fields =
      ~w(search runner_id environment status) ++
        case mode do
          :checks -> ~w(health freshness)
          :configuration -> ~w(configuration_stage)
          _ -> []
        end

    filters
    |> Map.take(fields)
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
    |> Map.put_new("status", default_status(mode))
  end

  # A result may return through measurement diagnostics and one shared incident
  # to a canonical inventory. Only inventory destinations remain after an incident.
  def safe_return_path(value), do: safe_return_path(value, 0)

  defp safe_return_path(value, depth) when is_binary(value) and byte_size(value) <= 8_192 do
    uri = URI.parse(value)

    if uri.scheme == nil && uri.host == nil && uri.fragment == nil do
      params = URI.decode_query(uri.query || "")

      cond do
        uri.path == "/" ->
          "/"

        depth in [0, 1] && is_binary(uri.path) && String.starts_with?(uri.path, "/notifications") ->
          NotificationNavigation.return_path(value)

        depth in [0, 1] && is_binary(uri.path) && String.starts_with?(uri.path, "/runners") ->
          MondekWeb.RunnerNavigation.return_path(value)

        depth in [0, 1] && is_binary(uri.path) &&
            String.starts_with?(uri.path, "/monitoring-incidents/") ->
          MondekWeb.MonitoringIncidentNavigation.return_path(value)

        depth == 0 && is_binary(uri.path) &&
            Regex.match?(~r"\A/(checks|resources)/[a-zA-Z0-9_-]{1,128}/diagnostics\z", uri.path) ->
          detail_path(uri.path, safe_return_path(params["return_to"], depth + 1))

        depth in [0, 1] && is_binary(uri.path) &&
            Regex.match?(~r"\A/(checks|resources)/[a-zA-Z0-9_-]{1,128}\z", uri.path) ->
          detail_path(uri.path, safe_return_path(params["return_to"], depth + 1))

        uri.path == "/coverage" ||
            (is_binary(uri.path) && Regex.match?(~r"\A/coverage/[a-f0-9]{64}\z", uri.path)) ->
          MondekWeb.CoverageNavigation.return_path(value)

        uri.path in ["/checks", "/configuration", "/incidents", "/runners"] ->
          mode =
            case uri.path do
              "/configuration" -> :configuration
              "/incidents" -> :incidents
              "/runners" -> :runners
              _ -> :checks
            end

          filter_path(mode, inventory_return_filters(params, mode))

        depth in [0, 1] && is_binary(uri.path) && String.starts_with?(uri.path, "/incidents/") ->
          id = String.replace_prefix(uri.path, "/incidents/", "")

          case Ecto.UUID.cast(id) do
            {:ok, id} ->
              condition_path(id, params, safe_return_path(params["return_to"], 2))

            :error ->
              nil
          end

        true ->
          nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  defp safe_return_path(_, _), do: nil

  defp inventory_return_filters(filters, :checks), do: CheckNavigation.normalize(filters)

  defp inventory_return_filters(filters, :runners),
    do: Map.take(filters, ~w(runner_id notification_status notification_page))

  defp inventory_return_filters(filters, mode),
    do:
      filters
      |> Map.take(
        ~w(search runner_id environment health freshness status configuration_stage page)
      )
      |> Map.merge(result_page_size_filter(filters, mode))

  def detail_path(path, nil), do: path

  def detail_path(path, return_to),
    do: path <> "?" <> URI.encode_query(%{"return_to" => return_to})

  def return_label(nil, fallback), do: fallback

  def return_label(path, _fallback) do
    case URI.parse(path).path do
      "/" ->
        "Back to overview"

      "/configuration" ->
        "Back to scheduled checks"

      "/incidents" ->
        "Back to incidents"

      "/notifications" ->
        "Back to notifications"

      "/runners" ->
        "Back to runners"

      path ->
        cond do
          String.starts_with?(path || "", "/notifications/") ->
            "Back to notification"

          String.starts_with?(path || "", "/runners/") ->
            "Back to runner"

          String.starts_with?(path || "", "/monitoring-incidents/") ->
            "Back to monitoring incident"

          String.ends_with?(path || "", "/diagnostics") ->
            "Back to investigation"

          String.starts_with?(path || "", "/checks/") ->
            "Back to result"

          String.starts_with?(path || "", "/resources/") ->
            "Back to check"

          String.starts_with?(path || "", "/coverage") ->
            "Back to coverage"

          String.starts_with?(path || "", "/incidents/") ->
            "Back to incident"

          true ->
            "Back to results"
        end
    end
  end

  defp default_status(:incidents), do: "open"
  defp default_status(_), do: "active"
end

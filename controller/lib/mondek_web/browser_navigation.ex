# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BrowserNavigation do
  @moduledoc "Bounded local browser return destinations, validated against the actual LiveView router."
  alias MondekWeb.{InvestigationTrail, Router}

  @keys ~w(search runner_id source_id environment target_kind target_key health freshness status group type severity acknowledgement opened grouping page healthy_page expected_page diagnostic_page coverage_observer_page coverage_entity notification_status notification_page notification_event notification_type notification_channel decisions_page relationships_page member_page inspect surface page_entity sort page_size contact collection lifecycle configuration_stage target_scope selection proposal candidate_page enabled ownership schema_search diagnostics assignment_id stream_id check_id occurrence_page result_page selected_page change history_page event_id event_page evidence_id schema_from copy_series)

  @return_depth 4

  def return_path(value), do: return_path(value, @return_depth)

  defp return_path(value, depth) when is_binary(value) and byte_size(value) <= 8192 do
    with true <- String.valid?(value) && !String.contains?(value, [<<0>>, "\\", "\r", "\n"]),
         %URI{scheme: nil, authority: nil, host: nil, userinfo: nil, fragment: nil, path: path} =
           uri <- URI.parse(value),
         true <-
           is_binary(path) && String.starts_with?(path, "/") && !String.starts_with?(path, "//"),
         %{plug: Phoenix.LiveView.Plug} = route <-
           Phoenix.Router.route_info(Router, "GET", path, nil),
         true <- valid_identity?(route),
         params <- URI.decode_query(uri.query || ""),
         {:ok, trail} <- InvestigationTrail.parse(params["inspect"]),
         true <- scalar_params?(params),
         true <- valid_page?(params, trail) do
      nested = if depth > 0, do: return_path(params["return_to"], depth - 1)
      allowed = Map.take(params, @keys)
      allowed = if nested, do: Map.put(allowed, "return_to", nested), else: allowed

      query =
        allowed
        |> Map.reject(fn {key, value} -> key != "inspect" && value == "" end)
        |> Enum.sort()
        |> URI.encode_query()

      normalized = path <> if(query == "", do: "", else: "?" <> query)
      if byte_size(normalized) <= 8192, do: normalized
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp return_path(_, _), do: nil

  defp valid_identity?(%{path_params: %{"id" => id}, route: route}) do
    cond do
      String.starts_with?(route, ["/coverage/publishers/", "/coverage/diagnostics/"]) ->
        case Integer.parse(id) do
          {number, ""} -> number > 0 && number <= 9_223_372_036_854_775_807
          _ -> false
        end

      String.starts_with?(route, ["/coverage/:id", "/expected/:id"]) ->
        !is_nil(InvestigationTrail.identity({"coverage", id}))

      true ->
        match?({:ok, _}, Ecto.UUID.cast(id))
    end
  end

  defp valid_identity?(_), do: true

  defp scalar_params?(params),
    do:
      Enum.all?(params, fn {key, value} ->
        is_binary(value) && !String.contains?(key, ["[", "]"]) &&
          (key in ["inspect", "return_to"] || byte_size(value) <= 800)
      end)

  defp valid_page?(%{"page_entity" => value} = params, trail) do
    identity = InvestigationTrail.from_token(value)
    params["surface"] == "page" && !is_nil(identity) && identity in trail
  end

  defp valid_page?(%{"surface" => "page"}, _), do: false
  defp valid_page?(params, _), do: params["surface"] in [nil, ""]
end

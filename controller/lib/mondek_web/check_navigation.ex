# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckNavigation do
  @moduledoc "Canonical result inventory filters and bounded investigation return state."
  @tabs ~w(all attention critical gaps)
  @preferences ~w(all_view attention_view critical_view gaps_view)
  @scope_fields ~w(search runner_id environment health freshness status)
  @fields ~w(search runner_id environment health freshness attention status page page_size target target_page target_scope group_search group_limit)

  def normalize(params) do
    filters =
      params
      |> Map.take(@fields)
      |> Map.filter(fn {_, value} -> is_binary(value) && byte_size(value) <= 200 end)

    filters =
      if params["target_scope"] not in [nil, ""] &&
           (!is_binary(params["target_scope"]) ||
              !Regex.match?(~r/\Atarget-[a-f0-9]{64}\z/, params["target_scope"])) do
        Map.put(filters, "target_scope", "invalid-target")
      else
        filters
      end

    filters =
      if filters["target_scope"] == "", do: Map.delete(filters, "target_scope"), else: filters

    filters =
      if filters["page_size"] in ~w(10 25 100),
        do: filters,
        else: Map.delete(filters, "page_size")

    filters =
      case Integer.parse(filters["group_limit"] || "") do
        {limit, ""} when limit > 100 ->
          Map.put(filters, "group_limit", to_string(min(limit, 1000)))

        _ ->
          Map.delete(filters, "group_limit")
      end

    filters =
      if filters["health"] in [nil, "", "OK", "WARN", "CRIT", "not_measured"],
        do: filters,
        else: Map.delete(filters, "health")

    filters =
      if filters["freshness"] in [nil, "", "fresh", "stale", "unavailable", "awaiting", "gaps"],
        do: filters,
        else: Map.delete(filters, "freshness")

    preferences =
      Map.take(params, @preferences) |> Map.filter(fn {_, v} -> v in ~w(list targets) end)

    tab = if params["tab"] in (@tabs ++ ["custom"]), do: params["tab"], else: infer_tab(filters)

    view =
      if params["view"] in ~w(list targets),
        do: params["view"],
        else: preferences[tab <> "_view"] || default_view(tab)

    filters
    |> Map.merge(preferences)
    |> Map.merge(runner_origin(params))
    |> Map.merge(investigation_origin(params))
    |> Map.put("tab", tab)
    |> Map.put("view", view)
    |> apply_tab(tab)
  end

  defp investigation_origin(params) do
    if params["target_scope"] not in [nil, ""] do
      case investigation_return(params["investigation_return"]) do
        nil -> %{}
        value -> %{"investigation_return" => value}
      end
    else
      %{}
    end
  end

  def investigation_return(value) when is_binary(value) and byte_size(value) <= 4_096 do
    uri = URI.parse(value)
    params = URI.decode_query(uri.query || "")

    if uri.path == "/checks" && uri.scheme == nil && uri.host == nil && uri.fragment == nil &&
         params["target_scope"] in [nil, ""] && params["investigation_return"] in [nil, ""] do
      params |> normalize() |> path()
    end
  rescue
    ArgumentError -> nil
  end

  def investigation_return(_), do: nil

  def target_context_path(target_id, filters, retain_investigation \\ true) do
    original =
      if retain_investigation,
        do: filters["investigation_return"] || investigation_return(path(filters)),
        else: nil

    filters
    |> Map.take(@preferences ++ ~w(page_size status return_to))
    |> Map.merge(%{
      "target_scope" => target_id,
      "tab" => "all",
      "view" => "list",
      "investigation_return" => original
    })
    |> path()
  end

  def leave_target_path(filters),
    do:
      filters |> Map.drop(~w(target_scope investigation_return target page target_page)) |> path()

  defp runner_origin(params) do
    case MondekWeb.RunnerNavigation.return_path(params["return_to"]) do
      nil -> %{}
      path -> %{"return_to" => path}
    end
  end

  def path(filters) do
    query =
      filters
      |> Enum.reject(fn {_, value} -> value in [nil, ""] end)
      |> Enum.sort()
      |> URI.encode_query()

    "/checks" <> if(query == "", do: "", else: "?" <> query)
  end

  def change_tab(filters, tab) when tab in @tabs do
    filters
    |> Map.drop(~w(page target_page group_limit health freshness attention))
    |> Map.put("tab", tab)
    |> Map.put("view", filters[tab <> "_view"] || default_view(tab))
    |> apply_tab(tab)
  end

  def change_tab(filters, _), do: filters

  def change_view(filters, view) when view in ~w(list targets) do
    tab = filters["tab"] || infer_tab(filters)
    filters = filters |> Map.delete("page") |> Map.put("view", view)
    if tab in @tabs, do: Map.put(filters, tab <> "_view", view), else: filters
  end

  def change_view(filters, _), do: filters

  def change_scope(filters, params) do
    # A change event includes the entire browser form, which may predate an
    # in-flight tab patch. Apply only the edited control; submits without a
    # target still apply the complete reviewed form.
    changes =
      case params["_target"] do
        [field] when field in @scope_fields -> Map.take(params, [field])
        nil -> Map.take(params, @scope_fields)
        _ -> %{}
      end

    updated = Map.merge(filters, changes)

    changed_health = Enum.any?(~w(health freshness), &(blank(updated[&1]) != blank(filters[&1])))

    updated =
      if changed_health,
        do:
          updated
          |> Map.delete("attention")
          |> Map.put("tab", infer_tab(Map.delete(updated, "attention"))),
        else: updated

    updated |> Map.drop(~w(page target_page group_limit))
  end

  def clear_scope(filters),
    do: Map.drop(filters, ~w(search runner_id environment page target_page group_limit))

  def clear_all(filters),
    do:
      filters
      |> Map.take(@preferences ++ ~w(page_size return_to target_scope investigation_return))
      |> change_tab("all")

  def view(filters), do: filters["view"] || default_view(filters["tab"] || infer_tab(filters))

  defp blank(value), do: if(value in [nil, ""], do: "", else: value)
  defp default_view("all"), do: "targets"
  defp default_view(_), do: "list"

  defp infer_tab(f) do
    cond do
      f["health"] == "CRIT" && f["freshness"] in [nil, ""] -> "critical"
      f["freshness"] == "gaps" && f["health"] in [nil, ""] -> "gaps"
      f["attention"] in [true, "true"] -> "attention"
      Enum.any?(~w(health freshness), &(f[&1] not in [nil, ""])) -> "custom"
      true -> "all"
    end
  end

  defp apply_tab(f, "all"), do: Map.drop(f, ~w(health freshness attention))

  defp apply_tab(f, "critical"),
    do: f |> Map.drop(~w(freshness attention)) |> Map.put("health", "CRIT")

  defp apply_tab(f, "attention"),
    do: f |> Map.drop(~w(health freshness)) |> Map.put("attention", "true")

  defp apply_tab(f, "gaps"),
    do: f |> Map.drop(~w(health attention)) |> Map.put("freshness", "gaps")

  defp apply_tab(f, _), do: f
end

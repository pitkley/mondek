# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConsumerStateLive do
  use MondekWeb, :live_view
  alias Mondek.{ConsumerState, Monitoring}
  alias MondekWeb.{PreviewLayouts, PreviewDetail, PreviewFilters, PreviewPagination}
  @fields [{"source_id", "Source", "code"}, {"scope", "Scope", "sliders"}]

  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2000)
    {:ok, assign(socket, page_title: "Consumer state", picker: nil, filters: %{}, selected: nil)}
  end

  def handle_params(params, _, socket) do
    filters = Map.take(params, ~w(source_id scope key page id))
    {:noreply, socket |> assign(filters: filters, picker: nil) |> refresh()}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2000)
    {:noreply, refresh(socket)}
  end

  def handle_event("search", %{"search" => key}, socket),
    do: patch_filters(socket, %{"key" => key})

  def handle_event("filter_open", %{"field" => field}, socket) when field in ~w(source_id scope),
    do: {:noreply, assign(socket, picker: picker(field, ""))}

  def handle_event(event, %{"search" => value}, %{assigns: %{picker: %{field: field}}} = socket)
      when event in ["filter_query", "filter_first"] do
    draft = picker(field, String.slice(value, 0, 200))

    case {event, draft.options} do
      {"filter_first", [first | _]} -> patch_filters(socket, %{field => first.key})
      _ -> {:noreply, assign(socket, picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: patch_filters(socket, %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event("filter_remove_edit", %{"field" => field}, socket)
      when field in ~w(source_id scope), do: patch_filters(socket, %{field => nil})

  def handle_event("filter_remove", %{"field" => "search"}, socket),
    do: patch_filters(socket, %{"key" => nil})

  def handle_event("filter_remove", %{"field" => field}, socket)
      when field in ~w(source_id scope), do: patch_filters(socket, %{field => nil})

  def handle_event("filter_close", _, socket),
    do:
      {:noreply,
       socket
       |> assign(picker: nil)
       |> push_event("preview-filter-ready", %{id: "consumer-state-filters"})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp picker(field, query) do
    %{
      field: field,
      value: query,
      title: "Select #{field}",
      options: ConsumerState.filter_options(field, query)
    }
  end

  defp patch_filters(socket, changes) do
    filters = socket.assigns.filters |> Map.drop(~w(page id)) |> Map.merge(changes)

    {:noreply,
     socket
     |> push_event("preview-filter-ready", %{id: "consumer-state-filters"})
     |> push_patch(to: url(filters))}
  end

  defp url(params),
    do:
      "/consumer-state?" <> URI.encode_query(Enum.reject(params, fn {_, v} -> v in [nil, ""] end))

  defp refresh(socket) do
    at = ConsumerState.now()

    selected =
      case Ecto.UUID.cast(socket.assigns.filters["id"]) do
        {:ok, id} ->
          case ConsumerState.get(id, at) do
            {:ok, value} -> value
            _ -> nil
          end

        _ ->
          nil
      end

    data = ConsumerState.list(socket.assigns.filters, at)

    chips =
      for {field, name, _} <- @fields,
          value = socket.assigns.filters[field],
          value not in [nil, ""],
          do: %{field: field, name: name, label: value}

    assign(socket, data: data, selected: selected, chips: chips, fields: @fields)
  end

  def render(assigns) do
    ~H"""
    <PreviewLayouts.app active={:consumer_state} page_title={@page_title} flash={@flash}>
      <section class="preview-list consumer-state" aria-labelledby="state-heading">
        <header class="preview-heading">
          <h1 id="state-heading" class="pf-v6-c-title pf-m-2xl">Consumer state</h1>
        </header>
        <p>
          Current shared monitoring data. Values are visible to operators; do not store secrets. Expired and retired assignment-local values are unavailable.
        </p>
        <PreviewFilters.filter_picker
          id="consumer-state-filters"
          picker={@picker}
          chips={@chips}
          fields={@fields}
          search={@filters["key"] || ""}
          form_label="Filter consumer state"
          label="Exact key"
          placeholder="Find an exact key or filter by source and scope"
        />
        <p :if={@data.usage}>
          Source storage: {@data.usage.bytes} / {@data.limits.source_bytes} accounted bytes; {@data.usage.entries} / {@data.limits.source_entries} entries, including unswept storage.
        </p>
        <p :if={@data.items == []}>No current state keys match.</p>
        <ul class="state-entry-list">
          <li :for={entry <- @data.items}>
            <.link patch={url(Map.put(@filters, "id", entry.id))}><strong>{entry.key}</strong></.link>
            <span>Source: {entry.source_id}</span><span>Scope: {entry.scope}</span>
            <span>Updated: {Monitoring.iso(entry.updated_at)}</span>
            <span>Expires: {if entry.expires_at, do: Monitoring.iso(entry.expires_at), else: "No TTL"}</span>
          </li>
        </ul>
        <PreviewPagination.pagination
          page={@data.page}
          size={@data.page_size}
          total={@data.total}
          label="State pages"
          url={fn page -> url(Map.put(@filters, "page", page)) end}
        />
        <p :if={@filters["id"] && !@selected} role="status">
          Selected key is unavailable, expired, deleted or retired.
        </p>
        <PreviewDetail.card :if={@selected} id="state-value" title={@selected.key} level={2}>
          <PreviewDetail.facts label="State provenance">
            <tr>
              <th scope="row">Source</th><td>{@selected.source_id}</td>
            </tr>
            <tr>
              <th scope="row">Scope</th><td>{@selected.scope}</td>
            </tr>
            <tr>
              <th scope="row">Version</th><td>{@selected.version}</td>
            </tr>
            <tr>
              <th scope="row">Updated</th><td>{Monitoring.iso(@selected.updated_at)}</td>
            </tr>
            <tr>
              <th scope="row">Expiry</th><td>
                {if @selected.expires_at, do: Monitoring.iso(@selected.expires_at), else: "No TTL"}
              </td>
            </tr>
            <tr>
              <th scope="row">Writer installation</th><td>{@selected.installation_id}</td>
            </tr>
            <tr>
              <th scope="row">Writer session</th><td>{@selected.session_id}</td>
            </tr>
            <tr>
              <th scope="row">Writer assignment</th><td>
                {@selected.assignment_id} · generation {@selected.generation}
              </td>
            </tr>
          </PreviewDetail.facts>
          <h3>Current JSON value</h3><pre class="state-json">{Jason.encode!(@selected.value, pretty: true)}</pre>
        </PreviewDetail.card>
      </section>
    </PreviewLayouts.app>
    """
  end
end

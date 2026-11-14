# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PublicationInventoryLive do
  use MondekWeb, :live_view
  alias Mondek.{Coverage, Monitoring, ObserverFilters, OverviewFilters}

  alias MondekWeb.{
    BrowserNavigation,
    InvestigationStack,
    InvestigationTrail,
    PreviewFilters,
    PreviewLayouts,
    PreviewPagination,
    ScalarFilterPicker
  }

  @fields [
    {"lifecycle", "Lifecycle", "info"},
    {"source_id", "Source", "code"},
    {"runner_id", "Runner", "terminal"},
    {"environment", "Environment", "globe"}
  ]
  @lifecycles [
    {"active", "Active publications"},
    {"awaiting_inventory", "Waiting for inventory"},
    {"retired", "Retired publications"},
    {"all", "Any lifecycle"}
  ]

  @impl true
  def mount(_, _, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 2_000)

    {:ok,
     assign(socket,
       page_title: "Source publications",
       filters: %{},
       filter_picker: nil,
       now: Monitoring.now()
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    local = URI.parse(uri)
    filters = filters(params)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       filter_picker: if(filters == socket.assigns.filters, do: socket.assigns.filter_picker),
       raw_params: params,
       current: local.path <> if(local.query, do: "?" <> local.query, else: ""),
       return_to: BrowserNavigation.return_path(params["return_to"]),
       investigation_selection: InvestigationTrail.selection(params),
       promoted: !is_nil(InvestigationTrail.promoted(params))
     )
     |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 2_000)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("search", %{"search" => value}, socket),
    do: apply_filters(socket, %{"search" => ScalarFilterPicker.text(value)})

  def handle_event("filter_open", %{"field" => field}, socket) do
    case picker(field, "") do
      nil ->
        {:noreply, socket}

      draft ->
        {:noreply,
         assign(socket,
           filter_picker: %{draft | value: selected_label(socket.assigns.filters, field)}
         )}
    end
  end

  def handle_event("filter_close", %{"reopen" => true}, socket), do: {:noreply, ready(socket)}
  def handle_event("filter_close", _, socket), do: {:noreply, assign(socket, filter_picker: nil)}

  def handle_event(
        "filter_remove_edit",
        _,
        %{assigns: %{filter_picker: %{field: field}}} = socket
      ),
      do: apply_filters(ready(socket), %{field => if(field == "lifecycle", do: "all", else: "")})

  def handle_event(
        event,
        %{"search" => value},
        %{assigns: %{filter_picker: %{field: field}}} = socket
      )
      when event in ["filter_query", "filter_first"] do
    draft = picker(field, value)

    case {event, draft.options} do
      {"filter_first", [option | _]} -> apply_filters(ready(socket), %{field => option.key})
      _ -> {:noreply, assign(socket, filter_picker: draft)}
    end
  end

  def handle_event(
        "filter_select",
        %{"key" => key},
        %{assigns: %{filter_picker: %{field: field, options: options}}} = socket
      ) do
    if Enum.any?(options, &(&1.key == key)),
      do: apply_filters(ready(socket), %{field => key}),
      else: {:noreply, socket}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp refresh(socket) do
    now = Monitoring.now()
    listing = Coverage.publishers(socket.assigns.filters, now)

    assign(socket,
      now: now,
      listing: listing,
      fields: @fields,
      chips: chips(socket.assigns.filters)
    )
  end

  defp ready(socket),
    do: socket |> assign(filter_picker: nil) |> push_event("preview-filter-ready", %{})

  defp apply_filters(socket, changes) do
    current = socket.assigns.filters
    next = current |> Map.merge(changes) |> filters()

    if Map.drop(current, ["page"]) == Map.drop(next, ["page"]),
      do: {:noreply, socket},
      else: {:noreply, push_patch(socket, to: path(Map.delete(next, "page")))}
  end

  defp filters(params) do
    values =
      for key <- ~w(search source_id runner_id environment),
          value = params[key],
          is_binary(value) && byte_size(value) <= 800 && String.valid?(value) &&
            !String.contains?(value, <<0>>) && value != "",
          into: %{},
          do: {key, String.slice(value, 0, 200)}

    values =
      Map.put(
        values,
        "lifecycle",
        if(List.keymember?(@lifecycles, params["lifecycle"], 0),
          do: params["lifecycle"],
          else: "active"
        )
      )

    case params["page"] do
      page when is_binary(page) and byte_size(page) <= 10 ->
        case Integer.parse(page) do
          {number, ""} when number > 1 -> Map.put(values, "page", min(number, 100_000))
          _ -> values
        end

      page when is_integer(page) and page > 1 ->
        Map.put(values, "page", min(page, 100_000))

      _ ->
        values
    end
  end

  def path(filters) do
    query = filters |> filters() |> Enum.sort() |> URI.encode_query()
    "/coverage/publishers" <> if(query == "", do: "", else: "?" <> query)
  end

  defp picker(field, query) do
    case List.keyfind(@fields, field, 0) do
      nil ->
        nil

      {_, label, _} ->
        %{
          field: field,
          title: label,
          value: ScalarFilterPicker.text(query),
          options: options(field, ScalarFilterPicker.text(query))
        }
    end
  end

  defp options("lifecycle", query),
    do:
      for(
        {key, label} <- @lifecycles,
        key != "all" && String.contains?(String.downcase(label), String.downcase(query)),
        do: %{key: key, label: label, kind: "", show_key: false}
      )

  defp options(field, query) when field in ~w(runner_id source_id),
    do: ObserverFilters.options(field, query)

  defp options("environment", query), do: OverviewFilters.options("environment", query)

  defp selected_label(filters, "lifecycle"),
    do: ScalarFilterPicker.label(@lifecycles, filters["lifecycle"])

  defp selected_label(filters, field) when field in ~w(runner_id source_id) do
    if value = filters[field] do
      case ObserverFilters.options(field, "", {value, ""}) do
        [option | _] -> option.label
        _ -> value
      end
    else
      ""
    end
  end

  defp selected_label(filters, "environment") do
    if value = filters["environment"] do
      case OverviewFilters.options("environment", "", {value, ""}) do
        [option | _] -> option.label
        _ -> value
      end
    else
      ""
    end
  end

  defp chips(filters),
    do:
      for(
        {field, name, _} <- @fields,
        filters[field] not in [nil, ""] && !(field == "lifecycle" && filters[field] == "all"),
        do: %{field: field, name: name, label: selected_label(filters, field)}
      )

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="preview-shell"
      id="publications-shell"
      phx-hook="OverviewPanel"
      data-selection={@investigation_selection}
      data-panel-heading={InvestigationTrail.heading(@raw_params, "publications-heading")}
    >
      <PreviewLayouts.navigation active={:coverage} />
      <main id="main-content" class="preview-main" tabindex="-1">
        <section
          class="preview-list publication-inventory"
          hidden={@promoted}
          inert={@promoted}
          aria-labelledby="publications-heading"
        >
          <header class="preview-heading">
            <h1 id="publications-heading" tabindex="-1" class="pf-v6-c-title pf-m-2xl">
              Source publications
            </h1><.link navigate={@return_to || "/coverage"} class="pf-v6-c-button pf-m-link">Back to Coverage</.link>
          </header>
          <p class="publication-message">
            Each row is one runner publishing one source. Lost contact does not withdraw monitoring. Retirement and replacement require a reviewed decision.
          </p>
          <div class="publication-filter-toolbar">
            <PreviewFilters.filter_picker
              picker={@filter_picker}
              chips={@chips}
              fields={@fields}
              search={@filters["search"]}
              remove={
                fn field ->
                  path(
                    @filters
                    |> Map.put(field, if(field == "lifecycle", do: "all", else: ""))
                    |> Map.delete("page")
                  )
                end
              }
              clear_search={path(Map.delete(@filters, "search") |> Map.delete("page"))}
              form_label="Filter source publications"
              label="Search source publications"
              placeholder="Search or filter publications"
            />
          </div>
          <section
            id="coverage-publishers"
            class="preview-table-group"
            tabindex="-1"
            aria-label="Matching source publications"
          >
            <h2 class="preview-section-heading">{@listing["total"]} matching publications</h2>
            <p :if={@listing["items"] == []} class="preview-empty">
              No matching publications. Change the filters, or <.link navigate="/guide">set up a runner</.link>.
            </p>
            <table
              :if={@listing["items"] != []}
              class="pf-v6-c-table pf-m-compact preview-table publication-inventory-table"
              aria-label="Source publications"
            >
              <thead class="pf-v6-c-table__thead">
                <tr>
                  <th scope="col" class="pf-v6-c-table__th">Runner / source</th><th
                    scope="col"
                    class="pf-v6-c-table__th"
                  >
                    Lifecycle
                  </th><th scope="col" class="pf-v6-c-table__th">Declarations</th><th
                    scope="col"
                    class="pf-v6-c-table__th"
                  >
                    Last contact
                  </th><th scope="col" class="pf-v6-c-table__th">Actions</th>
                </tr>
              </thead><tbody>
                <tr :for={publisher <- @listing["items"]} data-publisher-id={publisher["id"]}>
                  <td class="pf-v6-c-table__td" data-label="Runner / source">
                    <.link
                      navigate={detail_path(publisher["id"], path(@filters))}
                      class="preview-result-link"
                    >{publisher["runner_label"] || publisher["runner_id"]}</.link><span class="preview-caption publication-secondary">{publisher[
                      "source_id"
                    ]}</span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Lifecycle">
                    <span class={[
                      "pf-v6-c-label",
                      if(publisher["lifecycle_status"] == "active",
                        do: "pf-m-green",
                        else:
                          if(publisher["lifecycle_status"] == "awaiting_inventory",
                            do: "pf-m-orange",
                            else: ""
                          )
                      )
                    ]}><span class="pf-v6-c-label__content">{lifecycle_label(
                      publisher["lifecycle_status"]
                    )}</span></span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Declarations">
                    {publisher["declarations"] - publisher["unbound"]} resolved · {publisher[
                      "unbound"
                    ]} unresolved<span class="preview-caption publication-secondary">{audit_label(
                      publisher["audit_status"]
                    )}<span :if={publisher["lifecycle_status"] != "active"}> · retained history</span></span>
                  </td>
                  <td class="pf-v6-c-table__td" data-label="Last contact">
                    <time datetime={publisher["last_seen_at"]}>{MondekWeb.EvidencePresentation.age(
                      publisher["last_seen_at"],
                      @now
                    )}</time>
                  </td>
                  <td class="pf-v6-c-table__td publication-links" data-label="Actions">
                    <.link navigate={detail_path(publisher["id"], path(@filters))}>Manage publication</.link><.link
                      :if={publisher["lifecycle_status"] == "active"}
                      navigate={"/coverage?" <> URI.encode_query(%{"runner_id" => publisher["runner_id"], "source_id" => publisher["source_id"]})}
                    >Declared scopes</.link><.link
                      patch={InvestigationTrail.path(@current, [{"runner", publisher["runner_id"]}])}
                      id={"publication-runner-" <> to_string(publisher["id"])}
                      data-overview-open
                    >Inspect runner</.link>
                  </td>
                </tr>
              </tbody>
            </table>
            <PreviewPagination.pagination
              page={@listing["page"]}
              size={@listing["page_size"]}
              total={@listing["total"]}
              label="Source publication pages"
              url={fn page -> path(Map.put(@filters, "page", page)) end}
            />
          </section>
        </section>
        <.live_component
          module={InvestigationStack}
          id="investigation-stack"
          host={@current}
          params={@raw_params}
          now={@now}
          root={nil}
          initial={[]}
          context="publications"
          back={path(@filters)}
        />
        <div class="preview-connection" role="status">
          Connection interrupted. Displayed evidence may be out of date. Reconnecting…
        </div>
      </main>
    </div>
    """
  end

  defp detail_path(id, return_to),
    do:
      "/coverage/publishers/" <>
        to_string(id) <> "?" <> URI.encode_query(%{"return_to" => return_to})

  defp lifecycle_label("retired"), do: "Retired from this controller"
  defp lifecycle_label("awaiting_inventory"), do: "Waiting for inventory"
  defp lifecycle_label(_), do: "Active publication"
  defp audit_label("confirmed"), do: "Confirmed catalogue"
  defp audit_label("unconfirmed"), do: "Catalogue needs confirmation"
  defp audit_label(_), do: "Catalogue not supported"
end

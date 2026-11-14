# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewFilters do
  @moduledoc """
  A keyboard-operated search and filter picker for LiveView.

  The caller owns the applied filters and URL patches. It supplies the available
  fields, the applied chips, and the current picker draft with its allowed values.
  Handle `search`, `filter_open`, `filter_query`, `filter_first`, `filter_select`,
  `filter_remove_edit`, and `filter_close` in the owning LiveView.

  Send `preview-filter-ready` after committing or cancelling a draft to return
  focus to the picker. Include `%{id: id}` when using an explicit component ID.
  """
  use MondekWeb, :html

  attr :id, :string, default: nil
  attr :picker, :map, required: true
  attr :chips, :list, required: true
  attr :fields, :list, required: true
  attr :search, :string, required: true
  attr :remove, :any, default: nil
  attr :clear_search, :string, default: nil
  attr :form_label, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true

  def filter_picker(assigns) do
    assigns = assign(assigns, :ids, ids(assigns.id))

    ~H"""
    <form
      id={@ids.form}
      class="preview-toolbar"
      phx-hook="PreviewFilterPicker"
      phx-submit={if @picker, do: "filter_first", else: "search"}
      phx-auto-recover="ignore"
      aria-label={@form_label}
      data-step={@picker && @picker.field}
      data-editing-filter={to_string(!!(@picker && Enum.any?(@chips, &(&1.field == @picker.field))))}
      data-chip-fields={Enum.map_join(@chips, " ", & &1.field)}
      data-value={if @picker, do: @picker.value, else: ""}
      data-search={@search || ""}
    >
      <div class="preview-search-field">
        <%= for chip <- @chips do %>
          <.editor
            :if={@picker && @picker.field == chip.field}
            ids={@ids}
            picker={@picker}
            label={@label}
            placeholder={@placeholder}
          />
          <span
            :if={!@picker || @picker.field != chip.field}
            id={@ids.chip <> chip.field}
            class="preview-filter-chip"
          >
            <button
              type="button"
              phx-click="filter_open"
              phx-value-field={chip.field}
              aria-label={"Edit #{chip.name} filter: #{chip.label}"}
            >
              <MondekWeb.Layouts.icon name={elem(List.keyfind(@fields, chip.field, 0), 2)} size={14} />
              <strong>{chip.name}:</strong> {chip.label}
            </button>
            <.link
              :if={@remove}
              patch={@remove.(chip.field)}
              aria-label={"Remove #{chip.name} filter"}
            >×</.link>
            <button
              :if={!@remove && Map.get(chip, :removable, true)}
              type="button"
              phx-click="filter_remove"
              phx-value-field={chip.field}
              aria-label={"Remove #{chip.name} filter"}
            >×</button>
          </span>
        <% end %>
        <span :if={@search} class="preview-filter-chip">
          <span class="preview-search-token" title={@search}>{@search}</span>
          <.link
            :if={@clear_search}
            patch={@clear_search}
            aria-label="Clear search text"
          >×</.link>
          <button
            :if={!@clear_search}
            type="button"
            phx-click="filter_remove"
            phx-value-field="search"
            aria-label="Clear search text"
          >×</button>
        </span>
        <.editor
          :if={!@picker || !Enum.any?(@chips, &(&1.field == @picker.field))}
          ids={@ids}
          picker={@picker}
          label={@label}
          placeholder={@placeholder}
        />
      </div>
      <div id={@ids.popup} class="preview-filter-popup" data-filter-popup>
        <div
          id={@ids.options}
          role="listbox"
          aria-label={if @picker, do: @picker.title, else: "Search and filters"}
        >
          <button
            :if={!@picker}
            type="submit"
            role="option"
            id={@ids.text}
            tabindex="-1"
            aria-selected="false"
            data-search-text
            class="preview-filter-text-option"
          >
            <MondekWeb.Layouts.icon name="search" size={16} />
            <span>Search for this text</span>
          </button>
          <div :if={!@picker} class="preview-filter-fields" role="group" aria-label="Add a filter">
            <div class="preview-filter-group-label" aria-hidden="true">Add a filter</div>
            <button
              :for={{field, label, icon} <- @fields}
              :if={!Enum.any?(@chips, &(&1.field == field))}
              id={@ids.field <> field}
              type="button"
              role="option"
              tabindex="-1"
              aria-selected="false"
              phx-click="filter_open"
              phx-value-field={field}
              data-filter-label={label}
            >
              <span class="preview-filter-option-chip">
                <MondekWeb.Layouts.icon
                  name={icon}
                  size={16}
                />
                <span>{label}</span>
              </span>
              <MondekWeb.Layouts.icon name="arrow" size={14} />
            </button>
          </div>
          <button
            :for={{option, index} <- Enum.with_index(if @picker, do: @picker.options, else: [])}
            id={@ids.option <> Integer.to_string(index)}
            type="button"
            role="option"
            tabindex="-1"
            aria-selected="false"
            phx-click="filter_select"
            phx-value-key={option.key}
            phx-value-kind={option.kind}
          >
            <span>{option.label}</span>
            <small :if={
              Map.get(option, :show_key, true) &&
                (option.kind != "" || String.downcase(option.key) != String.downcase(option.label))
            }>
              {if option.kind != "", do: option.kind <> " · "}{option.key}
            </small>
          </button>
        </div>
        <p :if={@picker && @picker.options == []} role="status">No matches</p>
      </div>
    </form>
    """
  end

  # Keep the original identifiers for existing callers. Other instances can
  # supply an ID and scope the label, listbox and option relationships to it.
  defp ids(nil) do
    %{
      form: "overview-search",
      editor: "overview-search-editor",
      input: "preview-search",
      chip: "preview-chip-",
      popup: "overview-filter-popup",
      options: "overview-filter-options",
      text: "overview-search-text",
      field: "overview-filter-",
      option: "overview-filter-option-"
    }
  end

  defp ids(id) do
    %{
      form: id,
      editor: id <> "-editor",
      input: id <> "-input",
      chip: id <> "-chip-",
      popup: id <> "-popup",
      options: id <> "-options",
      text: id <> "-search-text",
      field: id <> "-field-",
      option: id <> "-option-"
    }
  end

  defp editor(assigns) do
    ~H"""
    <div
      id={@ids.editor}
      class={["preview-search-editor", @picker && "preview-filter-chip"]}
    >
      <span :if={@picker} class="preview-filter-draft">{@picker.title}:</span>
      <input
        id={@ids.input}
        name="search"
        value={if @picker, do: @picker.value, else: ""}
        aria-label={if @picker, do: @picker.title, else: @label}
        placeholder={if @picker, do: "Find a value", else: @placeholder}
        size={if @picker, do: 12}
        maxlength="200"
        autocomplete="off"
        role="combobox"
        aria-expanded="false"
        aria-autocomplete="list"
        aria-controls={@ids.options}
      />
    </div>
    """
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewFilters do
  use MondekWeb, :html

  attr :picker, :map, required: true
  attr :chips, :list, required: true
  attr :fields, :list, required: true
  attr :search, :string, required: true
  attr :remove, :any, required: true
  attr :clear_search, :string, required: true
  attr :form_label, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true

  def filter_picker(assigns) do
    ~H"""
    <form
      id="overview-search"
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
            picker={@picker}
            label={@label}
            placeholder={@placeholder}
          />
          <span
            :if={!@picker || @picker.field != chip.field}
            id={"preview-chip-" <> chip.field}
            class="preview-filter-chip"
          >
            <button
              type="button"
              phx-click="filter_open"
              phx-value-field={chip.field}
              aria-label={"Edit #{chip.name} filter: #{chip.label}"}
            >
              <strong>{chip.name}:</strong> {chip.label}
            </button>
            <.link
              patch={@remove.(chip.field)}
              aria-label={"Remove #{chip.name} filter"}
            >×</.link>
          </span>
        <% end %>
        <span :if={@search} class="preview-filter-chip">
          <span class="preview-search-token" title={@search}>{@search}</span>
          <.link
            patch={@clear_search}
            aria-label="Clear search text"
          >×</.link>
        </span>
        <.editor
          :if={!@picker || !Enum.any?(@chips, &(&1.field == @picker.field))}
          picker={@picker}
          label={@label}
          placeholder={@placeholder}
        />
      </div>
      <div id="overview-filter-popup" class="preview-filter-popup">
        <div
          id="overview-filter-options"
          role="listbox"
          aria-label={if @picker, do: @picker.title, else: "Search and filters"}
        >
          <button
            :if={!@picker}
            type="submit"
            role="option"
            id="overview-search-text"
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
              id={"overview-filter-#{field}"}
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
            id={"overview-filter-option-#{index}"}
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
              option.kind != "" || String.downcase(option.key) != String.downcase(option.label)
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

  defp editor(assigns) do
    ~H"""
    <div
      id="overview-search-editor"
      class={["preview-search-editor", @picker && "preview-filter-chip"]}
    >
      <span :if={@picker} class="preview-filter-draft">{@picker.title}:</span>
      <input
        id="preview-search"
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
        aria-controls="overview-filter-options"
      />
    </div>
    """
  end
end

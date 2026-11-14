# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PanelStack do
  @moduledoc """
  Read-only ancestor cards for a LiveView fly-over. Supply entries in navigation order
  with a patch path, title and kind. The optional fallback slot renders a card when
  there is no snapshot from this browser session.

  Import `panel_stack.css` and register the PanelStack hook on a common ancestor with a changing
  `data-selection` and an active `#overview-panel`. Put its canonical URL in
  `data-panel-path` and its contents in a direct card body. Place the rear cards
  directly before the active panel, and mark the back link with
  `data-overview-close`. The host owns routes, the live form, and narrow navigation.
  Set `data-panel-background` on the hook element to select the background regions
  that become inert on narrow screens. Use `--panel-stack-width` and
  `--panel-stack-step` to adjust the desktop geometry.
  """
  use MondekWeb, :html

  @doc "Return to the nearest earlier panel for an entity, using its original URL."
  def destination(entries, identity, new_path) do
    Enum.find_value(Enum.reverse(entries), new_path, fn entry ->
      if entry.identity == identity, do: entry.path
    end)
  end

  attr :id, :string, default: "panel-stack"
  attr :entries, :list, required: true
  attr :card_class, :string, default: ""
  slot :fallback

  def rear_cards(assigns) do
    ~H"""
    <nav :if={@entries != []} class="preview-panel-back-stack" aria-label="Earlier panels">
      <div
        :for={{ancestor, depth} <- Enum.with_index(Enum.reverse(@entries), 1)}
        class={["preview-panel-back-card", @card_class]}
        style={"--depth: #{depth}"}
        data-panel-back-path={ancestor.path}
      >
        <div
          id={"#{@id}-snapshot-#{depth}"}
          phx-update="ignore"
          class="preview-panel-snapshot"
          inert
          aria-hidden="true"
        />
        <template data-panel-fallback>{fallback_markup(render_slot(@fallback, ancestor))}</template>
        <.link
          patch={ancestor.path}
          class="preview-panel-back-hit"
          aria-label={"Return to #{ancestor.kind}: #{ancestor.title}"}
        ><span>{ancestor.title}</span></.link>
      </div>
    </nav>
    """
  end

  # Send escaped text so fallback IDs and event bindings never enter the live DOM.
  defp fallback_markup(rendered),
    do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
end

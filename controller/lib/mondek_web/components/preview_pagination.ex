# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewPagination do
  @moduledoc """
  Stable numbered pagination for URL-owned lists and stateful component reviews.
  Supply a URL callback for LiveView patches, or event/target for component-owned
  paging that must retain its original review token and expiry.
  """
  use MondekWeb, :html

  attr :page, :integer, required: true
  attr :size, :integer, required: true
  attr :total, :integer, required: true
  attr :label, :string, required: true
  attr :url, :any, default: nil
  attr :event, :string, default: nil
  attr :target, :any, default: nil

  def pagination(assigns) do
    unless is_function(assigns.url, 1) || is_binary(assigns.event),
      do: raise(ArgumentError, "pagination requires a URL callback or an event")

    pages = max(1, ceil(assigns.total / assigns.size))

    numbers =
      [1, assigns.page - 1, assigns.page, assigns.page + 1, pages]
      |> Enum.filter(&(&1 in 1..pages))
      |> Enum.uniq()

    assigns =
      assign(assigns,
        pages: pages,
        numbers: Enum.zip([0 | numbers], numbers),
        first: (assigns.page - 1) * assigns.size + 1,
        last: min(assigns.page * assigns.size, assigns.total)
      )

    ~H"""
    <nav :if={@pages > 1} class="preview-pager preview-numbered-pager" aria-label={@label}>
      <span class="preview-page-range">
        <span aria-hidden="true">{@total}–{@total} of {@total}</span>
        <span>{@first}–{@last} of {@total}</span>
      </span>
      <div class="preview-page-controls">
        <.destination :if={@page > 1} number={@page - 1} url={@url} event={@event} target={@target}>
          Previous
        </.destination>
        <span :if={@page == 1} aria-disabled="true">Previous</span>
        <%= for {previous, number} <- @numbers do %>
          <span :if={number - previous > 1} aria-hidden="true">…</span>
          <span :if={number == @page} aria-current="page" aria-label={"Page #{number}"}>{number}</span>
          <.destination
            :if={number != @page}
            number={number}
            url={@url}
            event={@event}
            target={@target}
            label={"Page #{number}"}
          >
            {number}
          </.destination>
        <% end %>
        <.destination
          :if={@page < @pages}
          number={@page + 1}
          url={@url}
          event={@event}
          target={@target}
        >
          Next
        </.destination>
        <span :if={@page == @pages} aria-disabled="true">Next</span>
      </div>
    </nav>
    """
  end

  attr :number, :integer, required: true
  attr :url, :any, required: true
  attr :event, :any, required: true
  attr :target, :any, required: true
  attr :label, :string, default: nil
  slot :inner_block, required: true

  defp destination(assigns) do
    ~H"""
    <.link :if={@url} patch={@url.(@number)} aria-label={@label}>{render_slot(@inner_block)}</.link>
    <button
      :if={!@url}
      type="button"
      phx-click={@event}
      phx-value-page={@number}
      phx-target={@target}
      aria-label={@label}
    >{render_slot(@inner_block)}</button>
    """
  end
end

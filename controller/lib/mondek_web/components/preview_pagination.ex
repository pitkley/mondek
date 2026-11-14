# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewPagination do
  use MondekWeb, :html

  attr :page, :integer, required: true
  attr :size, :integer, required: true
  attr :total, :integer, required: true
  attr :label, :string, required: true
  attr :url, :any, required: true

  def pagination(assigns) do
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
        <.link :if={@page > 1} patch={@url.(@page - 1)}>Previous</.link>
        <span :if={@page == 1} aria-disabled="true">Previous</span>
        <%= for {previous, number} <- @numbers do %>
          <span :if={number - previous > 1} aria-hidden="true">…</span>
          <span :if={number == @page} aria-current="page" aria-label={"Page #{number}"}>{number}</span>
          <.link :if={number != @page} patch={@url.(number)} aria-label={"Page #{number}"}>{number}</.link>
        <% end %>
        <.link :if={@page < @pages} patch={@url.(@page + 1)}>Next</.link>
        <span :if={@page == @pages} aria-disabled="true">Next</span>
      </div>
    </nav>
    """
  end
end

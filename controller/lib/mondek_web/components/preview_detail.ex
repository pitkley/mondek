# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.PreviewDetail do
  use MondekWeb, :html

  attr :id, :string, default: nil
  attr :level, :integer, values: [1, 2], required: true
  attr :size, :string, values: ["xl", "2xl"], default: "2xl"
  slot :inner_block, required: true

  def heading(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={"h#{@level}"}
      id={@id}
      tabindex="-1"
      class={["pf-v6-c-title", "pf-m-#{@size}"]}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  attr :tag, :string, values: ["section", "div"], default: "section"
  attr :dialog, :boolean, default: true
  attr :wide, :boolean, default: true
  attr :id, :string, default: "overview-panel"
  attr :heading_id, :string, default: "overview-panel-title"
  attr :path, :string, default: nil
  slot :inner_block, required: true

  def surface(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={@id}
      class={[
        "pf-v6-c-card",
        if(@dialog, do: "preview-panel", else: "preview-incident-page"),
        @wide && "preview-incident-panel"
      ]}
      data-panel-path={@path}
      role={if @dialog, do: "dialog"}
      aria-modal={if @dialog, do: "false"}
      aria-labelledby={@heading_id}
    >
      <div class="pf-v6-c-card__body">{render_slot(@inner_block)}</div>
    </.dynamic_tag>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rest, :global
  attr :level, :integer, values: [2, 3], default: 3
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section
      id={@id}
      class={["preview-table-group preview-incident-section preview-detail-card", @class]}
      aria-labelledby={@id <> "-heading"}
      {@rest}
    >
      <.dynamic_tag
        tag_name={"h#{@level}"}
        id={@id <> "-heading"}
        tabindex="-1"
        class="preview-section-heading"
      >
        {@title}
      </.dynamic_tag>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :labelledby, :string, default: nil
  slot :inner_block, required: true

  def facts(assigns) do
    ~H"""
    <table
      class={["preview-incident-fact-table", @class]}
      aria-label={@label}
      aria-labelledby={@labelledby}
    >
      <tbody>{render_slot(@inner_block)}</tbody>
    </table>
    """
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.Layouts do
  use MondekWeb, :html

  attr :name, :string, required: true
  attr :size, :integer, default: 18

  def icon(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <use href={"/assets/icons.svg#" <> @name} />
    </svg>
    """
  end
end

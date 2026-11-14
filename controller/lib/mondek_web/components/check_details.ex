# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckDetails do
  use MondekWeb, :html

  @elements ~w(p h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del table thead tbody tr th td)
  @void_elements ~w(br hr)

  attr :text, :string, required: true

  def check_details(assigns) do
    ~H"""
    <div :if={@text not in [nil, ""]} class="preview-check-details">{markdown(@text)}</div>
    """
  end

  defp markdown(text) do
    case EarmarkParser.as_ast(text, breaks: true, gfm_tables: true, pure_links: false) do
      {:ok, nodes, _messages} -> {:safe, Enum.map(nodes, &render_node/1)}
      {:error, _, _} -> html_escape(text)
    end
  end

  defp render_node(text) when is_binary(text), do: escape(text)

  defp render_node({tag, attributes, children, %{verbatim: true}}) do
    # Show literal HTML as text. Attributes from check output never become DOM attributes.
    opening = [
      "<",
      tag,
      Enum.map(attributes, fn {key, value} -> [" ", key, "=\"", value, "\""] end)
    ]

    closing = if children == [], do: [], else: escape("</" <> tag <> ">")
    [escape(IO.iodata_to_binary([opening, ">"])), Enum.map(children, &render_node/1), closing]
  end

  defp render_node({tag, _, _, _}) when tag in @void_elements, do: ["<", tag, ">"]

  defp render_node({tag, attrs, children, _}) when tag in @elements do
    ["<", tag, list_start(tag, attrs), ">", Enum.map(children, &render_node/1), "</", tag, ">"]
  end

  defp render_node({"img", attrs, _, _}),
    do: escape(List.keyfind(attrs, "alt", 0, {"alt", ""}) |> elem(1))

  defp render_node({_, _, children, _}), do: Enum.map(children, &render_node/1)

  defp list_start("ol", [{"start", start}]) do
    case Integer.parse(start) do
      {number, ""} -> [" start=\"", Integer.to_string(number), "\""]
      _ -> []
    end
  end

  defp list_start(_, _), do: []

  defp escape(text), do: Phoenix.HTML.Safe.to_iodata(text)
end

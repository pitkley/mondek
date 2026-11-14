# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.CheckDetailsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias MondekWeb.CheckDetails

  test "formats check findings and preserves multiline text and code" do
    html =
      render_component(&CheckDetails.check_details/1,
        text: """
        **Capacity** is high
        Review these files:

        - Logs
        - Backups

        | Volume | Used |
        | --- | --- |
        | /var | 96% |

        ```text
        <error>  missing
        ```
        """
      )

    assert html =~ "<strong>Capacity</strong> is high<br>"
    assert html =~ "<li>Logs</li>"
    assert html =~ "<th>Volume</th>"
    assert html =~ "<td>96%</td>"
    assert html =~ "<pre><code>&lt;error&gt;  missing"
  end

  test "renders HTML, links, and images without active markup" do
    html =
      render_component(&CheckDetails.check_details/1,
        text: """
        <strong onclick="alert(1)">literal</strong>

        <script>alert(1)</script>

        [Run](javascript:alert%281%29) ![Chart](https://example.test/chart.svg)
        """
      )

    assert html =~ "&lt;strong onclick="
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "Run Chart"
    refute html =~ "<strong"
    refute html =~ "<script"
    refute html =~ "<a "
    refute html =~ "<img"
    refute html =~ "https://example.test"
  end
end

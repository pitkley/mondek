# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.BrowserNavigationTest do
  use ExUnit.Case, async: true
  alias MondekWeb.{BrowserNavigation, InvestigationTrail}

  test "local LiveView routes retain their bounded scope and typed investigation" do
    id = Ecto.UUID.generate()

    path =
      InvestigationTrail.path("/checks?freshness=unavailable&runner_id=#{id}", [
        {"result", id}
      ])

    assert BrowserNavigation.return_path(path) == path

    assert BrowserNavigation.return_path(
             "/runners?sort=name&return_to=https%3A%2F%2Fexample.test&unknown=discard"
           ) == "/runners?sort=name"

    assert BrowserNavigation.return_path("/guide") == "/guide"
    assert BrowserNavigation.return_path("/runners/#{id}?inspect=") == "/runners/#{id}?inspect="
    runner = InvestigationTrail.path("/runners?sort=name", [{"runner", id}])
    assert BrowserNavigation.return_path(runner) == runner
  end

  test "nested editor returns retain validated investigation context within a depth bound" do
    id = Ecto.UUID.generate()
    checks = "/checks?search=volume"
    result = "/results/#{id}/full?" <> URI.encode_query(%{"return_to" => checks})
    editor = "/configuration/#{id}?" <> URI.encode_query(%{"return_to" => result})
    rules = "/configuration/rules/new?" <> URI.encode_query(%{"return_to" => editor})

    assert BrowserNavigation.return_path(rules) == rules

    for unsafe <- ["https://example.test", "/api/v1/runners", "/runners?inspect=invalid"] do
      path = "/configuration?" <> URI.encode_query(%{"return_to" => unsafe, "search" => "volume"})
      assert BrowserNavigation.return_path(path) == "/configuration?search=volume"
    end

    deep =
      Enum.reduce(1..8, "/checks", fn _, rest ->
        "/configuration?" <> URI.encode_query(%{"return_to" => rest})
      end)

    trimmed = BrowserNavigation.return_path(deep)
    assert is_binary(trimmed)
    assert return_depth(trimmed) == 4
    assert BrowserNavigation.return_path(trimmed) == trimmed

    assert BrowserNavigation.return_path(
             "/configuration?return_to=" <> String.duplicate("x", 8200)
           ) == nil

    raw_query =
      Enum.map_join(
        ~w(search environment source_id target_kind target_key runner_id),
        "&",
        fn key -> key <> "=" <> String.duplicate("{", 600) end
      )

    raw = "/checks?" <> raw_query
    assert byte_size(raw) < 8192
    assert BrowserNavigation.return_path(raw) == nil
  end

  defp return_depth(path) do
    case URI.decode_query(URI.parse(path).query || "")["return_to"] do
      nil -> 0
      nested -> 1 + return_depth(nested)
    end
  end

  test "saved publisher evidence and maintenance copy context survive an editor return" do
    id = Ecto.UUID.generate()

    for {owner, context} <- [
          {"/coverage/publishers/17",
           %{"history_page" => "2", "event_id" => "23", "event_page" => "3", "evidence_id" => id}},
          {"/maintenance/new", %{"copy_series" => id, "check_id" => id, "stream_id" => id}},
          {"/configuration/rules/#{id}", %{"schema_from" => id, "schema_search" => "volume"}}
        ] do
      origin = owner <> "?" <> URI.encode_query(context)
      editor = "/configuration/#{id}?" <> URI.encode_query(%{"return_to" => origin})
      normalized = BrowserNavigation.return_path(editor)
      assert is_binary(normalized)

      restored =
        normalized
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("return_to")

      assert URI.parse(restored).path == owner
      assert URI.decode_query(URI.parse(restored).query) == context
      assert BrowserNavigation.return_path(normalized) == normalized
    end
  end

  test "non-browser, malformed and external destinations cannot become return links" do
    for path <- [
          "https://example.test/runners",
          "//example.test/runners",
          "/runners#fragment",
          "/runners\\\\example.test",
          "/api/v1/runners",
          "/health",
          "/configuration.git/info/refs",
          "/licenses/notices",
          "/does-not-exist",
          "/runners?inspect=garbage",
          "/runners?search[bad]=1",
          "/runners?surface=page",
          "/runners?surface=page&page_entity=health:invalid",
          "/runners?search=" <> String.duplicate("x", 8200)
        ] do
      assert BrowserNavigation.return_path(path) == nil, path
    end

    assert BrowserNavigation.return_path(%{}) == nil
  end

  test "page presentation requires a typed entity in the same trail" do
    id = Ecto.UUID.generate()
    other = Ecto.UUID.generate()

    path =
      InvestigationTrail.path("/checks", [{"result", id}], %{
        "surface" => "page",
        "page_entity" => "result:#{id}"
      })

    assert BrowserNavigation.return_path(path) == path

    refute BrowserNavigation.return_path(
             String.replace(path, "page_entity=result%3A#{id}", "page_entity=result%3A#{other}")
           )
  end

  test "literal all remains an exact source or text filter through runner URLs" do
    path =
      MondekWeb.RunnerNavigation.path(%{"source_id" => "all", "search" => "all", "page" => "2"})

    query = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["source_id"] == "all"
    assert query["search"] == "all"
    assert query["page"] == "2"
    assert MondekWeb.BrowserNavigation.return_path(path) == path
  end
end

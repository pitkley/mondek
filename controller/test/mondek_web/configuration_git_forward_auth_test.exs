# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationGitForwardAuthTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint
  @token String.duplicate("test-configuration-token-", 2)
  @outer "Bearer isolated-test-gateway-token"
  @header "x-mondek-git-token"
  @upload "/configuration.git/git-upload-pack"
  @receive "/configuration.git/git-receive-pack"
  @advertise "/configuration.git/info/refs"
  @upload_info @advertise <> "?service=git-upload-pack"
  @receive_info @advertise <> "?service=git-receive-pack"

  defmodule Gateway do
    import Plug.Conn

    @outer "Bearer isolated-test-gateway-token"
    @routes [
      {"GET", "/configuration.git/info/refs"},
      {"POST", "/configuration.git/git-upload-pack"},
      {"POST", "/configuration.git/git-receive-pack"}
    ]

    def init(options), do: options

    def call(conn, origin: origin) do
      cond do
        {conn.method, conn.request_path} not in @routes ->
          send_resp(conn, 404, "Unknown path")

        get_req_header(conn, "authorization") != [@outer] ->
          send_resp(conn, 403, "Gateway credential required")

        true ->
          # Only the independent Mondek credential and Git headers reach the upstream.
          url = String.to_charlist(origin <> conn.request_path <> "?" <> conn.query_string)

          headers =
            for {name, value} <- conn.req_headers,
                name in ["x-mondek-git-token", "git-protocol"],
                do: {String.to_charlist(name), String.to_charlist(value)}

          case conn.method do
            "GET" ->
              forward(conn, :get, {url, headers})

            "POST" ->
              {:ok, body, conn} = read_body(conn)
              [content_type] = get_req_header(conn, "content-type")
              forward(conn, :post, {url, headers, String.to_charlist(content_type), body})
          end
      end
    end

    defp forward(conn, method, request) do
      {:ok, {{_, status, _}, headers, body}} =
        :httpc.request(method, request, [timeout: 5_000, autoredirect: false],
          body_format: :binary
        )

      conn =
        Enum.reduce(headers, conn, fn
          {~c"content-type", type}, acc -> put_resp_header(acc, "content-type", to_string(type))
          _, acc -> acc
        end)

      send_resp(conn, status, body)
    end
  end

  setup do
    values = [
      configuration_git_token: @token,
      configuration_git_token_file: nil,
      configuration_git_header_auth: true
    ]

    for {key, value} <- values do
      previous = Application.fetch_env(:mondek, key)
      Application.put_env(:mondek, key, value)

      on_exit(fn ->
        case previous do
          {:ok, saved} -> Application.put_env(:mondek, key, saved)
          :error -> Application.delete_env(:mondek, key)
        end
      end)
    end

    :ok
  end

  test "header authentication is opt-in and direct Basic remains available" do
    Application.put_env(:mondek, :configuration_git_header_auth, false)

    conn = build_conn() |> put_req_header(@header, @token) |> get(@upload_info)
    assert response(conn, 401)
    assert get_resp_header(conn, "www-authenticate") != []

    assert basic_conn()
           |> put_req_header(@header, "ignored")
           |> get(@upload_info)
           |> response(200)

    Application.put_env(:mondek, :configuration_git_header_auth, true)

    assert basic_conn() |> get(@upload_info) |> response(200)
    assert build_conn() |> put_req_header(@header, @token) |> get(@receive_info) |> response(200)

    conn =
      build_conn()
      |> put_req_header("x-forwarded-user", "mondek")
      |> put_req_header("x-auth-request-user", "mondek")
      |> get(@upload_info)

    assert response(conn, 401)
  end

  test "invalid or ambiguous header credentials never fall back to Basic" do
    for headers <- [
          [{@header, ""}],
          [{@header, "invalid"}],
          [{@header, @token <> "," <> @token}],
          [{@header, @token}, {@header, @token}]
        ],
        request <- [
          {:get, @upload_info, nil},
          {:get, @receive_info, nil},
          {:post, @upload, "application/x-git-upload-pack-request"},
          {:post, @receive, "application/x-git-receive-pack-request"}
        ] do
      conn = basic_conn()
      conn = %{conn | req_headers: headers ++ conn.req_headers}

      conn =
        case request do
          {:get, path, _} -> get(conn, path)
          {:post, path, type} -> conn |> put_req_header("content-type", type) |> post(path, "")
        end

      assert response(conn, 401) == "Git credentials required"
      assert get_resp_header(conn, "www-authenticate") == []
    end
  end

  test "real Git advertises, clones, fetches and pushes through a gateway consuming Authorization" do
    origin = listen(:git_origin, @endpoint)
    gateway = listen(:git_gateway, {Gateway, origin: origin})
    url = gateway <> "/configuration.git"

    directory = Path.join(System.tmp_dir!(), "mondek-forward-auth-" <> Ecto.UUID.generate())
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    writer = Path.join(directory, "writer")
    reader = Path.join(directory, "reader")

    both = ["Authorization: " <> @outer, "X-Mondek-Git-Token: " <> @token]

    assert {_, 0} = git(["clone", url, writer], both, url)
    assert {_, 0} = git(["clone", url, reader], both, url)

    assert {_, 0} =
             git(["-C", writer, "commit", "--allow-empty", "-m", "Gateway-authored change"])

    assert {:ok, %{head: original}} = Mondek.ConfigurationRepository.state()

    denied = [
      ["X-Mondek-Git-Token: " <> @token],
      ["Authorization: Bearer invalid", "X-Mondek-Git-Token: " <> @token],
      ["Authorization: " <> @outer],
      ["Authorization: " <> @outer, "X-Mondek-Git-Token: invalid"]
    ]

    for headers <- denied,
        args <- [
          ["ls-remote", url, "refs/heads/main"],
          ["-C", reader, "fetch", "origin"],
          ["-C", writer, "push", "origin", "main"]
        ] do
      assert {_, status} = git(args, headers, url)
      assert status != 0
    end

    assert {:ok, %{head: ^original}} = Mondek.ConfigurationRepository.state()
    assert {_, 0} = git(["-C", writer, "push", "origin", "main"], both, url)
    assert {_, 0} = git(["-C", reader, "fetch", "origin"], both, url)
    assert {local, 0} = git(["-C", writer, "rev-parse", "HEAD"])
    assert {fetched, 0} = git(["-C", reader, "rev-parse", "origin/main"])
    assert local == fetched
    assert {:ok, %{head: accepted}} = Mondek.ConfigurationRepository.state()
    assert String.trim(fetched) == accepted
  end

  defp basic_conn do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("mondek:" <> @token))
  end

  defp listen(id, plug) do
    spec = Supervisor.child_spec({Bandit, plug: plug, port: 0, ip: {127, 0, 0, 1}}, id: id)
    server = start_supervised!(spec)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp git(args, headers \\ [], url \\ nil) do
    config =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {header, index} -> {"MONDEK_TEST_HTTP_HEADER_#{index}", header} end)

    System.cmd(
      "git",
      Enum.map(config, fn {key, _} -> "--config-env=http.#{url}.extraHeader=#{key}" end) ++
        [
          "-c",
          "http.followRedirects=false",
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid" | args
        ],
      stderr_to_stdout: true,
      env:
        config ++
          [
            {"GIT_CONFIG_NOSYSTEM", "1"},
            {"GIT_CONFIG_GLOBAL", "/dev/null"},
            {"GIT_TERMINAL_PROMPT", "0"}
          ]
    )
  end
end

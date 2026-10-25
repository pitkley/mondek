# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.ConfigurationGitControllerTest do
  use Mondek.DataCase, async: false
  import Phoenix.ConnTest
  import Plug.Conn
  @endpoint MondekWeb.Endpoint
  @token String.duplicate("local-test-token-", 3)

  setup do
    previous = Application.get_env(:mondek, :configuration_git_token)
    Application.put_env(:mondek, :configuration_git_token, @token)
    on_exit(fn -> Application.put_env(:mondek, :configuration_git_token, previous) end)
  end

  defp authenticated do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("mondek:" <> @token))
  end

  test "Git endpoint is opt-in and both reads and writes require a token" do
    assert build_conn()
           |> get("/configuration.git/info/refs?service=git-upload-pack")
           |> response(401)

    assert build_conn()
           |> put_req_header("content-type", "application/x-git-receive-pack-request")
           |> post("/configuration.git/git-receive-pack", "")
           |> response(401)

    assert build_conn()
           |> put_req_header("authorization", "Basic " <> Base.encode64("mondek:wrong"))
           |> get("/configuration.git/info/refs?service=git-upload-pack")
           |> response(401)

    Application.delete_env(:mondek, :configuration_git_token)

    assert authenticated()
           |> get("/configuration.git/info/refs?service=git-upload-pack")
           |> response(404)
  end

  test "authenticated advertisement and fetch use real Git protocol" do
    {:ok, state} = Mondek.ConfigurationRepository.state()
    conn = authenticated() |> get("/configuration.git/info/refs?service=git-upload-pack")
    assert response(conn, 200) =~ state.head <> " refs/heads/main"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "access-control-allow-origin") == []
    body = packet("want #{state.head}\n") <> "0000" <> packet("done\n")

    conn =
      authenticated()
      |> put_req_header("content-type", "application/x-git-upload-pack-request")
      |> post("/configuration.git/git-upload-pack", body)

    assert response(conn, 200) =~ "PACK"
  end

  test "old Git username is rejected even with the correct token" do
    assert build_conn()
           |> put_req_header("authorization", "Basic " <> Base.encode64("watchpost:" <> @token))
           |> get("/configuration.git/info/refs?service=git-upload-pack")
           |> response(401)
  end

  test "simple browser content types and unsupported services are rejected" do
    for type <- ["text/plain", "application/json", "application/x-git-upload-pack-request"] do
      assert authenticated()
             |> put_req_header("content-type", type)
             |> post(
               "/configuration.git/git-receive-pack",
               if(type == "application/json", do: "{}", else: "test")
             )
             |> response(415)
    end

    assert authenticated()
           |> get("/configuration.git/info/refs?service=git-other")
           |> response(400)
  end

  test "protocol rejection does not alter accepted configuration" do
    {:ok, state} = Mondek.ConfigurationRepository.state()

    body =
      packet("#{state.head} #{String.duplicate("0", 40)} refs/heads/main\0report-status\n") <>
        "0000"

    conn =
      authenticated()
      |> put_req_header("content-type", "application/x-git-receive-pack-request")
      |> post("/configuration.git/git-receive-pack", body)

    assert response(conn, 200) =~ "ng refs/heads/main Deleting main"
    assert {:ok, %{head: head}} = Mondek.ConfigurationRepository.state()
    assert head == state.head
  end

  test "ordinary Git clone and push round trip through HTTP with rejected invalid content" do
    server = start_supervised!({Bandit, plug: @endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    directory =
      Path.join(
        System.tmp_dir!(),
        "mondek-git-10000000-0000-4000-8000-000000000002-" <> Ecto.UUID.generate()
      )

    on_exit(fn ->
      File.rm_rf!(directory)
    end)

    auth = "Authorization: Basic " <> Base.encode64("mondek:" <> @token)
    url = "http://127.0.0.1:#{port}/configuration.git"

    git = fn args ->
      System.cmd(
        "git",
        [
          "-c",
          "http.extraHeader=#{auth}",
          "-c",
          "credential.helper=",
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid" | args
        ],
        stderr_to_stdout: true,
        env: [
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_TERMINAL_PROMPT", "0"}
        ]
      )
    end

    assert {_, 0} = git.(["clone", url, directory])

    assert {_, 0} =
             git.([
               "-C",
               directory,
               "commit",
               "--allow-empty",
               "-m",
               "Agent reviewed configuration"
             ])

    assert {_, 0} = git.(["-C", directory, "push", "origin", "main"])
    {head, 0} = git.(["-C", directory, "rev-parse", "HEAD"])
    assert {:ok, %{head: accepted}} = Mondek.ConfigurationRepository.state()
    assert accepted == String.trim(head)
    File.write!(Path.join(directory, "unsupported.txt"), "not configuration")
    assert {_, 0} = git.(["-C", directory, "add", "unsupported.txt"])
    assert {_, 0} = git.(["-C", directory, "commit", "-m", "Invalid configuration"])
    assert {rejection, status} = git.(["-C", directory, "push", "origin", "main"])
    assert status != 0
    assert rejection =~ "remote rejected"
    assert {:ok, %{head: ^accepted}} = Mondek.ConfigurationRepository.state()
  end

  defp packet(body),
    do: ((byte_size(body) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0")) <> body
end

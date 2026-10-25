# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
{
  pkgs,
  lib,
  config,
  ...
}:
let
  beam = pkgs.beam.packages.erlang_29;
  elixir = beam.elixir_1_20;
in
{
  languages.elixir = {
    enable = true;
    package = elixir;
    lsp.package = beam.elixir-ls.override { inherit elixir; };
  };
  languages.erlang = {
    enable = true;
    package = beam.erlang;
  };
  languages.python = {
    enable = true;
    package = pkgs.python313;
  };
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_24;
  };

  packages = [
    pkgs.git
    pkgs.jq
    pkgs.curl
    pkgs.uv
    pkgs.rsync
    pkgs.openssh
    pkgs.openssl
    # Includes Compose and buildx CLI plugins; the engine is host-provided.
    pkgs.docker-client
    pkgs.shellcheck
    pkgs.actionlint
    pkgs.zizmor
    pkgs.nixfmt
    pkgs.esbuild
    pkgs.tailwindcss_4
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.inotify-tools ];

  # Non-secret local configuration only. Services are managed by Compose.
  env = {
    MIX_HOME = "${config.env.DEVENV_STATE}/mix";
    HEX_HOME = "${config.env.DEVENV_STATE}/hex";
    UV_CACHE_DIR = "${config.env.DEVENV_STATE}/uv-cache";
    UV_PYTHON = "${config.languages.python.package}/bin/python3";
    UV_PYTHON_DOWNLOADS = "never";
    ESBUILD_PATH = lib.getExe pkgs.esbuild;
    TAILWINDCSS_PATH = lib.getExe pkgs.tailwindcss_4;
    PGHOST = "127.0.0.1";
    PGPORT = "55432";
    PGUSER = "mondek";
    PGDATABASE = "mondek_dev";
  };

  scripts.mondek.exec = ''
    exec bash "$DEVENV_ROOT/scripts/mondek" "$@"
  '';

  # Native CI uses the same pinned runtimes without editor/deployment tooling.
  profiles.ci.module = {
    languages.elixir.lsp.enable = lib.mkForce false;
    languages.erlang.lsp.enable = lib.mkForce false;
    languages.python.lsp.enable = lib.mkForce false;
    languages.javascript.lsp.enable = lib.mkForce false;
    packages = lib.mkForce [
      pkgs.git
      pkgs.jq
      pkgs.curl
      pkgs.uv
      pkgs.docker-client
      pkgs.shellcheck
      pkgs.actionlint
      pkgs.zizmor
      pkgs.nixfmt
      pkgs.esbuild
      pkgs.pyright
      elixir
      beam.erlang
      beam.rebar3
      pkgs.python313
      pkgs.nodejs_24
    ];
    env.TAILWINDCSS_PATH = lib.mkForce "";
  };

  # Opt-in bot configuration tooling; keep it out of normal shells and CI.
  profiles.maintenance.module = {
    languages.elixir.enable = lib.mkForce false;
    languages.erlang.enable = lib.mkForce false;
    languages.python.enable = lib.mkForce false;
    languages.javascript.enable = lib.mkForce false;
    packages = lib.mkForce [ pkgs.renovate ];
  };

  # Shell entry does not install dependencies or start/migrate services.
  enterTest = ''
    mondek check
  '';
}

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.RuntimeConfigurationTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @variables ~w(MONDEK_RETENTION_RECEIPT_DAYS MONDEK_RETENTION_HISTORY_DAYS MONDEK_RETENTION_MAX_OBSERVATIONS MONDEK_DEPLOYMENT_MODE SECRET_KEY_BASE DATABASE_URL PGSSLMODE PGSSLROOTCERT PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE PORT MONDEK_PUBLIC_URL MONDEK_SEED_DEMO MONDEK_NOTIFICATION_ADAPTER MONDEK_WEBHOOK_CONFIG_FILE MONDEK_SMTP_HOST MONDEK_SMTP_PORT MONDEK_SMTP_TRANSPORT MONDEK_SMTP_USERNAME MONDEK_SMTP_PASSWORD MONDEK_SMTP_FROM MONDEK_SMTP_TO MONDEK_SMTP_TIMEOUT_MS)

  setup do
    variables =
      @variables ++ Enum.map(@variables, &String.replace_prefix(&1, "MONDEK_", "WATCHPOST_"))

    original = Map.new(variables, &{&1, System.get_env(&1)})
    Enum.each(variables, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp configuration do
    @runtime |> Config.Reader.read!(env: :prod) |> Keyword.fetch!(:mondek)
  end

  test "retention settings validate at startup and preserve defaults" do
    assert configuration()[:retention] == %{
             receipt_days: 7,
             history_days: 30,
             max_observations: 100_000
           }

    System.put_env("MONDEK_RETENTION_RECEIPT_DAYS", "14")
    System.put_env("MONDEK_RETENTION_HISTORY_DAYS", "60")
    System.put_env("MONDEK_RETENTION_MAX_OBSERVATIONS", "2000")

    assert configuration()[:retention] == %{
             receipt_days: 14,
             history_days: 60,
             max_observations: 2000
           }

    for name <-
          ~w(MONDEK_RETENTION_RECEIPT_DAYS MONDEK_RETENTION_HISTORY_DAYS MONDEK_RETENTION_MAX_OBSERVATIONS),
        value <- ["", "0", "-1", "1junk", "9999999999999"] do
      System.put_env(name, value)
      assert_raise RuntimeError, ~r/#{name} must be an integer/, &configuration/0
      System.put_env(name, "1")
    end
  end

  defp deployment do
    System.put_env(%{
      "MONDEK_DEPLOYMENT_MODE" => "true",
      "SECRET_KEY_BASE" => String.duplicate("test-only-secret-", 6),
      "PGPASSWORD" => "test-only-database-password",
      "MONDEK_PUBLIC_URL" => "https://monitoring.example.test",
      "MONDEK_NOTIFICATION_ADAPTER" => "smtp",
      "MONDEK_SMTP_HOST" => "relay",
      "MONDEK_SMTP_FROM" => "mondek@example.invalid",
      "MONDEK_SMTP_TO" => "operator@example.invalid"
    })
  end

  test "old setting names are ignored and current names remain authoritative" do
    System.put_env("WATCHPOST_SEED_DEMO", "false")
    assert configuration()[:seed_demo] == nil
    System.put_env("MONDEK_SEED_DEMO", "false")
    assert configuration()[:seed_demo] == nil
    System.put_env("WATCHPOST_DEPLOYMENT_MODE", "true")
    assert configuration()[:deployment_mode] == false
  end

  test "local production builds retain the development defaults" do
    config = configuration()
    assert config[:deployment_mode] == false
    assert config[:seed_demo] == nil
    assert config[MondekWeb.Endpoint][:check_origin] == false
    assert config[Mondek.Repo][:database] == "mondek_dev"
    assert config[Mondek.Repo][:password] == nil
  end

  test "deployment installs the exact public origin and starts without controller-seeded checks" do
    deployment()
    System.put_env("MONDEK_SEED_DEMO", "true")
    config = configuration()

    assert config[:deployment_mode] == true
    assert config[:seed_demo] == nil
    assert config[:public_url] == "https://monitoring.example.test"

    assert config[MondekWeb.Endpoint][:url] == [
             scheme: "https",
             host: "monitoring.example.test",
             port: 443
           ]

    assert config[MondekWeb.Endpoint][:check_origin] == ["https://monitoring.example.test"]
  end

  test "missing deployment values fail by variable name without printing provided values" do
    for name <- ~w(SECRET_KEY_BASE PGPASSWORD MONDEK_PUBLIC_URL) do
      deployment()
      System.delete_env(name)
      assert_raise RuntimeError, "#{name} is required in deployment mode", &configuration/0
      System.put_env(name, "")
      assert_raise RuntimeError, "#{name} is required in deployment mode", &configuration/0
    end
  end

  test "deployment refuses short and known development session secrets" do
    deployment()

    for value <- ["short-private-value", String.duplicate("local-development-only-", 4)] do
      System.put_env("SECRET_KEY_BASE", value)

      assert_raise RuntimeError,
                   "SECRET_KEY_BASE must contain at least 64 bytes and must not use the development value",
                   &configuration/0
    end
  end

  test "database passwords retain literal special characters without URL encoding" do
    deployment()
    password = ~s(test-only-$dollar#hash@slash/quote"single'and space)
    System.put_env("PGPASSWORD", password)
    assert configuration()[Mondek.Repo][:password] == password
  end

  test "deployment rejects conflicting DATABASE_URL without exposing its contents" do
    deployment()
    System.put_env("DATABASE_URL", "postgres://private-user:private-password@db/db")

    assert_raise RuntimeError,
                 "Deployment mode uses PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD; remove DATABASE_URL",
                 &configuration/0
  end

  test "database TLS is opt-in and supports required encryption and verified modes" do
    refute Keyword.has_key?(configuration()[Mondek.Repo], :ssl)
    deployment()
    System.put_env("PGSSLMODE", "disable")
    assert configuration()[Mondek.Repo][:ssl] == false
    System.put_env("PGSSLMODE", "require")
    assert configuration()[Mondek.Repo][:ssl] == [verify: :verify_none]
    System.put_env("PGSSLROOTCERT", "/run/certs/database-ca.pem")

    for mode <- ["verify-ca", "verify-full"] do
      System.put_env("PGSSLMODE", mode)
      ssl = configuration()[Mondek.Repo][:ssl]
      assert ssl[:verify] == :verify_peer
      assert ssl[:cacertfile] == "/run/certs/database-ca.pem"
      assert ssl[:server_name_indication] == :disable == (mode == "verify-ca")
    end
  end

  test "invalid or conflicting database TLS settings fail without exposing values" do
    for value <- ["", "prefer", "allow", "private-invalid-value"] do
      System.put_env("PGSSLMODE", value)

      assert_raise RuntimeError,
                   "PGSSLMODE must be disable, require, verify-ca or verify-full",
                   &configuration/0
    end

    System.delete_env("PGSSLMODE")
    System.put_env("PGSSLROOTCERT", "/private/ca.pem")

    assert_raise RuntimeError,
                 "PGSSLROOTCERT requires PGSSLMODE=verify-ca or verify-full",
                 &configuration/0

    System.delete_env("PGSSLROOTCERT")
    System.put_env("PGSSLMODE", "require")

    for query <- ["ssl=true", "ssl=false"] do
      System.put_env("DATABASE_URL", "postgres://private:secret@localhost/db?" <> query)

      assert_raise RuntimeError,
                   "Configure database TLS through PGSSLMODE or DATABASE_URL, not both",
                   &configuration/0
    end
  end

  test "development DATABASE_URL keeps Ecto ssl=true support" do
    url = "postgres://localhost/mondek_dev?ssl=true"
    System.put_env("DATABASE_URL", url)
    assert configuration()[Mondek.Repo][:url] == url
    refute Keyword.has_key?(configuration()[Mondek.Repo], :ssl)
    assert Ecto.Repo.Supervisor.parse_url(url)[:ssl] == true
    System.put_env("DATABASE_URL", "postgres://localhost/mondek_dev?sslmode=require")

    assert_raise RuntimeError,
                 "DATABASE_URL sslmode is unsupported; use PGSSLMODE or ssl=true",
                 &configuration/0

    System.put_env("DATABASE_URL", "postgres://localhost/mondek_dev")
    System.put_env("PGSSLMODE", "require")
    assert configuration()[Mondek.Repo][:ssl] == [verify: :verify_none]
  end

  test "public origin rejects insecure URLs and URL credentials or extra components" do
    deployment()

    for url <- [
          "http://monitoring.example.test",
          "https://user:secret@monitoring.example.test",
          "https://monitoring.example.test/prefix",
          "https://monitoring.example.test?secret=value",
          "https://monitoring.example.test#fragment",
          "https://monitoring.example.test:99999",
          "https://*.example.test",
          "https://"
        ] do
      System.put_env("MONDEK_PUBLIC_URL", url)

      assert_raise RuntimeError,
                   ~r/MONDEK_PUBLIC_URL must be an HTTPS origin/,
                   &configuration/0
    end
  end

  test "root slash is normalized and explicit HTTPS development ports are retained" do
    deployment()
    System.put_env("MONDEK_PUBLIC_URL", "https://localhost:4443/")
    config = configuration()
    assert config[:public_url] == "https://localhost:4443"
    assert config[MondekWeb.Endpoint][:check_origin] == ["https://localhost:4443"]
    assert config[MondekWeb.Endpoint][:url][:port] == 4443
  end

  test "invalid deployment toggle cannot silently select development defaults" do
    System.put_env("MONDEK_DEPLOYMENT_MODE", "yes")
    assert_raise RuntimeError, "MONDEK_DEPLOYMENT_MODE must be true or false", &configuration/0
  end

  @tag capture_log: true
  test "Phoenix accepts only the configured deployment WebSocket origin" do
    deployment()
    origins = configuration()[MondekWeb.Endpoint][:check_origin]

    for origin <- [
          "https://monitoring.example.test",
          "http://monitoring.example.test",
          "https://monitoring.example.test:4443",
          "https://other.example.test"
        ] do
      conn =
        Plug.Test.conn(:get, "http://controller:4000/live/websocket")
        |> Plug.Conn.put_req_header("origin", origin)
        |> Phoenix.Socket.Transport.check_origin(
          __MODULE__,
          MondekWeb.Endpoint,
          check_origin: origins
        )

      if origin == "https://monitoring.example.test" do
        refute conn.halted
      else
        assert conn.halted
        assert conn.status == 403
      end
    end
  end

  defp smtp do
    System.put_env(%{
      "MONDEK_SMTP_HOST" => "relay",
      "MONDEK_SMTP_FROM" => "mondek@example.invalid",
      "MONDEK_SMTP_TO" => "operator@example.invalid"
    })
  end

  test "deployment requires SMTP settings by default while local delivery stays webhook" do
    assert configuration()[:notification_adapter] == :webhook
    deployment()
    System.delete_env("MONDEK_NOTIFICATION_ADAPTER")
    Enum.each(~w(MONDEK_SMTP_HOST MONDEK_SMTP_FROM MONDEK_SMTP_TO), &System.delete_env/1)

    assert_raise ArgumentError, ~r/Invalid SMTP configuration/, &configuration/0
    smtp()
    config = configuration()
    assert config[:notification_adapter] == :smtp
    assert config[:smtp][:transport] == :plain
    assert config[:smtp][:port] == 25
    assert config[:smtp][:timeout_ms] == 10_000
  end

  test "inactive transports stay configured so their frozen queues can drain" do
    path =
      Path.join(
        System.tmp_dir!(),
        "mondek-runtime-webhook-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      Jason.encode!(%{
        "active" => "ops",
        "destinations" => %{
          "ops" => %{"url" => "https://receiver.example.invalid/secret", "template" => "teams"}
        }
      })
    )

    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm(path) end)
    deployment()
    System.put_env("MONDEK_WEBHOOK_CONFIG_FILE", path)
    config = configuration()
    assert config[:notification_adapter] == :smtp
    assert config[:webhook].active == "ops"
    assert config[:smtp][:host] == "relay"
    System.put_env("MONDEK_NOTIFICATION_ADAPTER", "webhook")
    config = configuration()
    assert config[:notification_adapter] == :webhook
    assert config[:smtp][:host] == "relay"
    assert config[:webhook].active == "ops"
    System.delete_env("MONDEK_WEBHOOK_CONFIG_FILE")

    assert_raise RuntimeError,
                 "MONDEK_WEBHOOK_CONFIG_FILE is required for deployment webhooks",
                 &configuration/0
  end

  test "SMTP credentials retain literal characters and require encrypted transport" do
    deployment()
    smtp()
    password = ~s(test-only-$dollar#hash@slash/quote"single'and space)

    System.put_env(%{
      "MONDEK_NOTIFICATION_ADAPTER" => "smtp",
      "MONDEK_SMTP_USERNAME" => "operator",
      "MONDEK_SMTP_PASSWORD" => password
    })

    assert_raise ArgumentError, ~r/Invalid SMTP configuration/, &configuration/0
    System.put_env("MONDEK_SMTP_TRANSPORT", "starttls")
    assert configuration()[:smtp][:password] == password
  end

  test "invalid SMTP options are rejected without printing supplied settings" do
    deployment()
    smtp()
    System.put_env("MONDEK_NOTIFICATION_ADAPTER", "smtp")

    for {name, value, message} <- [
          {"MONDEK_SMTP_TRANSPORT", "private-value",
           "MONDEK_SMTP_TRANSPORT must be plain, starttls or tls"},
          {"MONDEK_SMTP_PORT", "private-value", "MONDEK_SMTP_PORT must be an integer"},
          {"MONDEK_SMTP_TIMEOUT_MS", "private-value", "MONDEK_SMTP_TIMEOUT_MS must be an integer"}
        ] do
      System.put_env(name, value)
      assert_raise RuntimeError, message, &configuration/0
      System.delete_env(name)
    end

    System.put_env("MONDEK_NOTIFICATION_ADAPTER", "private-value")

    assert_raise RuntimeError,
                 "MONDEK_NOTIFICATION_ADAPTER must be smtp or webhook",
                 &configuration/0
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
import Config

settings = System.get_env()

env = fn name, default -> Map.get(settings, name, default) end

deployment? =
  case env.("MONDEK_DEPLOYMENT_MODE", "false") do
    "true" -> true
    "false" -> false
    _ -> raise "MONDEK_DEPLOYMENT_MODE must be true or false"
  end

required_env! = fn name ->
  case env.(name, nil) do
    value when is_binary(value) and byte_size(value) > 0 -> value
    _ -> raise "#{name} is required in deployment mode"
  end
end

development_secret = String.duplicate("local-development-only-", 4)

secret_key_base =
  if deployment? do
    value = required_env!.("SECRET_KEY_BASE")

    if byte_size(value) < 64 or value == development_secret do
      raise "SECRET_KEY_BASE must contain at least 64 bytes and must not use the development value"
    end

    value
  else
    env.("SECRET_KEY_BASE", development_secret)
  end

if deployment? and env.("DATABASE_URL", nil) do
  raise "Deployment mode uses PGHOST, PGPORT, PGUSER, PGDATABASE and PGPASSWORD; remove DATABASE_URL"
end

database_password =
  if deployment?, do: required_env!.("PGPASSWORD"), else: env.("PGPASSWORD", nil)

public_uri =
  if deployment? do
    value = required_env!.("MONDEK_PUBLIC_URL")

    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: port,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       } = uri}
      when is_binary(host) and host != "" and port in 1..65_535 and path in [nil, "/"] ->
        if not Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host) do
          raise "MONDEK_PUBLIC_URL must be an HTTPS origin with a DNS hostname"
        end

        %{uri | path: nil}

      _ ->
        raise "MONDEK_PUBLIC_URL must be an HTTPS origin without credentials, path, query or fragment"
    end
  end

database_url = env.("DATABASE_URL", nil)
production_database? = config_env() == :prod or deployment?

db =
  cond do
    config_env() == :test ->
      env.("MONDEK_TEST_DATABASE", "mondek_test")

    production_database? ->
      case env.("PGDATABASE", nil) do
        value when is_binary(value) and byte_size(value) > 0 -> value
        _ when is_binary(database_url) and byte_size(database_url) > 0 -> nil
        _ -> raise "PGDATABASE is required in production when DATABASE_URL is not set"
      end

    true ->
      env.("PGDATABASE", "mondek_dev")
  end

database_pool_size =
  case Integer.parse(env.("MONDEK_DATABASE_POOL_SIZE", "12")) do
    {size, ""} when size > 0 -> size
    _ -> raise "MONDEK_DATABASE_POOL_SIZE must be a positive integer"
  end

config :mondek, Mondek.Repo,
  hostname: env.("PGHOST", "127.0.0.1"),
  port: String.to_integer(env.("PGPORT", if(production_database?, do: "5432", else: "55432"))),
  username: env.("PGUSER", "mondek"),
  password: database_password,
  database: db,
  pool_size: database_pool_size,
  show_sensitive_data_on_connection_error: false

# Postgrex does not interpret libpq's PGSSLMODE environment variable.
ssl_mode = env.("PGSSLMODE", nil)
ssl_root_cert = env.("PGSSLROOTCERT", nil)

url_tls_options =
  if database_url,
    do: URI.query_decoder(URI.parse(database_url).query || "") |> Enum.map(&elem(&1, 0)),
    else: []

if "sslmode" in url_tls_options do
  raise "DATABASE_URL sslmode is unsupported; use PGSSLMODE or ssl=true"
end

if (ssl_mode || ssl_root_cert) && "ssl" in url_tls_options do
  raise "Configure database TLS through PGSSLMODE or DATABASE_URL, not both"
end

ssl =
  case ssl_mode do
    nil ->
      nil

    "disable" ->
      false

    "require" ->
      [verify: :verify_none]

    mode when mode in ["verify-ca", "verify-full"] ->
      trust =
        if ssl_root_cert && ssl_root_cert != "",
          do: [cacertfile: ssl_root_cert],
          else: [cacerts: :public_key.cacerts_get()]

      if mode == "verify-ca",
        do: trust ++ [verify: :verify_peer, server_name_indication: :disable],
        else: trust ++ [verify: :verify_peer]

    _ ->
      raise "PGSSLMODE must be disable, require, verify-ca or verify-full"
  end

if ssl_root_cert && ssl_mode not in ["verify-ca", "verify-full"] do
  raise "PGSSLROOTCERT requires PGSSLMODE=verify-ca or verify-full"
end

if ssl != nil, do: config(:mondek, Mondek.Repo, ssl: ssl)
if database_url, do: config(:mondek, Mondek.Repo, url: database_url)

{:ok, bind_address} =
  env.("MONDEK_BIND_ADDRESS", "127.0.0.1")
  |> String.to_charlist()
  |> :inet.parse_address()

config :mondek, MondekWeb.Endpoint,
  http: [ip: bind_address, port: String.to_integer(env.("PORT", "4000"))],
  secret_key_base: secret_key_base

if deployment? do
  config :mondek, MondekWeb.Endpoint,
    url: [scheme: public_uri.scheme, host: public_uri.host, port: public_uri.port],
    check_origin: [URI.to_string(public_uri)]
else
  if config_env() == :prod,
    do: config(:mondek, MondekWeb.Endpoint, check_origin: false)
end

notification_adapter =
  case env.(
         "MONDEK_NOTIFICATION_ADAPTER",
         if(deployment?, do: "smtp", else: "webhook")
       ) do
    "smtp" -> :smtp
    "webhook" -> :webhook
    _ -> raise "MONDEK_NOTIFICATION_ADAPTER must be smtp or webhook"
  end

case env.("MONDEK_WEBHOOK_CONFIG_FILE", nil) do
  nil ->
    if deployment? and notification_adapter == :webhook,
      do: raise("MONDEK_WEBHOOK_CONFIG_FILE is required for deployment webhooks")

  path ->
    config :mondek, :webhook, Mondek.WebhookNotification.load!(path)
end

if notification_adapter == :smtp or env.("MONDEK_SMTP_HOST", nil) not in [nil, ""] do
  integer_env! = fn name, default ->
    case Integer.parse(env.(name, default)) do
      {value, ""} -> value
      _ -> raise "#{name} must be an integer"
    end
  end

  optional_env = fn name ->
    case env.(name, nil) do
      "" -> nil
      value -> value
    end
  end

  transport =
    case env.("MONDEK_SMTP_TRANSPORT", "plain") do
      "plain" -> :plain
      "starttls" -> :starttls
      "tls" -> :tls
      _ -> raise "MONDEK_SMTP_TRANSPORT must be plain, starttls or tls"
    end

  smtp =
    Mondek.NotificationDelivery.validate_config!(
      host: env.("MONDEK_SMTP_HOST", nil),
      port: integer_env!.("MONDEK_SMTP_PORT", "25"),
      transport: transport,
      username: optional_env.("MONDEK_SMTP_USERNAME"),
      password: optional_env.("MONDEK_SMTP_PASSWORD"),
      from: env.("MONDEK_SMTP_FROM", nil),
      to: env.("MONDEK_SMTP_TO", nil),
      timeout_ms: integer_env!.("MONDEK_SMTP_TIMEOUT_MS", "10000")
    )

  config :mondek, smtp: smtp
end

config :mondek,
  deployment_mode: deployment?,
  notification_adapter: notification_adapter,
  public_url: if(deployment?, do: URI.to_string(public_uri), else: nil),
  notification_max_attempts:
    env.("MONDEK_NOTIFICATION_MAX_ATTEMPTS", "100")
    |> String.to_integer()
    |> min(100)
    |> max(1),
  webhook_url: env.("MONDEK_WEBHOOK_URL", "http://127.0.0.1:58080/webhook")

for {setting, name, default} <- [
      {:monitoring_loss_grace_seconds, "MONDEK_MONITORING_LOSS_GRACE_SECONDS", "120"},
      {:monitoring_contact_seconds, "MONDEK_MONITORING_CONTACT_SECONDS", "60"}
    ] do
  value =
    case Integer.parse(env.(name, default)) do
      {seconds, ""} when seconds in 1..604_800 -> seconds
      _ -> raise "#{name} must be an integer from 1 to 604800 seconds"
    end

  config :mondek, setting, value
end

# Git access is opt-in and requires a deployment-local token for reads and writes.
configuration_git_token =
  case env.("MONDEK_CONFIGURATION_GIT_TOKEN", nil) do
    nil -> nil
    "" -> nil
    token when byte_size(token) >= 32 -> token
    _ -> raise "MONDEK_CONFIGURATION_GIT_TOKEN must contain at least 32 bytes"
  end

config :mondek, :configuration_git_token, configuration_git_token

retention =
  for {key, name, default, maximum} <- [
        {:receipt_days, "MONDEK_RETENTION_RECEIPT_DAYS", 7, 36500},
        {:history_days, "MONDEK_RETENTION_HISTORY_DAYS", 30, 36500},
        {:max_observations, "MONDEK_RETENTION_MAX_OBSERVATIONS", 100_000, 1_000_000_000}
      ],
      into: %{} do
    value =
      case Integer.parse(env.(name, to_string(default))) do
        {number, ""} when number >= 1 and number <= maximum -> number
        _ -> raise "#{name} must be an integer from 1 to #{maximum}"
      end

    {key, value}
  end

config :mondek, :retention, retention

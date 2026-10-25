# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.SMTPNotificationTest do
  use Mondek.DataCase, async: false
  import ExUnit.CaptureLog
  alias Mondek.NotificationDelivery, as: Delivery
  alias Mondek.NotificationWorker, as: Worker

  setup do
    keys = [:notification_adapter, :smtp, :public_url]
    original = Map.new(keys, &{&1, Application.fetch_env(:mondek, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:mondek, key, value)
        {key, :error} -> Application.delete_env(:mondek, key)
      end)
    end)

    Application.put_env(:mondek, :notification_adapter, :smtp)
    Application.put_env(:mondek, :public_url, "https://mondek.example.invalid")
    :ok
  end

  defp config(port) do
    [
      host: "127.0.0.1",
      port: port,
      transport: :plain,
      from: "mondek@example.invalid",
      to: "operator@example.invalid",
      username: nil,
      password: nil,
      timeout_ms: 1000
    ]
  end

  defp receiver(extra_env \\ []) do
    script = Path.expand("../../../tests/deployment/smtp_receiver.py", __DIR__)

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 8192},
        {:args, [script]},
        {:env,
         Enum.map(
           [
             {"SMTP_PORT", "0"},
             {"HTTP_PORT", "0"},
             {"FIXTURE_BIND", "127.0.0.1"},
             {"FIXTURE_EXIT_ON_STDIN_EOF", "true"}
           ] ++ extra_env,
           fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end
         )}
      ])

    on_exit(fn ->
      if Port.info(port), do: Port.close(port)
    end)

    assert_receive {^port, {:data, {:eol, ready}}}, 5000
    ports = Jason.decode!(ready)
    Application.put_env(:mondek, :smtp, config(ports["smtp_port"]))
    %{port: port, url: "http://127.0.0.1:#{ports["http_port"]}", smtp_port: ports["smtp_port"]}
  end

  defp request(receiver, path, body \\ nil) do
    url = String.to_charlist(receiver.url <> path)

    result =
      if body,
        do:
          :httpc.request(:post, {url, [], ~c"application/json", Jason.encode!(body)}, [],
            body_format: :binary
          ),
        else: :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert {:ok, {{_, 200, _}, _, response}} = result
    Jason.decode!(response)
  end

  defp fire(health \\ "CRIT") do
    connect()
    ingest(measurement(health))
    Repo.one!(Occurrence)
  end

  test "SMTP configuration refuses header injection, partial credentials and plaintext authentication without disclosing values" do
    options = config(2525)
    assert Delivery.validate_config!(options) == options

    for overrides <- [
          [from: "sender@example.invalid\r\nBcc: other@example.invalid"],
          [to: "first@example.invalid,second@example.invalid"],
          [to: "First Person <first@example.invalid>"],
          [host: "relay\nsecret"],
          [username: "dummy-sensitive-user", password: nil],
          [username: "dummy-sensitive-user", password: "dummy-sensitive-password"],
          [port: 0],
          [port: 65_536],
          [timeout_ms: 30_001]
        ] do
      error =
        assert_raise ArgumentError, fn ->
          Delivery.validate_config!(Keyword.merge(options, overrides))
        end

      refute Exception.message(error) =~ "dummy-sensitive"
    end
  end

  test "SMTP accepts one committed attempt and includes useful immutable incident context" do
    receiver = receiver()
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert job.args["delivery_channel"] == "smtp"
    assert :ok = Worker.perform(job)
    assert Repo.one!(Attempt).status == "accepted"
    assert Repo.one!(Attempt).http_status == nil
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    [record] = request(receiver, "/records")
    assert record["subject"] =~ "PROBLEM CRIT"
    assert record["body"] =~ "Real sample in contract fixture"
    assert record["body"] =~ "/incidents/#{occurrence.incident_id}"
    assert record["body"] =~ "2009-09-15T08:00:00.010000Z"
    assert record["occurrence_id"] == occurrence.id
    assert record["from"] == "mondek@example.invalid"
    assert record["to"] == "operator@example.invalid"
    assert record["raw"] == occurrence.payload["email"]["message"] <> "\r\n"

    changed_renderer_input =
      put_in(
        occurrence.payload,
        ["email", "summary"],
        "Later code would describe this differently"
      )

    assert Delivery.message(%{occurrence | payload: changed_renderer_input}) <> "\r\n" ==
             record["raw"]

    assert :ok = Worker.perform(job)
    assert request(receiver, "/state")["connections"] == 1
  end

  test "refusal is durable and sanitized; retry and measured recovery use real SMTP" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "refuse"})
    occurrence = fire()
    job = Repo.one!(Oban.Job)

    log = capture_log(fn -> assert {:error, _} = Worker.perform(job) end)
    refute log =~ "dummy-secret"
    attempt = Repo.one!(Attempt)
    assert attempt.status == "failed_or_ambiguous"
    refute attempt.error =~ "dummy-secret"
    assert Repo.get!(Occurrence, occurrence.id).status == "retrying"
    assert request(receiver, "/state")["connections"] == 1
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(job)
    ingest(measurement("OK", 2))
    recovery = Repo.one!(from o in Occurrence, where: o.kind == "resolved")

    recovery_job =
      Repo.one!(
        from j in Oban.Job, where: fragment("?->>'occurrence_id' = ?", j.args, ^recovery.id)
      )

    assert :ok = Worker.perform(recovery_job)
    [problem, recovered] = request(receiver, "/records")
    assert problem["occurrence_id"] == occurrence.id
    assert recovered["subject"] =~ "RECOVERED OK"
    refute recovered["subject"] =~ "CRIT"
    assert recovered["body"] =~ "Recovery measurement: OK"
    assert recovered["body"] =~ "Previous incident severity: CRIT"
    assert recovered["body"] =~ "Measured recovery"
    assert Repo.aggregate(Attempt, :count) == 3
  end

  test "lost reply can deliver twice with identical Message-ID and bytes despite changed runtime sender and destination" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "ambiguous"})
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, _} = Worker.perform(job)
    options = Application.fetch_env!(:mondek, :smtp)

    Application.put_env(
      :mondek,
      :smtp,
      Keyword.merge(options, from: "changed@example.invalid", to: "changed@example.invalid")
    )

    Application.put_env(:mondek, :public_url, "https://changed.example.invalid")
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(job)
    [first, second] = request(receiver, "/records")
    assert first["raw"] == second["raw"]
    assert first["message_id"] == "<#{occurrence.id}@mondek.invalid>"
    assert second["envelope_to"] == "<operator@example.invalid>"
    assert second["body"] =~ "https://mondek.example.invalid/"
  end

  test "total deadline bounds an ambiguous slow reply and leaves original budget inspectable" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "timeout"})
    occurrence = fire()
    job = %{Repo.one!(Oban.Job) | attempt: 1, max_attempts: 1}
    started = System.monotonic_time(:millisecond)
    assert {:error, "SMTP attempt timed out; relay acceptance is uncertain"} = Worker.perform(job)
    assert System.monotonic_time(:millisecond) - started < 2500
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert Repo.one!(Attempt).finished_at
    assert length(request(receiver, "/records")) == 1
  end

  test "SMTP retry delay is channel-specific and stays bounded across old webhook jobs" do
    assert Worker.backoff(%Oban.Job{attempt: 1, args: %{"delivery_channel" => "smtp"}}) == 30
    assert Worker.backoff(%Oban.Job{attempt: 30, args: %{"delivery_channel" => "smtp"}}) == 900
    assert Worker.backoff(%Oban.Job{attempt: 100, args: %{"delivery_channel" => "smtp"}}) == 900
    assert Worker.backoff(%Oban.Job{attempt: 1, args: %{}}) == 2
    assert Worker.backoff(%Oban.Job{attempt: 100, args: %{}}) == 30
  end

  test "oversized and unending multiline replies are bounded and leave recoverable attempt history" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "oversized"})
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, _} = Worker.perform(job)
    request(receiver, "/control", %{mode: "multiline"})
    options = Application.fetch_env!(:mondek, :smtp)
    Application.put_env(:mondek, :smtp, Keyword.put(options, :timeout_ms, 30_000))

    log =
      capture_log(fn ->
        {pid, monitor} = spawn_monitor(fn -> Worker.perform(job) end)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 15_000
      end)

    refute log =~ "dummy-secret"
    assert request(receiver, "/state")["reply_bytes"] < 40_000_000
    attempts = Repo.all(from a in Attempt, order_by: a.started_at)
    assert Enum.map(attempts, & &1.status) == ["failed_or_ambiguous", "started"]
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(job)
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
  end

  test "SMTP I/O follows commit and interrupted work reuses durable identity on a fresh execution" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "timeout"})
    occurrence = fire()
    options = Application.fetch_env!(:mondek, :smtp)
    Application.put_env(:mondek, :smtp, Keyword.put(options, :timeout_ms, 30_000))
    job = Repo.one!(Oban.Job)
    execution = Task.async(fn -> Worker.perform(job) end)

    assert Enum.reduce_while(1..100, false, fn _, _ ->
             if request(receiver, "/records") == [] do
               Process.sleep(10)
               {:cont, false}
             else
               {:halt, true}
             end
           end)

    # A separate process sees the committed attempt while the SMTP call is
    # still awaiting its reply, proving I/O does not hold the transaction open.
    assert Repo.one!(Attempt).status == "started"
    assert Repo.get!(Occurrence, occurrence.id).status == "delivering"
    assert Task.shutdown(execution, :brutal_kill) == nil
    assert Repo.one!(Attempt).status == "started"
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(job)
    assert Repo.aggregate(Attempt, :count) == 2
    [first, second] = request(receiver, "/records")
    assert first["raw"] == second["raw"]
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
  end

  test "manual retry keeps SMTP timing and original addressing after adapter configuration changes" do
    receiver = receiver()
    request(receiver, "/control", %{mode: "refuse"})
    occurrence = fire()
    job = %{Repo.one!(Oban.Job) | attempt: 1, max_attempts: 1}
    assert {:error, _} = Worker.perform(job)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "discarded"])
    Application.put_env(:mondek, :notification_adapter, :webhook)
    assert {:ok, _} = Monitoring.retry_notification(occurrence.id, "Local relay repaired", at())
    next = Repo.one!(from j in Oban.Job, where: j.id != ^job.id)
    assert next.args["delivery_channel"] == "smtp"
    assert Worker.backoff(%{next | attempt: 1}) == 30
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(next)
    [record] = request(receiver, "/records")
    assert record["to"] == "operator@example.invalid"
    assert record["occurrence_id"] == occurrence.id
  end

  defp tls_receiver(implicit? \\ false) do
    directory = Path.join(System.tmp_dir!(), "mondek-smtp-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    certificate = Path.join(directory, "certificate.pem")
    key = Path.join(directory, "key.pem")
    authority = Path.join(directory, "authority.pem")
    authority_key = Path.join(directory, "authority.key")
    request = Path.join(directory, "request.pem")
    extensions = Path.join(directory, "extensions.cnf")

    File.write!(
      extensions,
      "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
    )

    assert {_, 0} =
             System.cmd(
               System.find_executable("openssl"),
               [
                 "req",
                 "-x509",
                 "-newkey",
                 "rsa:2048",
                 "-nodes",
                 "-keyout",
                 authority_key,
                 "-out",
                 authority,
                 "-days",
                 "1",
                 "-subj",
                 "/CN=Mondek local test CA",
                 "-addext",
                 "basicConstraints=critical,CA:TRUE"
               ],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               System.find_executable("openssl"),
               [
                 "req",
                 "-new",
                 "-newkey",
                 "rsa:2048",
                 "-nodes",
                 "-keyout",
                 key,
                 "-out",
                 request,
                 "-subj",
                 "/CN=localhost"
               ],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               System.find_executable("openssl"),
               [
                 "x509",
                 "-req",
                 "-in",
                 request,
                 "-CA",
                 authority,
                 "-CAkey",
                 authority_key,
                 "-CAcreateserial",
                 "-out",
                 certificate,
                 "-days",
                 "1",
                 "-extfile",
                 extensions
               ],
               stderr_to_stdout: true
             )

    receiver =
      receiver([
        {"SMTP_CERT_FILE", certificate},
        {"SMTP_KEY_FILE", key},
        {"SMTP_IMPLICIT_TLS", to_string(implicit?)}
      ])

    options =
      Keyword.merge(config(receiver.smtp_port),
        host: "localhost",
        transport: if(implicit?, do: :tls, else: :starttls),
        timeout_ms: 3000
      )

    Application.put_env(:mondek, :smtp, options)
    {receiver, authority, options}
  end

  defp trust_fixture(certificate) do
    :public_key.cacerts_clear()
    :ok = :public_key.cacerts_load(String.to_charlist(certificate))
    [{:Certificate, der, _}] = certificate |> File.read!() |> :public_key.pem_decode()

    assert Enum.any?(:public_key.cacerts_get(), fn
             {:cert, ^der, _} -> true
             ^der -> true
             _ -> false
           end)

    on_exit(fn ->
      :public_key.cacerts_clear()
      :public_key.cacerts_load()
    end)
  end

  test "STARTTLS verifies trust and authenticates only after encryption; credential rejection stays secret-safe" do
    {receiver, certificate, options} = tls_receiver()
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, _} = Worker.perform(job)
    assert request(receiver, "/records") == []
    trust_fixture(certificate)

    options =
      Keyword.merge(options, username: "dummy-user", password: "dummy-secret-must-not-leak")

    Application.put_env(:mondek, :smtp, options)
    request(receiver, "/control", %{mode: "auth_refuse"})

    logs =
      capture_log(fn ->
        assert {:error, "SMTP authentication was rejected"} = Worker.perform(job)
      end)

    refute logs =~ "dummy-secret-must-not-leak"
    assert Enum.all?(Repo.all(Attempt), &(not String.contains?(&1.error || "", "dummy-secret")))
    request(receiver, "/control", %{mode: "accept"})
    assert :ok = Worker.perform(job)
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    assert length(request(receiver, "/records")) == 1
  end

  test "implicit TLS verifies hostname as well as the certificate trust chain" do
    {receiver, certificate, options} = tls_receiver(true)
    trust_fixture(certificate)
    fire()
    job = Repo.one!(Oban.Job)
    Application.put_env(:mondek, :smtp, Keyword.put(options, :host, "127.0.0.1"))
    assert {:error, _} = Worker.perform(job)
    assert request(receiver, "/records") == []
    Application.put_env(:mondek, :smtp, options)
    assert :ok = Worker.perform(job)
    assert length(request(receiver, "/records")) == 1
  end
end

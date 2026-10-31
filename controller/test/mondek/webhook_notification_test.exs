# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.WebhookReceiver do
  import Plug.Conn
  import Ecto.Query
  def init(options), do: options

  def call(conn, options) do
    {:ok, body, conn} = read_body(conn)
    id = get_req_header(conn, "x-mondek-occurrence") |> List.first()

    committed =
      Mondek.Repo.exists?(
        from a in Mondek.Attempt, where: a.occurrence_id == ^id and a.status == "started"
      )

    send(options[:owner], {:received, body, conn.req_headers, committed})
    if options[:delay], do: Process.sleep(options[:delay])

    conn =
      Enum.reduce(options[:headers] || [], conn, fn {key, value}, conn ->
        put_resp_header(conn, key, value)
      end)

    send_resp(conn, options[:status] || 204, options[:body] || "")
  end
end

defmodule Mondek.WebhookNotificationTest do
  use Mondek.DataCase, async: false

  alias Mondek.{
    WebhookNotification,
    NotificationTemplate,
    NotificationDelivery,
    NotificationWorker
  }

  setup do
    keys = [:notification_adapter, :webhook, :public_url]
    old = Map.new(keys, &{&1, Application.fetch_env(:mondek, &1)})

    directory =
      Path.join(System.tmp_dir!(), "mondek-webhook-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)

    on_exit(fn ->
      File.rm_rf!(directory)

      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:mondek, key, value)
          :error -> Application.delete_env(:mondek, key)
        end
      end
    end)

    Application.put_env(:mondek, :notification_adapter, :webhook)
    Application.put_env(:mondek, :public_url, "https://mondek.example.invalid")
    %{directory: directory}
  end

  defp configure(directory, url, extra \\ %{}) do
    file = Path.join(directory, "webhook.json")

    File.write!(
      file,
      Jason.encode!(%{
        "active" => "operations",
        "destinations" => %{"operations" => Map.merge(%{"url" => url}, extra)}
      })
    )

    File.chmod!(file, 0o600)
    config = WebhookNotification.load!(file)
    Application.put_env(:mondek, :webhook, config)
    config
  end

  defp receiver(options \\ [], tls \\ []) do
    pid =
      start_supervised!(
        {Bandit,
         [plug: {Mondek.WebhookReceiver, [owner: self()] ++ options}, ip: {127, 0, 0, 1}, port: 0] ++
           tls}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    "#{if tls == [], do: "http", else: "https"}://localhost:#{port}/notify?secret=dummy-token"
  end

  defp fire do
    connect()
    ingest(measurement("CRIT"))
    Repo.one!(Occurrence)
  end

  test "default JSON is frozen, secret-free, and delivered only after attempt commit", %{
    directory: directory
  } do
    url = receiver()
    configure(directory, url, %{"headers" => %{"Authorization" => "Bearer dummy-secret"}})
    occurrence = fire()
    assert occurrence.destination == "webhook:operations"
    refute Jason.encode!(occurrence.payload) =~ "dummy-token"
    refute Jason.encode!(occurrence.payload) =~ "dummy-secret"
    frozen = occurrence.payload["webhook_delivery"]["body"]
    assert Jason.decode!(frozen)["version"] == 1
    assert Repo.one!(Oban.Job).args["delivery_channel"] == "webhook_http"

    # A later template edit changes new deliveries only; credentials can rotate.
    configure(directory, url, %{
      "template" => "teams",
      "headers" => %{"Authorization" => "Bearer rotated"}
    })

    assert :ok = NotificationWorker.perform(Repo.one!(Oban.Job))
    assert_receive {:received, ^frozen, headers, true}
    assert {"authorization", "Bearer rotated"} in headers
    assert {"x-mondek-occurrence", occurrence.id} in headers
    assert Repo.get!(Occurrence, occurrence.id).status == "delivered"
    assert Repo.one!(Attempt).http_status == 204
  end

  test "changed URLs fail closed and retained destinations drain after active selection changes",
       %{directory: directory} do
    url = receiver()
    original = configure(directory, url)
    occurrence = fire()
    configure(directory, url <> "changed")
    assert {:error, :webhook_configuration_unavailable} = NotificationDelivery.deliver(occurrence)
    refute_receive {:received, _, _, _}, 50

    config = %{
      original
      | active: "next",
        destinations: Map.put(original.destinations, "next", original.destinations["operations"])
    }

    Application.put_env(:mondek, :webhook, config)
    assert {:ok, {{_, 204, _}, _, _}} = NotificationDelivery.deliver(occurrence)
    assert_receive {:received, _, _, false}
  end

  test "rate limits retain failed attempts and use bounded recorded retries", %{
    directory: directory
  } do
    url = receiver(status: 429, headers: [{"retry-after", "120"}], body: "dummy-secret")
    configure(directory, url)
    occurrence = fire()
    job = Repo.one!(Oban.Job)
    assert {:error, {:webhook_retry_after, 120}} = NotificationWorker.perform(job)
    assert Repo.get!(Occurrence, occurrence.id).status == "retrying"
    attempt = Repo.one!(Attempt)
    assert attempt.http_status == 429
    refute attempt.error =~ "dummy-secret"
    error = %Oban.PerformError{reason: {:error, {:webhook_retry_after, 120}}}
    assert NotificationWorker.backoff(%{job | attempt: 1, unsaved_error: %{reason: error}}) == 120
    assert NotificationWorker.backoff(%{job | attempt: 99}) == 900
  end

  test "redirects fail without reflecting private receiver content", %{
    directory: directory
  } do
    url =
      receiver(
        status: 302,
        headers: [{"location", "http://localhost:1/private"}],
        body: "dummy-secret"
      )

    configure(directory, url)
    occurrence = fire()

    assert {:error, "Receiver rejected delivery"} =
             NotificationWorker.perform(Repo.one!(Oban.Job))

    assert Repo.one!(Attempt).http_status == 302
    assert Repo.get!(Occurrence, occurrence.id).status == "retrying"
  end

  test "large response bodies are discarded without persisting private content", %{
    directory: directory
  } do
    url = receiver(body: String.duplicate("private-body", 100_000))
    configure(directory, url)
    fire()
    assert :ok = NotificationWorker.perform(Repo.one!(Oban.Job))
    assert Repo.one!(Attempt).error == nil
  end

  test "oversized headers are rejected", %{directory: directory} do
    url = receiver(headers: [{"x-private", String.duplicate("secret", 4000)}])
    configure(directory, url)
    fire()
    assert {:error, _} = NotificationWorker.perform(Repo.one!(Oban.Job))
    refute Repo.one!(Attempt).error =~ "secret"
  end

  test "total request deadline bounds a stalled receiver", %{directory: directory} do
    url = receiver(delay: 2000)
    configure(directory, url, %{"timeout_ms" => 1000})
    fire()
    start = System.monotonic_time(:millisecond)
    assert {:error, _} = NotificationWorker.perform(Repo.one!(Oban.Job))
    assert System.monotonic_time(:millisecond) - start < 1800
  end

  test "template failures preserve real monitoring state and become inspectable exhausted deliveries",
       %{directory: directory} do
    template = Path.join(directory, "large.json")

    File.write!(
      template,
      Jason.encode!(%{
        "text" => %{"$concat" => List.duplicate(%{"$ref" => "notification.summary"}, 400)}
      })
    )

    configure(directory, "http://localhost:1/webhook", %{"template" => template})
    connect()
    report = measurement("CRIT")

    report =
      update_in(report, ["results"], fn results ->
        Enum.map(results, &Map.put(&1, "summary", String.duplicate("x", 1000)))
      end)

    assert disposition(ingest(report)) == "current"
    occurrence = Repo.one!(Occurrence)
    assert occurrence.payload["webhook_delivery"]["render_error"]
    assert Repo.exists?(Incident)
    job = Repo.one!(Oban.Job)
    assert {:discard, _} = NotificationWorker.perform(job)
    assert Repo.get!(Occurrence, occurrence.id).status == "exhausted"
    assert Repo.one!(Attempt).error =~ "template"
  end

  test "TLS trusts configured CA, rejects hostname mismatch and untrusted certificates", %{
    directory: directory
  } do
    key = Path.join(directory, "server.key")
    cert = Path.join(directory, "server.crt")

    ca = Path.join(directory, "ca.crt")
    ca_key = Path.join(directory, "ca.key")
    csr = Path.join(directory, "server.csr")
    extensions = Path.join(directory, "extensions")
    File.write!(extensions, "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n")

    for args <- [
          [
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            ca_key,
            "-out",
            ca,
            "-days",
            "1",
            "-subj",
            "/CN=Mondek-test-CA"
          ],
          [
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            key,
            "-out",
            csr,
            "-subj",
            "/CN=localhost"
          ],
          [
            "x509",
            "-req",
            "-in",
            csr,
            "-CA",
            ca,
            "-CAkey",
            ca_key,
            "-CAcreateserial",
            "-out",
            cert,
            "-days",
            "1",
            "-extfile",
            extensions
          ]
        ],
        do: assert({_, 0} = System.cmd("openssl", args, stderr_to_stdout: true))

    url = receiver([], scheme: :https, certfile: cert, keyfile: key)
    configure(directory, url, %{"cacertfile" => ca})
    occurrence = fire()
    assert :ok = NotificationWorker.perform(Repo.one!(Oban.Job))
    configure(directory, String.replace(url, "localhost", "127.0.0.1"), %{"cacertfile" => ca})
    # Create a fresh snapshot for the changed destination; avoid fingerprint rejection.
    {payload, destination} =
      NotificationDelivery.snapshot(
        Map.delete(occurrence.payload, "webhook_delivery"),
        "Example",
        "Finding",
        "CRIT"
      )

    assert {:error, :webhook_transport_failed} =
             NotificationDelivery.deliver(%{
               occurrence
               | payload: payload,
                 destination: destination
             })

    configure(directory, url)
    assert {:error, :webhook_transport_failed} = NotificationDelivery.deliver(occurrence)
  end

  test "configuration errors and template errors do not disclose supplied secrets", %{
    directory: directory
  } do
    for extra <- [
          %{"url" => "http://external.invalid/private"},
          %{"headers" => %{"Host" => "dummy-secret"}},
          %{"headers" => %{"Authorization" => "secret\r\nInjected: yes"}},
          %{"timeout_ms" => 99},
          %{"url" => "https://user:dummy-secret@host/path"},
          %{"template" => "missing-private-path"}
        ] do
      error =
        assert_raise ArgumentError, fn ->
          configure(directory, "https://receiver.invalid/secret", extra)
        end

      refute Exception.message(error) =~ "dummy-secret"
      refute Exception.message(error) =~ "missing-private-path"
    end
  end

  test "Teams renders all notification events with escaped content and recovery meaning" do
    template = NotificationTemplate.load!(WebhookNotification.teams_path())

    for {event, document} <- WebhookNotification.examples() do
      document = put_in(document, ["notification", "summary"], "Quotes: \"hello\"\nUnicode: ☃")
      rendered = NotificationTemplate.render!(template, document) |> Jason.decode!()
      card = hd(rendered["attachments"])["content"]
      assert Enum.at(card["body"], 1)["text"] == document["notification"]["summary"]
      assert hd(card["actions"])["url"] == document["incident"]["url"]

      if event == "recovered" do
        facts = Enum.at(card["body"], 2)["facts"]
        assert hd(facts)["value"] == "OK"
      end

      if event in ["monitoring_lost", "monitoring_restored"],
        do: assert(is_nil(document["evidence"]["health"]))
    end
  end

  test "templates support typed values, conditionals and bounded iteration without executable evaluation" do
    template = %{
      "items" => %{
        "$each" => "items",
        "template" => %{"$concat" => ["Value: ", %{"$ref" => "item"}]}
      },
      "optional" => %{"$if" => "missing", "then" => "yes", "else" => nil}
    }

    assert Jason.decode!(
             NotificationTemplate.render!(template, %{"items" => ["one", "two"], "missing" => nil})
           ) == %{"items" => ["Value: one", "Value: two"], "optional" => nil}

    assert_raise ArgumentError, fn -> NotificationTemplate.render!(%{"$ref" => "typo"}, %{}) end

    assert_raise ArgumentError, fn ->
      NotificationTemplate.render!(%{"$ref" => "x", "extra" => true}, %{"x" => 1})
    end

    assert_raise ArgumentError, fn ->
      NotificationTemplate.render!(%{"$ref" => "large"}, %{
        "large" => String.duplicate("x", 300_000)
      })
    end

    assert_raise ArgumentError, fn ->
      NotificationTemplate.render!(%{"$each" => "items", "template" => true}, %{
        "items" => Enum.to_list(1..101)
      })
    end
  end
end

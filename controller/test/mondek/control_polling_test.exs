# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ControlPollingTest do
  use Mondek.DataCase, async: false
  alias Mondek.{Runner, SourceInventory}
  alias Mondek.CoverageFixtures, as: F

  setup do
    pid = start_supervised!({Bandit, plug: MondekWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {:ok, previous} = :httpc.get_options([:max_sessions])
    :ok = :httpc.set_options(max_sessions: 32)
    on_exit(fn -> :httpc.set_options(previous) end)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "concurrent runner polls ignore peer heartbeats, observations and inventory and release database locks",
       %{url: url} do
    callers = for index <- 1..8, do: observer("Waiting #{index}")
    polls = Enum.map(callers, &poll(url, &1, 4))
    wait_for_poll_count(8)

    # A waiting HTTP request must not retain its runner row or pool connection.
    assert {:ok, 8} =
             Repo.transaction(fn ->
               Repo.all(
                 from r in Runner,
                   where: fragment("?->>'poll' = 'waiting'", r.status),
                   lock: "FOR UPDATE NOWAIT"
               )
               |> length()
             end)

    peer = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(peer)
    assert {:ok, _} = F.activate(peer, Monitoring.now())

    for sequence <- 1..4 do
      assert {:ok, _} = F.activate(peer, Monitoring.now())
      assert disposition(F.sample(peer, "OK", sequence, Monitoring.now())) == "current"
      assert {:ok, _} = Monitoring.inventory(peer)
    end

    assert Enum.all?(Task.yield_many(polls, 300), fn {_, reply} -> is_nil(reply) end)

    for task <- polls do
      assert {{200, %{"assignments" => []}}, elapsed} = Task.await(task, 6_000)
      assert elapsed >= 3_800
    end
  end

  test "a committed owner configuration wakes only that runner and inventory withdrawal wakes its publisher",
       %{url: url} do
    local = control(%{"runner_label" => "Local"}) |> stable_caller()
    assert {:ok, _} = Monitoring.control(local)
    publisher = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(publisher)
    assert {:ok, _} = F.activate(publisher, Monitoring.now())

    published = F.assignments(publisher) |> hd()
    remote = observer("Remote", publisher)
    remote = remote |> Map.put("prepared", %{published.id => 1}) |> stable_caller()
    local_poll = poll(url, Map.update!(local, "installation_id", &String.upcase/1), 5)
    remote_poll = poll(url, remote, 5)
    wait_for_poll_count(2)

    local_check = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    assert {:ok, _} =
             Monitoring.save_assignment(
               "10000000-0000-4000-8000-000000000001",
               local_check.revision,
               Map.put(local_check.params, "warn_percent", 70)
             )

    assert {{200, local_response}, _} = Task.await(local_poll, 1_500)

    assert Enum.find(
             local_response["assignments"],
             &(&1["id"] == "10000000-0000-4000-8000-000000000001")
           )["generation"] ==
             2

    assert Task.yield(remote_poll, 200) == nil

    withdrawn =
      publisher
      |> Map.put("inventory_revision", 2)
      |> Map.put("checks", [])
      |> put_in(["coverage", "candidates"], [])

    assert {:ok, _} = Monitoring.inventory(withdrawn)
    assert {{200, %{"assignments" => []}}, _} = Task.await(remote_poll, 1_500)
    assert Repo.get!(Assignment, published.id).retired_at
  end

  test "timeout rereads committed state even without a wake signal and revalidates session ownership",
       %{url: url} do
    local = control() |> stable_caller()
    assert {:ok, _} = Monitoring.control(local)
    task = poll(url, local, 1)
    wait_for_poll_count(1)
    a = Repo.get!(Assignment, "10000000-0000-4000-8000-000000000001")

    # Model a missed PubSub signal: committed durable state remains authoritative.
    assert {:ok, _} =
             Repo.transaction(fn ->
               Monitoring.update_configuration!(
                 a,
                 Map.put(a.params, "warn_percent", 70),
                 Monitoring.now()
               )
             end)

    assert {{200, response}, elapsed} = Task.await(task, 2_000)
    assert elapsed >= 900

    assert Enum.find(
             response["assignments"],
             &(&1["id"] == "10000000-0000-4000-8000-000000000001")
           )["generation"] == 2

    Repo.update_all(Runner, set: [status: %{}])

    local =
      local
      |> put_in(["active", "10000000-0000-4000-8000-000000000001"], 2)
      |> put_in(["prepared", "10000000-0000-4000-8000-000000000001"], 2)

    expired = poll(url, local, 1)
    wait_for_poll_count(1)
    Repo.update_all(Runner, set: [boot: 2, session_id: Ecto.UUID.generate()])
    assert {{409, %{"error" => _}}, elapsed} = Task.await(expired, 2_000)
    assert elapsed >= 900
  end

  test "publisher retirement and restore signal only committed owner control changes" do
    publication = F.publication([F.candidate(F.check())])
    assert {:ok, _} = Monitoring.inventory(publication)
    source = Repo.one!(SourceInventory)

    Phoenix.PubSub.subscribe(
      Mondek.PubSub,
      Monitoring.control_topic(publication["installation_id"])
    )

    on_exit(fn ->
      Phoenix.PubSub.unsubscribe(
        Mondek.PubSub,
        Monitoring.control_topic(publication["installation_id"])
      )
    end)

    proposal = %{
      "publisher_id" => source.id,
      "action" => "retire",
      "reason" => "Retire publisher"
    }

    # Validation failure cannot wake polling runners.
    assert {:error, _} =
             Monitoring.save_assignment("10000000-0000-4000-8000-000000000001", 999, %{})

    refute_receive :control_changed, 30

    assert {:ok, preview} = Mondek.PublisherLifecycle.preview(proposal)
    assert {:ok, _} = Mondek.PublisherLifecycle.apply(preview["review_token"], proposal)
    assert_receive :control_changed

    restore = %{
      proposal
      | "action" => "restore",
        "reason" => "Restore publisher"
    }

    assert {:ok, preview} = Mondek.PublisherLifecycle.preview(restore)
    assert {:ok, _} = Mondek.PublisherLifecycle.apply(preview["review_token"], restore)
    assert_receive :control_changed
  end

  defp observer(label, identity \\ %{}) do
    control(%{
      "installation_id" => identity["installation_id"] || Ecto.UUID.generate(),
      "session_id" => identity["session_id"] || Ecto.UUID.generate(),
      "runner_label" => label,
      "prepared" => %{},
      "active" => %{}
    })
  end

  test "already pending adoption returns without spending the long poll budget", %{url: url} do
    assert {{200, %{"assignments" => assignments}}, elapsed} =
             Task.await(poll(url, control(), 5), 1_500)

    assert assignments != []
    assert elapsed < 1_000
  end

  test "pending publisher restoration returns immediately for an otherwise adopted runner",
       %{url: url} do
    publication = F.publication([])
    assert {:ok, _} = Monitoring.inventory(publication)
    source = Repo.one!(SourceInventory)
    caller = observer("Restoring observer", publication)

    # Commit lifecycle changes before the HTTP request subscribes, so only the
    # durable refresh request can shorten this otherwise steady empty poll.
    for action <- ~w(retire restore) do
      proposal = %{
        "publisher_id" => source.id,
        "action" => action,
        "reason" => "Exercise pending restoration"
      }

      assert {:ok, preview} = Mondek.PublisherLifecycle.preview(proposal)
      assert {:ok, _} = Mondek.PublisherLifecycle.apply(preview["review_token"], proposal)
    end

    restored = Repo.get!(SourceInventory, source.id)
    assert restored.retired_at == nil
    assert restored.resume_after_revision == publication["inventory_revision"]

    assert {{200, response}, elapsed} = Task.await(poll(url, caller, 5), 1_500)
    assert response["assignments_authoritative"] == true
    assert response["assignments"] == []
    assert caller["active"] == %{} and caller["prepared"] == %{}

    assert response["inventory_refresh"] == %{
             publication["source_id"] => %{
               "after_revision" => restored.resume_after_revision,
               "lifecycle_revision" => restored.lifecycle_revision
             }
           }

    assert elapsed < 1_000
  end

  test "contact window bounds steady waiting including one second settings", %{url: url} do
    old = Application.get_env(:mondek, :monitoring_contact_seconds)

    on_exit(fn ->
      if old == nil,
        do: Application.delete_env(:mondek, :monitoring_contact_seconds),
        else: Application.put_env(:mondek, :monitoring_contact_seconds, old)
    end)

    Application.put_env(:mondek, :monitoring_contact_seconds, 1)
    assert {{200, _}, elapsed} = Task.await(poll(url, observer("Short contact"), 5), 1_500)
    assert elapsed < 1_000
    Application.put_env(:mondek, :monitoring_contact_seconds, 3)
    assert {{200, _}, elapsed} = Task.await(poll(url, observer("Three second contact"), 5), 2_000)
    assert elapsed >= 900 and elapsed < 1_800
  end

  defp stable_caller(caller), do: Map.put(caller, "active", caller["prepared"])

  defp poll(url, caller, seconds) do
    Task.async(fn ->
      started = System.monotonic_time(:millisecond)

      body =
        caller |> Map.put("wait_seconds", seconds) |> Map.put("status", %{"poll" => "waiting"})

      {:ok, {{_, status, _}, _, json}} =
        :httpc.request(
          :post,
          {String.to_charlist(url <> "/api/v1/control"), [], ~c"application/json",
           Jason.encode!(body)},
          [timeout: 8_000],
          body_format: :binary
        )

      {{status, Jason.decode!(json)}, System.monotonic_time(:millisecond) - started}
    end)
  end

  defp wait_for_poll_count(count, attempts \\ 100)

  defp wait_for_poll_count(_count, 0),
    do: flunk("HTTP control requests did not commit their initial contact")

  defp wait_for_poll_count(count, attempts) do
    current =
      Repo.aggregate(
        from(r in Runner, where: fragment("?->>'poll' = 'waiting'", r.status)),
        :count
      )

    if current != count do
      Process.sleep(10)
      wait_for_poll_count(count, attempts - 1)
    end
  end
end

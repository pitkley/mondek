# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.CorrelationProviderDecisionsTest do
  use Mondek.DataCase, async: false

  alias Mondek.{CorrelationCase, CorrelationDecision, CoverageFixtures, Correlations}
  alias Mondek.CorrelationProviderDecisions, as: Decisions
  @moduletag :empty_source_fixture

  setup do
    path = Path.join(System.tmp_dir!(), "mondek-provider-decision-#{Ecto.UUID.generate()}.json")
    on_exit(fn -> File.rm(path) end)

    raw = %{
      "id" => "fixture",
      "url" => "https://example.invalid/advice",
      "binding_key" => String.duplicate("k", 32),
      "evidence" => ["dimensions", "timing", "health"]
    }

    File.write!(path, Jason.encode!(raw))
    File.chmod!(path, 0o600)
    previous = Application.fetch_env(:mondek, :correlation_decisions_config)
    Application.put_env(:mondek, :correlation_decisions_config, path)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:mondek, :correlation_decisions_config, old)
        _ -> Application.delete_env(:mondek, :correlation_decisions_config)
      end
    end)

    parent = episode("upstream", "up")
    child = episode("app", "child")
    %{path: path, raw: raw, child: child, parent: parent, id: Ecto.UUID.generate()}
  end

  defp episode(name, target) do
    check = CoverageFixtures.check(name, nil, target)

    hint = %{
      "dimension" => "network",
      "window_seconds" => 10,
      "depends_on" => %{
        "type" => "target",
        "source_id" => "coverage-test",
        "kind" => "service",
        "key" => "up"
      }
    }

    check =
      if name == "app",
        do: update_in(check["outputs"], fn [o] -> [Map.put(o, "correlation_hints", [hint])] end),
        else: check

    pub =
      CoverageFixtures.publication([CoverageFixtures.candidate(check)]) |> Map.delete("coverage")

    assert {:ok, _} = Monitoring.inventory(pub, at())
    CoverageFixtures.activate(pub, at())
    CoverageFixtures.sample(pub, "CRIT", 1, at())
    [assignment] = CoverageFixtures.assignments(pub)
    %{"type" => "individual", "id" => Repo.get_by!(Incident, assignment_id: assignment.id).id}
  end

  defp request(c) do
    p = %{"subject" => c.child, "request_id" => c.id}
    assert {:ok, row} = Decisions.request(p, at())
    assert {:ok, ^row} = Decisions.request(p, at())

    assert {:error, :already_pending} =
             Decisions.request(%{p | "request_id" => Ecto.UUID.generate()}, at())

    assert {:ok, {:post, _, lease, bytes, expiry}} = Decisions.admit(c.id, at())
    {lease, bytes, expiry}
  end

  defp suggestion(id, bytes) do
    [candidate] = Jason.decode!(bytes)["candidates"]

    Jason.encode!(%{
      version: 1,
      request_id: id,
      outcome: "suggest",
      candidate: candidate["handle"],
      reason: "Shared network",
      confidence: 0.75
    })
  end

  test "leased work restarts with exact frozen bytes and identity, one advisory result and reviewed case",
       c do
    occurrences = Repo.all(from o in Occurrence, order_by: o.id)
    {first, bytes, expiry} = request(c)
    refute bytes =~ c.child["id"]
    refute bytes =~ c.parent["id"]
    refute bytes =~ "coverage-test"

    assert [%{"dimensions" => ["network"], "health" => "CRIT", "timing" => ["overlap"]}] =
             Jason.decode!(bytes)["candidates"]

    assert {:ok, {:wait, _}} = Decisions.admit(c.id, DateTime.add(at(), 1))
    later = DateTime.add(at(), 31)
    assert {:ok, {:post, _, second, ^bytes, ^expiry}} = Decisions.admit(c.id, later)
    refute first == second
    reply = {:ok, suggestion(c.id, bytes)}
    assert {:error, :stale_attempt} = Decisions.complete(c.id, first, reply, later)

    assert {:ok, %{"status" => "proposed"} = saved} =
             Decisions.complete(c.id, second, reply, later)

    assert saved["resolved_at"] == Monitoring.iso(later)
    assert {:ok, ^saved} = Decisions.complete(c.id, second, reply, DateTime.add(later, 1))
    assert {:error, :conflicting_reply} = Decisions.complete(c.id, second, {:ok, "{}"}, later)
    assert Repo.aggregate(CorrelationCase, :count) == 0
    assert occurrences == Repo.all(from o in Occurrence, order_by: o.id)
    assert {:ok, review} = Decisions.preview(c.id, later)
    token = review["review_token"]
    assert {:error, :invalid_review} = Correlations.apply(token, later)

    assert {:ok, {_, native}} =
             Phoenix.Token.verify(MondekWeb.Endpoint, "provider-grouping-review-v1", token)

    assert {:error, :invalid_review} = Correlations.apply(native, later)
    assert {:ok, %{"case_id" => case_id}} = Decisions.apply(token, later)

    assert {:ok, %{"replayed" => true, "case_id" => ^case_id}} =
             Decisions.apply(review["review_token"], later)

    assert Repo.one!(CorrelationDecision).change["proposal"]["request_id"] == c.id
  end

  test "revoking disclosure after review blocks apply and persists disposition", c do
    {lease, bytes, _} = request(c)

    assert {:ok, %{"status" => "proposed"}} =
             Decisions.complete(c.id, lease, {:ok, suggestion(c.id, bytes)}, at())

    assert {:ok, review} = Decisions.preview(c.id, at())
    File.write!(c.path, Jason.encode!(%{c.raw | "evidence" => []}))
    assert {:error, :review_changed} = Decisions.apply(review["review_token"], at())
    File.write!(c.path, Jason.encode!(c.raw))

    assert %{"items" => [%{"status" => "revoked"}]} =
             Decisions.list("individual", c.child["id"], 1, at())

    refute Correlations.membership("individual", c.child["id"])
  end

  test "explicit browser disclosure consent is bound to the displayed policy", c do
    {:ok, config} = Mondek.CorrelationDecisionProvider.configuration()
    fingerprint = Mondek.CorrelationDecisionProvider.fingerprint(config)
    p = %{"subject" => c.child, "request_id" => c.id}
    File.write!(c.path, Jason.encode!(%{c.raw | "evidence" => []}))
    assert {:error, :review_changed} = Decisions.request_reviewed(p, fingerprint, at())
    assert Repo.aggregate(Mondek.CorrelationProviderDecision, :count) == 0
    File.write!(c.path, Jason.encode!(c.raw))
    assert {:ok, %{"status" => "pending"}} = Decisions.request_reviewed(p, fingerprint, at())
  end

  test "changed destination blocks readmission", c do
    {lease, _, _} = request(c)
    assert {:ok, :retry} = Decisions.complete(c.id, lease, {:error, :retryable}, at())
    File.write!(c.path, Jason.encode!(%{c.raw | "url" => "https://other.invalid/"}))
    assert {:ok, %{"status" => "revoked"}} = Decisions.admit(c.id, at())
  end

  test "expired response preserves original deadline", c do
    {lease, bytes, expiry} = request(c)

    assert {:ok, %{"status" => "expired"}} =
             Decisions.complete(c.id, lease, {:ok, suggestion(c.id, bytes)}, expiry)
  end

  test "selector revalidation rejects a recovered parent", c do
    {lease, bytes, _} = request(c)

    from(i in Incident, where: i.id == ^c.parent["id"])
    |> Repo.update_all(set: [status: "closed"])

    assert {:ok, %{"status" => "stale"}} =
             Decisions.complete(c.id, lease, {:ok, suggestion(c.id, bytes)}, at())
  end

  test "invalid reason and foreign handle cannot create a proposal", c do
    for bad <- [
          %{"reason" => <<0>>},
          %{"reason" => c.raw["binding_key"]},
          %{"candidate" => c.child["id"]}
        ] do
      c = %{c | id: Ecto.UUID.generate()}
      {lease, bytes, _} = request(c)
      reply = suggestion(c.id, bytes) |> Jason.decode!() |> Map.merge(bad) |> Jason.encode!()

      assert {:ok, %{"status" => "invalid", "reason" => nil}} =
               Decisions.complete(c.id, lease, {:ok, reply}, at())
    end
  end

  test "standalone and abstain leave operator and delivery authority untouched", c do
    original = Repo.all(from o in Occurrence, order_by: o.id)

    for {outcome, status} <- [{"standalone", "standalone"}, {"abstain", "abstained"}] do
      c = %{c | id: Ecto.UUID.generate()}
      {lease, _, _} = request(c)
      reply = Jason.encode!(%{version: 1, request_id: c.id, outcome: outcome})
      assert {:ok, %{"status" => ^status}} = Decisions.complete(c.id, lease, {:ok, reply}, at())
      assert {:error, :not_reviewable} = Decisions.preview(c.id, at())
    end

    assert %{"revision" => 0} = Mondek.CorrelationAutomationPolicy.override(c.child)
    assert original == Repo.all(from o in Occurrence, order_by: o.id)
    assert Repo.aggregate(CorrelationCase, :count) == 0
  end

  test "reviewed attachment uses the frozen existing parent case", c do
    other = episode("other", "other")

    proposal = %{
      "request_id" => Ecto.UUID.generate(),
      "action" => "create",
      "episodes" => [other, c.parent],
      "anchor" => other,
      "title" => "Existing case",
      "reason" => "Reviewed grouping"
    }

    {:ok, review} = Correlations.preview(proposal, at())
    {:ok, %{"case_id" => case_id}} = Correlations.apply(review["review_token"], at())
    {lease, bytes, _} = request(c)

    {:ok, %{"status" => "proposed"}} =
      Decisions.complete(c.id, lease, {:ok, suggestion(c.id, bytes)}, at())

    assert {:ok, %{"proposal" => %{"action" => "attach"}, "review_token" => token}} =
             Decisions.preview(c.id, at())

    assert {:ok, %{"case_id" => ^case_id}} = Decisions.apply(token, at())
  end
end

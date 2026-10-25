# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.DiscoveryConfiguration do
  @moduledoc "Declared resource ownership and accepted selection evidence; never executes source code."
  import Ecto.Query

  alias Mondek.{
    Assignment,
    Configuration,
    ConfigurationRules,
    DiscoveryChange,
    Monitoring,
    Parameters,
    Repo
  }

  def validate_inventory(p) do
    checks = p["checks"]
    by_key = Map.new(checks, &{&1["key"], &1})

    Enum.all?(checks, fn check ->
      case check["discovery"] do
        nil ->
          true

        %{"version" => 1, "kind" => "manager", "capability" => "linux.resources.v1"} = d ->
          map_size(d) == 3 and check["params_owner"] == "ui" and
            check["parameter_contract"] == "mondek.linux.discovery.v1" and
            Parameters.text?(check["environment"], 128) and length(check["outputs"]) == 1 and
            is_map(get_in(check, ["outputs", Access.at(0), "target"]))

        %{
          "version" => 1,
          "kind" => "resource",
          "manager_key" => key,
          "resource_kind" => kind,
          "resource_name" => name,
          "origin" => origin
        } = d ->
          manager = by_key[key]

          map_size(d) == 6 and kind in ~w(interface filesystem) and
            origin in ~w(required discovered) and
            Parameters.text?(name, 2048) and manager != nil and key != check["key"] and
            get_in(manager, ["discovery", "kind"]) == "manager" and
            manager["environment"] == check["environment"]

        _ ->
          false
      end
    end) and valid_selections?(p["catalog_selections"], by_key)
  end

  defp valid_selections?(nil, _), do: true

  defp valid_selections?(items, checks) when is_map(items) and map_size(items) <= 512 do
    Enum.all?(items, fn {key, selection} ->
      manager = checks[key]

      is_map(selection) and manager != nil and get_in(manager, ["discovery", "kind"]) == "manager" and
        Map.keys(selection) -- ~w(status params assignment_id generation) == [] and
        selection["status"] in ~w(accepted failed) and
        Parameters.validate(manager["parameter_schema"], selection["params"]) == :ok and
        ((is_nil(selection["assignment_id"]) and is_nil(selection["generation"])) or
           (Mondek.Protocol.assignment_id?(selection["assignment_id"]) and
              is_integer(selection["generation"]) and selection["generation"] > 0))
    end)
  end

  defp valid_selections?(_, _), do: false

  def validate_retention!(p, existing) do
    incoming = MapSet.new(p["checks"], & &1["key"])

    for row <- existing,
        row.discovery["origin"] == "discovered",
        get_in(p, ["catalog_selections", row.discovery["manager_key"], "status"]) == "failed",
        not MapSet.member?(incoming, row.source_key) do
      Repo.rollback(
        {:invalid, "Failed discovery must retain the previously accepted optional resources."}
      )
    end
  end

  def observer_count(manager) do
    target = get_in(manager, ["outputs", Access.at(0), "target"])

    Repo.one(
      from a in Assignment,
        where:
          a.source_id == ^manager["source_id"] and
            a.parameter_contract == ^manager["parameter_contract"] and
            a.environment == ^manager["environment"] and is_nil(a.retired_at),
        where:
          fragment(
            "?->>'key' = ? AND ?->>'kind' = ?",
            fragment("(?)[1]->'target'", a.outputs),
            ^target["key"],
            fragment("(?)[1]->'target'", a.outputs),
            ^target["kind"]
          ),
        select: count(a.runner_id, :distinct)
    )
  end

  def context(id) do
    row = if Mondek.Protocol.assignment_id?(id), do: Repo.get(Assignment, id)

    case row do
      %Assignment{discovery: %{"kind" => "manager"}} ->
        %{manager: Monitoring.assignment_detail(row.id), resource: nil}

      %Assignment{discovery: %{"kind" => "resource", "manager_key" => key}} ->
        manager =
          Repo.one(
            from(a in Assignment,
              where:
                a.runner_id == ^row.runner_id and a.source_id == ^row.source_id and
                  a.source_key == ^key and is_nil(a.retired_at)
            )
          )

        if manager && manager.environment == row.environment &&
             manager.discovery["kind"] == "manager",
           do: %{
             manager: Monitoring.assignment_detail(manager.id),
             resource: Monitoring.public(row)
           }

      _ ->
        nil
    end
  end

  def host_proposal(manager, params) do
    with {:ok, seed} <- ConfigurationRules.seed(manager["id"]) do
      origin = manager["configuration_origin"] || %{}

      existing =
        if origin["kind"] == "rule", do: Repo.get(Mondek.ConfigurationRule, origin["rule_id"])

      exact? =
        existing && existing.environment == seed["environment"] &&
          existing.target_kind == seed["target_kind"] && existing.target_key == seed["target_key"]

      proposal = if exact?, do: ConfigurationRules.public_rule(existing), else: seed
      {:ok, Map.put(proposal, "params", params)}
    end
  end

  def host_shadowed?(preview, proposal) do
    (get_in(preview, ["counts", "shadowed"]) || 0) > 0 or
      Enum.any?(preview["rows"] || [], fn row ->
        not row["instance_exception"] and is_nil(row["error"]) and
          get_in(row, ["origin", "kind"]) == "rule" and
          get_in(row, ["origin", "rule_id"]) !=
            (proposal["id"] || "00000000-0000-0000-0000-000000000000")
      end)
  end

  def save(context, scope, preview, proposal \\ nil) do
    result =
      Repo.transaction(fn ->
        if scope == "host" and host_shadowed?(preview, proposal),
          do:
            Repo.rollback(
              {:conflict,
               "Another shared rule remains effective. Inspect that rule or choose this discovery check only."}
            )

        result =
          if scope == "host",
            do: ConfigurationRules.apply(preview["review_token"], proposal),
            else: ConfigurationRules.apply_instance(preview["review_token"])

        saved =
          case result do
            {:ok, saved} -> saved
            {:error, reason} -> Repo.rollback(reason)
          end

        members =
          if scope == "host",
            do: saved["receipts"],
            else: [%{"id" => saved["id"], "target_generation" => saved["desired_generation"]}]

        members =
          Enum.map(members, fn member ->
            row = Repo.get!(Assignment, member["id"])

            %{
              "id" => row.id,
              "generation" => member["target_generation"],
              "runner_id" => row.runner_id,
              "source_key" => row.source_key,
              "origin" =>
                if(scope == "host",
                  do: %{
                    "kind" => "rule",
                    "rule_id" => saved["rule"]["id"],
                    "rule_revision" => saved["rule"]["revision"]
                  },
                  else: row.configuration_origin
                ),
              "status" => "waiting"
            }
          end)

        supersede_pending!(context.manager["source_id"], Enum.map(members, & &1["id"]))

        Repo.insert!(%DiscoveryChange{
          assignment_id: context.manager["id"],
          source_id: context.manager["source_id"],
          scope: scope,
          params: preview["proposed_params"] || proposal["params"],
          members: members,
          resource:
            (context.resource || %{})
            |> Map.take(~w(discovery source_key))
            |> Map.put(
              "subject",
              Map.take(context.manager, ~w(label environment environment_label outputs))
            ),
          saved_at: Monitoring.now()
        })
      end)

    if match?({:ok, _}, result) do
      Monitoring.notify()
      Monitoring.notify_control()
    end

    result
  end

  # Called in the inventory transaction. Completed receipts remain historical;
  # a later edit cannot rewrite their observed outcome.
  def reconcile!(p, at) do
    changes =
      Repo.all(
        from(c in DiscoveryChange,
          where: c.source_id == ^p["source_id"] and c.pending,
          order_by: c.id,
          lock: "FOR UPDATE"
        )
      )

    for change <- changes do
      members =
        Enum.map(change.members, fn member ->
          if member["runner_id"] == p["installation_id"] and
               member["status"] in ~w(waiting refresh_failed) do
            selection = get_in(p, ["catalog_selections", member["source_key"]])
            row = Repo.get(Assignment, member["id"])

            cond do
              is_nil(row) or row.retired_at ->
                Map.put(member, "status", "superseded")

              change.scope == "host" and is_map(row.instance_exception) ->
                member

              not Parameters.same_json?(row.params, change.params) ->
                Map.put(member, "status", "superseded")

              not same_origin?(row.configuration_origin, member["origin"]) ->
                Map.put(member, "status", "superseded")

              is_nil(selection) or selection["assignment_id"] != row.id ->
                member

              not is_integer(selection["generation"]) or
                  selection["generation"] < member["generation"] ->
                member

              not Parameters.same_json?(selection["params"], change.params) ->
                member

              not valid_configuration?(
                row.id,
                selection["generation"],
                change.params,
                member["origin"]
              ) ->
                member

              selection["status"] == "failed" ->
                Map.put(member, "status", "refresh_failed")

              true ->
                resource = get_in(change.resource, ["discovery"])

                present =
                  if resource,
                    do:
                      Enum.any?(p["checks"], fn check ->
                        d = check["discovery"] || %{}

                        d["manager_key"] == row.source_key and
                          d["resource_kind"] == resource["resource_kind"] and
                          d["resource_name"] == resource["resource_name"]
                      end),
                    else: nil

                Map.merge(member, %{
                  "status" => "inventory_accepted",
                  "resource_present" => present,
                  "inventory_revision" => p["inventory_revision"],
                  "accepted_at" => DateTime.to_iso8601(at)
                })
            end
          else
            member
          end
        end)

      if members != change.members,
        do:
          Monitoring.change(change, %{
            members: members,
            pending: Enum.any?(members, &(&1["status"] in ~w(waiting refresh_failed)))
          })
    end
  end

  defp valid_configuration?(id, generation, params, origin) do
    case Repo.get_by(Configuration, assignment_id: id, generation: generation) do
      nil ->
        false

      config ->
        Parameters.same_json?(config.params, params) and
          same_origin?(config.definition["configuration_origin"], origin)
    end
  end

  defp same_origin?(a, b),
    do:
      Map.take(a || %{}, ~w(kind rule_id rule_revision)) ==
        Map.take(b || %{}, ~w(kind rule_id rule_revision))

  defp supersede_pending!(source, ids) do
    for change <-
          Repo.all(
            from c in DiscoveryChange,
              where: c.source_id == ^source and c.pending,
              order_by: c.id,
              lock: "FOR UPDATE"
          ) do
      members =
        Enum.map(change.members, fn member ->
          if member["id"] in ids and member["status"] in ~w(waiting refresh_failed),
            do: Map.put(member, "status", "superseded"),
            else: member
        end)

      if members != change.members,
        do:
          Monitoring.change(change, %{
            members: members,
            pending: Enum.any?(members, &(&1["status"] in ~w(waiting refresh_failed)))
          })
    end
  end

  defp resource_stream(change, member) do
    case change.resource["discovery"] do
      %{"resource_kind" => kind, "resource_name" => name} ->
        Repo.one(
          from s in Mondek.ResultStream,
            join: a in Assignment,
            on: s.assignment_id == a.id,
            where: a.runner_id == ^member["runner_id"] and a.source_id == ^change.source_id,
            where:
              fragment(
                "?->>'manager_key' = ? AND ?->>'resource_kind' = ? AND ?->>'resource_name' = ?",
                a.discovery,
                ^member["source_key"],
                a.discovery,
                ^kind,
                a.discovery,
                ^name
              ),
            order_by: [desc_nulls_first: a.retired_at],
            limit: 1,
            select: s.id
        )

      _ ->
        nil
    end
  end

  def receipt(id) do
    if match?({:ok, _}, Ecto.UUID.cast(id)) do
      case Repo.get(DiscoveryChange, id) do
        nil ->
          nil

        change ->
          %{
            change: change,
            historical?:
              Repo.exists?(
                from c in DiscoveryChange,
                  where:
                    c.assignment_id == ^change.assignment_id and c.saved_at > ^change.saved_at
              ),
            members:
              Enum.map(change.members, fn member ->
                row = Monitoring.assignment_detail(member["id"])

                status =
                  cond do
                    member["status"] not in ~w(waiting refresh_failed) ->
                      member["status"]

                    is_nil(row) or row["retired"] ->
                      "superseded"

                    is_map(row["instance_exception"]) and change.scope == "host" ->
                      "masked"

                    not Parameters.same_json?(row["params"], change.params) ->
                      "superseded"

                    not same_origin?(row["configuration_origin"], member["origin"]) ->
                      "superseded"

                    member["status"] == "refresh_failed" ->
                      "refresh_failed"

                    row["active_generation"] != row["desired_generation"] ->
                      "activation_pending"

                    true ->
                      "inventory_pending"
                  end

                %{
                  receipt: member,
                  assignment: row,
                  status: status,
                  resource_stream_id: resource_stream(change, member)
                }
              end)
          }
      end
    end
  end
end

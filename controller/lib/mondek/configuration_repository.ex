# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationRepository do
  @moduledoc "Database-authoritative Git history, committed atomically with operator settings."
  import Ecto.Query

  alias Mondek.{
    Repo,
    Assignment,
    ConfigurationRule,
    ConfigurationObjects,
    ConfigurationPolicyProject
  }

  @lock 774_020
  @rule_fields ~w(name source_id parameter_contract environment target_kind target_key priority enabled parameter_schema params managed_project managed_key)a

  def transaction(channel, fun) do
    if Process.get(__MODULE__) do
      Repo.transaction(fun)
    else
      Repo.transaction(fn ->
        lock!()
        Process.put(__MODULE__, true)

        try do
          initialize!()
          before = snapshot!()
          result = fun.()
          after_files = snapshot!()

          if before != after_files do
            if channel != "policy", do: advance_projects!(before, after_files)
            record!(after_files, channel, "#{channel}: update configuration")
          end

          result
        after
          Process.delete(__MODULE__)
        end
      end)
    end
  end

  def accept_push(expected_head, candidate) do
    result =
      Repo.transaction(fn ->
        lock!()
        initialize!()

        if head!() != expected_head,
          do:
            Repo.rollback({:invalid, "Configuration changed; fetch and reconcile before pushing"})

        before = snapshot!()
        Mondek.ConfigurationImport.apply!(candidate.files)
        after_files = snapshot!()
        # Imported formatting remains clonable; compare normalized document values.
        decode = fn files ->
          Map.new(files, fn {path, body} -> {path, Jason.decode!(body)} end)
        end

        if decode.(candidate.files) != decode.(after_files),
          do:
            Repo.rollback(
              {:invalid, "Configuration is not representable without changing identity or scope"}
            )

        advance_projects!(before, after_files)

        persist!(
          candidate.head,
          expected_head,
          candidate.objects,
          candidate.files,
          "git",
          "Accept Git configuration push"
        )

        %{head: candidate.head}
      end)

    if match?({:ok, _}, result) do
      Mondek.Monitoring.notify()
      Mondek.Monitoring.notify_control()
    end

    result
  end

  def lock!, do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock])

  def state do
    Repo.transaction(fn ->
      lock!()
      initialize!()

      [[id, head]] =
        Repo.query!("SELECT installation_id::text, head FROM configuration_repository WHERE id=1").rows

      %{installation_id: id, head: head, files: current_files!()}
    end)
  end

  def objects do
    Map.new(Repo.query!("SELECT oid, kind, body FROM configuration_git_objects").rows, fn [
                                                                                            oid,
                                                                                            kind,
                                                                                            body
                                                                                          ] ->
      {oid, {kind, body}}
    end)
  end

  def history(limit \\ 25) do
    Repo.query!(
      "SELECT head,parent,channel,message,inserted_at FROM configuration_revisions ORDER BY id DESC LIMIT $1",
      [min(max(limit, 1), 100)]
    ).rows
    |> Enum.map(fn [head, parent, channel, message, at] ->
      %{head: head, parent: parent, channel: channel, message: message, inserted_at: at}
    end)
  end

  def head!,
    do: Repo.query!("SELECT head FROM configuration_repository WHERE id=1").rows |> hd() |> hd()

  def current_files!,
    do:
      Repo.query!("SELECT files FROM configuration_revisions WHERE head=$1", [head!()]).rows
      |> hd()
      |> hd()

  def initialize! do
    if Repo.query!("SELECT id FROM configuration_repository WHERE id=1").rows == [] do
      Repo.query!(
        "INSERT INTO configuration_repository(id,installation_id) VALUES (1,$1::uuid)",
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      )

      record!(snapshot!(), "migration", "Import existing controller configuration")
    end
  end

  def snapshot! do
    # Stable keys are independent of database IDs after import; old rows receive
    # an initial key once, without changing settings or effective generations.
    Repo.query!(
      "UPDATE configuration_rules SET repository_key='rule-' || id::text WHERE repository_key IS NULL"
    )

    rules =
      Repo.all(ConfigurationRule)
      |> Map.new(fn rule ->
        value =
          Map.new(@rule_fields, &{Atom.to_string(&1), Map.get(rule, &1)})
          |> Map.put("key", rule.repository_key)

        {"rules/#{rule.repository_key}.json", ConfigurationObjects.json(value)}
      end)

    Repo.query!(
      "UPDATE assignments SET configuration_exception_key=id::text WHERE instance_exception IS NOT NULL AND configuration_exception_key IS NULL"
    )

    exceptions =
      Repo.all(from a in Assignment, where: not is_nil(a.instance_exception))
      |> Map.new(fn row ->
        value = %{
          "key" => row.configuration_exception_key,
          "installation_specific" => true,
          "scope" => %{
            "assignment_id" => row.id,
            "runner_installation_id" => row.runner_id,
            "source_id" => row.source_id,
            "check_key" => row.source_key
          },
          "parameter_contract" => row.parameter_contract,
          "parameter_schema" => row.parameter_schema,
          "params" => row.instance_exception,
          "environment" => row.environment,
          "outputs" =>
            Enum.map(row.outputs, fn output ->
              %{"key" => output["key"], "target" => Map.take(output["target"], ~w(kind key))}
            end)
        }

        {"exceptions/#{row.configuration_exception_key}.json", ConfigurationObjects.json(value)}
      end)

    Map.merge(rules, exceptions)
    |> Map.put("mondek.json", ConfigurationObjects.json(%{"version" => 1}))
  end

  def record!(files, channel, message) do
    parent = head!()
    at = DateTime.utc_now()
    {head, objects} = ConfigurationObjects.commit(files, parent, message, at)
    persist!(head, parent, objects, files, channel, message, at)
    head
  end

  def persist!(head, parent, objects, files, channel, message, at \\ DateTime.utc_now()) do
    Enum.each(objects, fn {oid, {kind, body}} ->
      Repo.insert_all("configuration_git_objects", [%{oid: oid, kind: kind, body: body}],
        on_conflict: :nothing,
        conflict_target: [:oid]
      )
    end)

    Repo.insert_all("configuration_revisions", [
      %{
        head: head,
        parent: parent,
        files: files,
        channel: channel,
        message: message,
        inserted_at: at
      }
    ])

    Repo.query!("UPDATE configuration_repository SET head=$1 WHERE id=1", [head])
  end

  defp advance_projects!(before, after_files) do
    projects =
      [before, after_files]
      |> Enum.flat_map(fn files ->
        Enum.flat_map(files, fn {path, body} ->
          if String.starts_with?(path, "rules/") and
               Map.get(before, path) != Map.get(after_files, path),
             do: [Jason.decode!(body)["managed_project"]],
             else: []
        end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    for project <- projects do
      Repo.insert!(%ConfigurationPolicyProject{id: project, revision: 1},
        on_conflict: [inc: [revision: 1]],
        conflict_target: [:id]
      )
    end
  end
end

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.MaintenanceProjects.Project do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "maintenance_projects" do
    field :revision, :integer
    field :receipt, :map
  end
end

defmodule Mondek.MaintenanceProjects.Schedule do
  use Ecto.Schema
  @primary_key false
  schema "managed_maintenance_schedules" do
    field :project, :string, primary_key: true
    field :key, :string, primary_key: true
    field :series_id, :binary_id
    field :proposal, :map
    field :active, :boolean, default: true
  end
end

defmodule Mondek.MaintenanceProjects do
  @moduledoc "Reviewed complete declarations for project-owned recurring schedules."
  import Ecto.Query
  import Kernel, except: [apply: 2, apply: 3]

  alias Mondek.{
    ConfigurationRules,
    Maintenance,
    MaintenanceSchedules,
    MaintenanceSelection,
    MaintenanceSeries,
    Monitoring,
    Repo
  }

  alias __MODULE__.{Project, Schedule}

  @fields ~w(name reason timezone starts_local ends_local start_fold end_fold selections recurrence)
  @limit 8
  @window_limit 128
  @salt "maintenance-project-review"

  def export(project) do
    Repo.transaction(fn ->
      Maintenance.lock!(:shared)
      project = identifier!(project)
      current(project, Repo.get(Project, project), schedules(project))
    end)
  end

  def plan(manifest, base, at \\ nil) do
    Repo.transaction(fn ->
      Maintenance.lock!(:shared)
      manifest = normalize!(manifest)
      project = Repo.get(Project, manifest["project"])
      context = prepare!(manifest, project, base, at || Monitoring.now())

      review = %{
        "manifest" => digest(manifest),
        "state" => digest(context.public),
        "base" => base
      }

      Map.put(
        context.public,
        "review_token",
        Phoenix.Token.sign(MondekWeb.Endpoint, @salt, review)
      )
    end)
  end

  def apply(token, manifest, at \\ nil) do
    result =
      Repo.transaction(fn ->
        Maintenance.lock!()
        manifest = normalize!(manifest)
        review = verify!(token)
        if review["manifest"] != digest(manifest), do: Repo.rollback(:review_changed)
        project = Repo.get(Project, manifest["project"])
        token_digest = digest(token)

        case project do
          %{receipt: %{"token" => ^token_digest, "result" => result}} ->
            result

          _ ->
            at = at || Monitoring.now()
            context = prepare!(manifest, project, review["base"], at)

            rows = for %{prepared: %{rows: rows}} <- context.changes, row <- rows, do: row
            Maintenance.series_lock_assignments!(rows)
            context = prepare!(manifest, project, review["base"], at)
            if review["state"] != digest(context.public), do: Repo.rollback(:review_changed)
            persist!(manifest, project, context, token_digest, at)
        end
      end)

    if match?({:ok, _}, result), do: Monitoring.notify()
    result
  end

  defp prepare!(manifest, project, base, at) do
    items = schedules(manifest["project"])
    snapshot = current(manifest["project"], project, items)
    wanted = Map.new(manifest["schedules"], &{&1["key"], &1["proposal"]})

    active = Map.new(for {item, _} <- items, item.active, do: {item.key, item.proposal})
    changed? = wanted != active

    if (not is_nil(base) or (not is_nil(project) and changed?)) and base != snapshot["revision"],
      do: Repo.rollback(:stale)

    sources =
      for proposal <- Map.values(wanted) ++ Enum.map(items, fn {item, _} -> item.proposal end),
          selector <- proposal["selections"],
          do: selector["source_id"]

    Enum.each(Enum.sort(Enum.uniq(sources)), &ConfigurationRules.lock_source!/1)

    existing = Map.new(items, fn {item, series} -> {item.key, {item, series}} end)
    active_keys = for {item, _} <- items, item.active, do: item.key
    keys = Enum.sort(Enum.uniq(Map.keys(wanted) ++ active_keys))

    if map_size(existing) + Enum.count(Map.keys(wanted), &(!Map.has_key?(existing, &1))) > 64,
      do:
        invalid!(
          "A maintenance project supports at most 64 different schedule keys over its lifetime."
        )

    changes =
      for key <- keys do
        desired = wanted[key]
        {item, series} = Map.get(existing, key, {nil, nil})

        cond do
          item && item.active && item.proposal == desired ->
            %{key: key, action: "unchanged", item: item}

          true ->
            retirement = if series, do: MaintenanceSchedules.managed_retirement!(series, at)

            prepared =
              if desired,
                do:
                  desired
                  |> Map.merge(%{"scope" => "selection", "start_mode" => "scheduled"})
                  |> MaintenanceSchedules.managed_preview!(at)

            protection =
              if not is_nil(prepared) and not is_nil(item),
                do: MaintenanceSchedules.managed_protection!(manifest["project"], key, at)

            validate_replacement!(prepared, protection)

            action =
              if item && item.active,
                do: if(desired, do: "replace", else: "remove"),
                else: "create"

            %{
              key: key,
              action: action,
              item: item,
              retirement: retirement,
              prepared: prepared,
              protection: protection
            }
        end
      end

    impacts = Enum.map(changes, &impact/1)

    if Enum.sum(Enum.map(changes, &window_count/1)) > @window_limit or
         byte_size(Jason.encode!(impacts)) > 262_144,
       do: invalid!("The project review exceeds its window or response size limit.")

    %{
      changes: changes,
      changed?: changed?,
      public:
        Map.merge(snapshot, %{
          "changes" => impacts,
          "overlapping_schedules" => planned_overlaps(changes)
        })
    }
  end

  defp validate_replacement!(%{windows: [first | _]}, %{through: %DateTime{} = through}) do
    {:ok, starts_at, _} = DateTime.from_iso8601(first["starts_at"])

    if DateTime.before?(starts_at, through),
      do:
        invalid!(
          "The replacement must start after the protected windows and original exception dates."
        )
  end

  defp validate_replacement!(_, _), do: :ok

  defp window_count(%{action: "unchanged"}), do: 0

  defp window_count(change) do
    created = if change.prepared, do: length(change.prepared.windows), else: 0
    cancelled = if change.retirement, do: length(change.retirement.upcoming), else: 0
    created + cancelled
  end

  defp impact(%{action: "unchanged"} = change),
    do: %{"key" => change.key, "action" => change.action, "series_id" => change.item.series_id}

  defp impact(change),
    do: %{
      "key" => change.key,
      "action" => change.action,
      "retire" => change.retirement && change.retirement.impact,
      "create" => change.prepared && change.prepared.impact,
      "protected_windows" => change.protection && change.protection.windows
    }

  defp planned_overlaps(changes) do
    planned = Enum.filter(changes, &(&1[:prepared] != nil))

    for left <- planned,
        right <- planned,
        left.key < right.key,
        scopes_overlap?(left.prepared.scope.selections, right.prepared.scope.selections),
        Enum.any?(left.prepared.windows, fn a ->
          Enum.any?(right.prepared.windows, fn b ->
            DateTime.before?(parse(a["starts_at"]), parse(b["ends_at"])) and
              DateTime.before?(parse(b["starts_at"]), parse(a["ends_at"]))
          end)
        end),
        do: [left.key, right.key]
  end

  defp scopes_overlap?(left, right) do
    Enum.any?(left, fn a ->
      Enum.any?(right, fn b ->
        Map.take(a, ~w(source_id source_key environment)) ==
          Map.take(b, ~w(source_id source_key environment)) and
          (is_nil(a["target_kind"]) or is_nil(b["target_kind"]) or
             Map.take(a, ~w(target_kind target_key)) == Map.take(b, ~w(target_kind target_key)))
      end)
    end)
  end

  defp persist!(_manifest, _project, %{changed?: false} = context, _token, _at),
    do: context.public

  defp persist!(manifest, project, context, token_digest, at) do
    id = manifest["project"]
    project = project || Repo.insert!(%Project{id: id, revision: 0})

    wanted = Map.new(manifest["schedules"], &{&1["key"], &1["proposal"]})

    scopes =
      for change <- context.changes, change.action != "unchanged" do
        owner = %{"project" => id, "key" => change.key}
        retire? = change.action in ["remove", "replace"]

        if retire?,
          do:
            MaintenanceSchedules.managed_retire!(
              change.retirement,
              "Updated by maintenance project #{id}",
              owner,
              at
            )

        if change.prepared do
          series = MaintenanceSchedules.managed_create!(change.prepared, owner, at)
          attrs = %{series_id: series.id, proposal: wanted[change.key], active: true}

          if change.item do
            Repo.update!(Ecto.Changeset.change(change.item, attrs))
          else
            Repo.insert!(struct(Schedule, Map.merge(attrs, %{project: id, key: change.key})))
          end
        else
          Repo.update!(Ecto.Changeset.change(change.item, active: false))
        end

        if(retire?, do: [change.retirement.scope], else: []) ++
          if(change.prepared, do: [change.prepared.scope], else: [])
      end

    Maintenance.series_wake_many!(List.flatten(scopes))

    revision = project.revision + 1
    result = current(id, %{project | revision: revision}, schedules(id))

    project
    |> Ecto.Changeset.change(
      revision: revision,
      receipt: %{"token" => token_digest, "result" => result}
    )
    |> Repo.update!()

    result
  end

  defp schedules(project) do
    Repo.all(
      from m in Schedule,
        left_join: s in MaintenanceSeries,
        on: s.id == m.series_id,
        where: m.project == ^project,
        order_by: m.key,
        select: {m, s}
    )
  end

  defp current(id, project, rows) do
    versions =
      Enum.map(rows, fn {item, series} ->
        %{
          "key" => item.key,
          "series_id" => item.series_id,
          "revision" => series && series.revision,
          "active" => item.active
        }
      end)

    %{
      "revision" => digest({id, if(project, do: project.revision, else: 0), versions}),
      "manifest" => %{
        "version" => 1,
        "project" => id,
        "schedules" =>
          for(
            {item, _} <- rows,
            item.active,
            do: %{"key" => item.key, "proposal" => item.proposal}
          )
      },
      "schedules" => Enum.filter(versions, & &1["active"]),
      "archived_keys" => Enum.reject(versions, & &1["active"])
    }
  end

  defp normalize!(%{"version" => 1, "project" => project, "schedules" => schedules} = doc)
       when map_size(doc) == 3 and is_list(schedules) and length(schedules) <= @limit do
    canonical = schedules |> Enum.map(&schedule!/1) |> Enum.sort_by(& &1["key"])

    if length(Enum.uniq_by(canonical, & &1["key"])) != length(canonical),
      do: invalid!("Schedule keys must be distinct.")

    %{doc | "project" => identifier!(project), "schedules" => canonical}
  end

  defp normalize!(_),
    do: invalid!("Supply a version 1 project with at most eight complete schedules.")

  defp schedule!(%{"key" => key, "proposal" => proposal} = item)
       when map_size(item) == 2 and is_map(proposal) do
    selectors = proposal["selections"]

    if Enum.sort(Map.keys(proposal)) != Enum.sort(@fields) or not is_list(selectors) or
         length(selectors) not in 1..32 or not MaintenanceSelection.valid?(selectors) or
         Enum.any?(selectors, fn selector ->
           selector["scope"] != "stable_check" or
             Enum.any?(
               Map.keys(selector),
               &(not Map.has_key?(MaintenanceSelection.identity(selector), &1))
             )
         end),
       do:
         invalid!(
           "Each schedule needs complete civil times, recurrence and exact stable check selections."
         )

    %{
      "key" => identifier!(key),
      "proposal" => %{proposal | "selections" => MaintenanceSelection.normalize(selectors)}
    }
  end

  defp schedule!(_), do: invalid!("Each schedule needs a key and a proposal.")

  defp identifier!(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/, value),
      do: value,
      else: invalid!("Use a stable project or schedule key.")
  end

  defp identifier!(_), do: invalid!("Use a stable project or schedule key.")

  defp verify!(token) when is_binary(token) and byte_size(token) < 4096 do
    case Phoenix.Token.verify(MondekWeb.Endpoint, @salt, token, max_age: 900) do
      {:ok, review} -> review
      {:error, :expired} -> Repo.rollback(:review_expired)
      _ -> Repo.rollback(:invalid_review)
    end
  end

  defp verify!(_), do: Repo.rollback(:invalid_review)
  defp parse(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp invalid!(message), do: Repo.rollback({:invalid, message})
end

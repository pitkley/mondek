# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Read trusted project/lock files without compiling or starting the application.
Mix.start()

result =
  Mix.Project.in_project(:mondek, "controller", fn _ ->
    locks = Mix.Dep.Lock.read()

    roots =
      for dep <- Mix.Project.config()[:deps],
          opts = if(tuple_size(dep) == 3, do: elem(dep, 2), else: []),
          :prod in List.wrap(Keyword.get(opts, :only, :prod)),
          do: elem(dep, 0)

    expand = fn expand, pending, seen ->
      case pending do
        [] ->
          seen

        [name | rest] ->
          if MapSet.member?(seen, name) do
            expand.(expand, rest, seen)
          else
            {:hex, _, _, _, _, children, _, _} = Map.fetch!(locks, name)
            children = for {child, _, opts} <- children, not opts[:optional], do: child
            expand.(expand, children ++ rest, MapSet.put(seen, name))
          end
      end
    end

    production = expand.(expand, roots, MapSet.new())

    for {name, {:hex, package, version, _, _, _, "hexpm", checksum}} <- locks do
      path = Path.join(Mix.Project.deps_path(), Atom.to_string(name))
      {:ok, terms} = :file.consult(String.to_charlist(Path.join(path, "hex_metadata.config")))
      metadata = Map.new(terms)
      ^version = metadata["version"]
      true = metadata["name"] == Atom.to_string(package)

      %{
        name: Atom.to_string(name),
        version: version,
        licenses: metadata["licenses"],
        source: "https://repo.hex.pm/tarballs/#{package}-#{version}.tar",
        checksum: checksum,
        scope: if(MapSet.member?(production, name), do: "controller", else: "controller-test"),
        path: Path.relative_to(path, File.cwd!())
      }
    end
    |> then(fn entries ->
      true = length(entries) == map_size(locks)
      Enum.sort_by(entries, & &1.name)
    end)
  end)

IO.puts(JSON.encode!(result))

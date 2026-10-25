# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationGit do
  @moduledoc "Bounded, disposable Git plumbing. The caller owns durable acceptance of returned objects."
  @limit 8_388_608
  @count 10_000
  @repository_limit 268_435_456
  @repository_count 250_000
  @zero String.duplicate("0", 40)
  @ref "refs/heads/main"

  def advertise(objects, head, service) when service in ["git-upload-pack", "git-receive-pack"] do
    repository(objects, head, fn path ->
      with {:ok, output} <-
             git(path, [
               String.replace_prefix(service, "git-", ""),
               "--stateless-rpc",
               "--advertise-refs",
               path
             ]) do
        {:ok, packet("# service=#{service}\n") <> "0000" <> output}
      end
    end)
  end

  def upload(objects, head, body) when byte_size(body) <= @limit,
    do:
      repository(
        objects,
        head,
        &git(&1, ["upload-pack", "--stateless-rpc", &1], body, repository_limit())
      )

  def upload(_, _, _), do: {:error, "Git request exceeds limit"}

  def receive(objects, head, body) when byte_size(body) <= @limit do
    with {:ok, old, new} <- command(body),
         true <-
           old == (head || @zero) ||
             {:error, "Configuration changed; fetch and reconcile before pushing"} do
      repository(objects, head, fn path ->
        with {:ok, response} <- git(path, ["receive-pack", "--stateless-rpc", path], body),
             {:ok, actual} <- git(path, ["rev-parse", @ref]),
             true <- String.trim(actual) == new || {:error, "Git rejected the update"},
             :ok <- fast_forward(path, head, new),
             {:ok, snapshot} <- snapshot(path, new, head, objects) do
          {:ok, Map.put(snapshot, :response, response)}
        end
      end)
    end
  end

  def receive(_, _, _), do: {:error, "Git request exceeds limit"}

  def rejection(body, reason) do
    reason = reason |> String.replace(~r/[\r\n\x00-\x1f]/, " ") |> String.slice(0, 500)
    report = packet("unpack ok\n") <> packet("ng #{@ref} #{reason}\n") <> "0000"

    if String.contains?(binary_part(body, 0, min(byte_size(body), 512)), "side-band-64k"),
      do: packet(<<1>> <> report) <> "0000",
      else: report
  end

  defp command(body) do
    with {:ok, line, rest} <- take_packet(body),
         true <- String.starts_with?(rest, "0000") || {:error, "Push exactly one update to main"},
         [update | _] <- :binary.split(line, <<0>>),
         [old, new, @ref] <- String.split(String.trim(update), " "),
         true <- oid?(old) and oid?(new),
         true <- new != @zero || {:error, "Deleting main is not supported"},
         true <-
           old != new ||
             {:error,
              "Main already has this revision; fetch to confirm the accepted configuration"} do
      {:ok, old, new}
    else
      {:error, _} = error -> error
      _ -> {:error, "Only one refs/heads/main update is supported"}
    end
  end

  defp take_packet(<<length::binary-size(4), rest::binary>>) do
    case Integer.parse(length, 16) do
      {n, ""} when n >= 4 and n <= byte_size(rest) + 4 ->
        <<line::binary-size(^n - 4), tail::binary>> = rest
        {:ok, line, tail}

      _ ->
        {:error, "Invalid Git packet"}
    end
  end

  defp take_packet(_), do: {:error, "Invalid Git packet"}

  defp packet(data),
    do:
      ((byte_size(data) + 4)
       |> Integer.to_string(16)
       |> String.downcase()
       |> String.pad_leading(4, "0")) <> data

  defp oid?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
  defp fast_forward(_, nil, _), do: :ok

  defp fast_forward(path, old, new) do
    case git(path, ["merge-base", "--is-ancestor", old, new]) do
      {:ok, _} -> :ok
      _ -> {:error, "Non-fast-forward push; fetch and reconcile configuration"}
    end
  end

  defp repository(objects, head, operation) when map_size(objects) <= @repository_count do
    path =
      Path.join(
        System.tmp_dir!(),
        "mondek-git-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)

    previous_deadline =
      Process.put({__MODULE__, :deadline}, System.monotonic_time(:millisecond) + 60_000)

    try do
      with true <- is_nil(head) or oid?(head),
           {:ok, _} <- git(path, ["init", "--bare", "--initial-branch=main", path]),
           :ok <- put_objects(path, objects),
           :ok <- set_head(path, head) do
        operation.(path)
      else
        false -> {:error, "Invalid repository head"}
        error -> error
      end
    after
      if previous_deadline,
        do: Process.put({__MODULE__, :deadline}, previous_deadline),
        else: Process.delete({__MODULE__, :deadline})

      File.rm_rf(path)
    end
  end

  defp repository(_, _, _),
    do:
      {:error,
       "Repository exceeds 250000 objects; configuration remains saved, but Git export needs capacity review"}

  defp set_head(_, nil), do: :ok
  defp set_head(path, head), do: File.write(Path.join(path, @ref), head <> "\n")

  defp put_objects(path, objects) do
    Enum.reduce_while(objects, 0, fn {oid, object}, bytes ->
      {type, body} =
        case object do
          %{type: t, body: b} -> {t, b}
          {t, b} -> {t, b}
        end

      raw = "#{type} #{byte_size(body)}\0" <> body

      cond do
        System.monotonic_time(:millisecond) >= Process.get({__MODULE__, :deadline}) ->
          {:halt, {:error, "Repository materialization timed out; configuration remains saved"}}

        bytes + byte_size(raw) <= repository_limit() and type in ["blob", "tree", "commit"] and
          oid?(oid) and Base.encode16(:crypto.hash(:sha, raw), case: :lower) == oid ->
          file = Path.join([path, "objects", String.slice(oid, 0, 2), String.slice(oid, 2, 38)])
          File.mkdir_p!(Path.dirname(file))
          File.write!(file, :zlib.compress(raw))
          {:cont, bytes + byte_size(raw)}

        true ->
          {:halt,
           {:error,
            "Invalid Git object or repository capacity exceeded; configuration remains saved; increase configuration_git_repository_bytes after capacity review"}}
      end
    end)
    |> case do
      count when is_integer(count) -> :ok
      error -> error
    end
  end

  defp snapshot(path, head, previous, existing) do
    revisions = if previous, do: [head, "^" <> previous], else: [head]

    with {:ok, commits} <- git(path, ["rev-list", "--max-count=1001"] ++ revisions),
         true <-
           length(String.split(commits, "\n", trim: true)) <= 1000 ||
             {:error, "Push introduces more than 1000 commits; split it into smaller pushes"},
         {:ok, list} <- git(path, ["rev-list", "--objects", "--no-object-names"] ++ revisions),
         oids = String.split(list, "\n", trim: true),
         true <- length(oids) <= @count || {:error, "Too many Git objects"},
         {:ok, objects} <- read_objects(path, oids),
         {:ok, files} <- read_files(path, head, Map.merge(existing, objects)) do
      {:ok, %{head: head, objects: objects, files: files}}
    end
  end

  defp read_objects(path, oids) do
    with {:ok, data} <- git(path, ["cat-file", "--batch"], Enum.join(oids, "\n") <> "\n") do
      parse_objects(data, %{})
    end
  end

  defp parse_objects("", objects), do: {:ok, objects}

  defp parse_objects(data, objects) do
    with [header, rest] <- :binary.split(data, "\n"),
         [oid, type, size] <- String.split(header, " "),
         {size, ""} <- Integer.parse(size),
         true <- size >= 0 and size < byte_size(rest) and type in ["blob", "tree", "commit"],
         <<body::binary-size(^size), "\n", tail::binary>> <- rest do
      parse_objects(tail, Map.put(objects, oid, {type, body}))
    else
      _ -> {:error, "Invalid or oversized Git objects"}
    end
  end

  defp read_files(path, head, objects) do
    with {:ok, list} <- git(path, ["ls-tree", "-r", "-z", head]) do
      Enum.reduce_while(String.split(list, <<0>>, trim: true), {:ok, %{}}, fn line,
                                                                              {:ok, files} ->
        case Regex.run(~r/\A100644 blob ([a-f0-9]{40})\t(.+)\z/s, line) do
          [_, oid, name] -> {:cont, {:ok, Map.put(files, name, elem(objects[oid], 1))}}
          _ -> {:halt, {:error, "Only regular non-executable configuration files are supported"}}
        end
      end)
    end
  end

  defp repository_limit,
    do: Application.get_env(:mondek, :configuration_git_repository_bytes, @repository_limit)

  defp git(path, args, input \\ "", output_limit \\ @limit) do
    input_path = Path.join(path, "request-input")
    File.write!(input_path, input)

    env = [
      {~c"PATH", String.to_charlist(System.get_env("PATH", "/usr/bin:/bin"))},
      {~c"HOME", String.to_charlist(path)},
      {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
      {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
      {~c"GIT_AUTHOR_NAME", ~c"Mondek"},
      {~c"GIT_AUTHOR_EMAIL", ~c"configuration@mondek.invalid"},
      {~c"GIT_COMMITTER_NAME", ~c"Mondek"},
      {~c"GIT_COMMITTER_EMAIL", ~c"configuration@mondek.invalid"}
    ]

    unset =
      System.get_env()
      |> Map.keys()
      |> Enum.map(&{String.to_charlist(&1), false})

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, String.to_charlist(path)},
        {:env, unset ++ env},
        {:args,
         [
           ~c"-c",
           # Packing and indexing share the per-process memory budget across their threads.
           ~c"ulimit -t 15; ulimit -f 32768; (ulimit -v 262144) 2>/dev/null && ulimit -v 262144; exec git -c pack.threads=1 -c core.bigFileThreshold=1m -c pack.windowMemory=8m -c pack.deltaCacheSize=8m -c core.hooksPath=/dev/null -c protocol.allow=never -c receive.fsckObjects=true -c receive.maxInputSize=8388608 \"$@\" < request-input 2> diagnostic-output",
           ~c"git" | Enum.map(args, &String.to_charlist/1)
         ]}
      ])

    collect(
      port,
      "",
      min(System.monotonic_time(:millisecond) + 15_000, Process.get({__MODULE__, :deadline})),
      output_limit
    )
  end

  defp collect(port, output, deadline, limit) do
    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= limit ->
        collect(port, output <> data, deadline, limit)

      {^port, {:data, _}} ->
        Port.close(port)
        {:error, "Git output exceeds limit"}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error, "Git operation rejected"}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Port.close(port)
        {:error, "Git operation timed out"}
    end
  end
end

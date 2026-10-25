# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mondek.ConfigurationGitTest do
  use ExUnit.Case, async: true
  alias Mondek.ConfigurationGit, as: Git
  @zero String.duplicate("0", 40)

  defp packet(body),
    do: ((byte_size(body) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0")) <> body

  defp object(type, body),
    do:
      {Base.encode16(:crypto.hash(:sha, "#{type} #{byte_size(body)}\0" <> body), case: :lower),
       {type, body}}

  defp fixture(parent \\ nil, value \\ "{}\n") do
    {blob, blob_object} = object("blob", value)

    {tree, tree_object} =
      object("tree", "100644 config.json\0" <> Base.decode16!(blob, case: :lower))

    body =
      "tree #{tree}\n" <>
        if(parent, do: "parent #{parent}\n", else: "") <>
        "author Operator <operator@example.invalid> 946684800 +0000\ncommitter Operator <operator@example.invalid> 946684800 +0000\n\nConfiguration\n"

    {head, commit} = object("commit", body)
    {head, %{head => commit, tree => tree_object, blob => blob_object}}
  end

  test "real advertisement and stateless fetch expose accepted objects" do
    {head, objects} = fixture()
    assert {:ok, advertisement} = Git.advertise(objects, head, "git-upload-pack")
    assert advertisement =~ head <> " refs/heads/main"

    assert {:ok, pack} =
             Git.upload(objects, head, packet("want #{head}\n") <> "0000" <> packet("done\n"))

    assert pack =~ "PACK"
  end

  test "push response is provisional until caller accepts and all refs are protected" do
    {head, objects} = fixture()
    {next, additions} = fixture(head, "{\"changed\":true}\n")
    all = Map.merge(objects, additions)
    # All candidate objects are materialized; an empty pack is legal when objects already exist.
    empty_pack = <<"PACK", 2::32, 0::32>>

    request =
      packet("#{head} #{next} refs/heads/main\0report-status\n") <>
        "0000" <> empty_pack <> :crypto.hash(:sha, empty_pack)

    assert {:ok, result} = Git.receive(all, head, request)
    assert result.head == next
    assert result.files == %{"config.json" => "{\"changed\":true}\n"}
    assert result.response =~ "ok refs/heads/main"

    assert {:error, message} =
             Git.receive(
               all,
               head,
               packet("#{head} #{head} refs/heads/main\0report-status\n") <> "0000"
             )

    assert message =~ "already has this revision"

    assert Git.rejection(request, "Configuration invalid") =~
             "ng refs/heads/main Configuration invalid"

    assert {:error, _} =
             Git.receive(
               all,
               head,
               packet("#{head} #{next} refs/heads/other\0report-status\n") <> "0000"
             )

    assert {:error, _} =
             Git.receive(
               all,
               head,
               packet("#{head} #{@zero} refs/heads/main\0report-status\n") <> "0000"
             )

    assert {:error, _} = Git.receive(all, next, request)

    assert {:error, _} =
             Git.receive(
               all,
               next,
               packet("#{next} #{head} refs/heads/main\0report-status\n") <> "0000"
             )

    assert {:error, _} =
             Git.receive(
               all,
               head,
               packet("#{head} #{next} refs/heads/main\0report-status\n") <>
                 packet("#{@zero} #{next} refs/tags/tag\n") <> "0000"
             )
  end

  test "new packed objects are returned for durable acceptance" do
    {head, objects} = fixture()
    {next, additions} = fixture(head, "{\"new\":true}\n")

    assert {:ok, upload} =
             Git.upload(
               Map.merge(objects, additions),
               next,
               packet("want #{next}\n") <> "0000" <> packet("done\n")
             )

    {offset, _} = :binary.match(upload, "PACK")
    pack = binary_part(upload, offset, byte_size(upload) - offset)

    request =
      packet("#{head} #{next} refs/heads/main\0report-status side-band-64k\n") <> "0000" <> pack

    assert {:ok, result} = Git.receive(objects, head, request)
    assert result.objects[next] == additions[next]
    assert result.files == %{"config.json" => "{\"new\":true}\n"}
    assert Git.rejection(request, "Invalid") =~ <<1>> <> "000eunpack ok\n"
  end

  test "accepted history over 1000 commits does not consume a new push budget" do
    {head, objects} =
      Enum.reduce(1..1002, {nil, %{}}, fn _, {parent, objects} ->
        {head, additions} = fixture(parent)
        {head, Map.merge(objects, additions)}
      end)

    {next, additions} = fixture(head, "{\"after_long_history\":true}\n")

    {:ok, upload} =
      Git.upload(
        Map.merge(objects, additions),
        next,
        packet("want #{next}\n") <> "0000" <> packet("done\n")
      )

    {offset, _} = :binary.match(upload, "PACK")
    pack = binary_part(upload, offset, byte_size(upload) - offset)
    request = packet("#{head} #{next} refs/heads/main\0report-status\n") <> "0000" <> pack
    assert {:ok, result} = Git.receive(objects, head, request)
    assert result.head == next
    assert map_size(result.objects) <= 3
    assert result.files == %{"config.json" => "{\"after_long_history\":true}\n"}
  end

  test "invalid objects and oversized requests fail closed" do
    {head, objects} = fixture()

    assert {:error, _} =
             Git.advertise(Map.put(objects, head, {"commit", "invalid"}), head, "git-upload-pack")

    assert {:error, _} = Git.upload(objects, head, :binary.copy("x", 8_388_609))
    assert {:error, _} = Git.receive(objects, head, "invalid")
  end
end

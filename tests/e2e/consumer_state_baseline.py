# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A bounded partitioned baseline trial through the real consumer-state HTTP API."""

from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import json
from threading import Barrier

from mondek_runner import StateConflict, StateError, StateWriteIndeterminate
from mondek_runner.consumer_state import value_bytes

POINTER = "baseline/v1/current"
SHARD_ROWS = 150
VALUE_LIMIT = 65_536
SOURCE_LIMIT = 1_048_576


def degraded_queues(offset):
    return [
        {
            "id": f"customer-{i % 31:02d}/vhost-{i % 12:02d}/retry-priority-queue-{i:04d}",
            "first_degraded_at": "2026-11-21T08:00:00.000000Z",
            "sample_at": "2026-11-21T08:15:00.000000Z",
            "previous": {
                "ready": 1400 + i,
                "unacknowledged": i % 30,
                "consumers": 4 + i % 5,
            },
            "current": {
                "ready": 9100 + i + offset,
                "unacknowledged": i % 70,
                "consumers": i % 3,
            },
        }
        for i in range(600)
    ]


def digest(rows):
    encoded = json.dumps(rows, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
    return sha256(encoded.encode()).hexdigest()


def partition(generation, rows):
    return {
        f"baseline/v1/staged/{generation}/{start // SHARD_ROWS}": rows[
            start : start + SHARD_ROWS
        ]
        for start in range(0, len(rows), SHARD_ROWS)
    }


def stage(client, generation, rows):
    shards = partition(generation, rows)
    stored = {
        key: client.compare_and_set(key, "missing", value).version
        for key, value in shards.items()
    }
    manifest = {
        "generation": generation,
        "acquired_at": rows[0]["sample_at"],
        "shards": list(shards),
        "row_count": len(rows),
        "sha256": digest(rows),
    }
    return manifest, stored


def read_generation(reader, pointer):
    manifest = pointer.value
    rows = []
    for key in manifest["shards"]:
        entry = reader.get(key)
        if entry is None or not isinstance(entry.value, list):
            raise StateError("Baseline shard is unavailable")
        rows.extend(entry.value)
    if len(rows) != manifest["row_count"] or digest(rows) != manifest["sha256"]:
        raise StateError("Baseline generation is incomplete")
    return rows


def charge(key, value):
    return len(key.encode()) + value_bytes(value)


def verify_partitioned_baseline(writer_a, writer_b, reader, usage, drop_reply):
    before = usage()
    original = degraded_queues(0)
    assert value_bytes(original) > VALUE_LIMIT
    original_manifest, original_keys = stage(writer_a, "original", original)
    original_pointer = writer_a.compare_and_set(POINTER, "missing", original_manifest)

    # The writer stops after its first shard. Nothing addresses that incomplete stage.
    interrupted_key, interrupted_rows = next(
        iter(partition("interrupted", original).items())
    )
    interrupted_version = writer_a.compare_and_set(
        interrupted_key, "missing", interrupted_rows
    ).version
    assert reader.get(POINTER) == original_pointer
    assert read_generation(reader, original_pointer) == original

    expected_a = writer_a.get(POINTER)
    expected_b = writer_b.get(POINTER)
    assert expected_a == expected_b == original_pointer
    first, second = degraded_queues(100), degraded_queues(200)
    manifest_a, keys_a = stage(writer_a, "writer-a", first)
    manifest_b, keys_b = stage(writer_b, "writer-b", second)
    assert reader.get(POINTER) == original_pointer
    ready = Barrier(2)

    def publish(writer, expected, manifest):
        ready.wait(timeout=5)
        try:
            writer.compare_and_set(POINTER, expected.version, manifest)
        except StateConflict:
            return False
        return True

    with ThreadPoolExecutor(max_workers=2) as pool:
        race_a = pool.submit(publish, writer_a, expected_a, manifest_a)
        race_b = pool.submit(publish, writer_b, expected_b, manifest_b)
        wins_a, wins_b = race_a.result(), race_b.result()

    assert wins_a != wins_b
    winner = reader.get(POINTER)
    assert winner.value == (manifest_a if wins_a else manifest_b)
    winner_rows = first if wins_a else second
    assert read_generation(reader, winner) == winner_rows
    assert read_generation(reader, original_pointer) == original

    next_rows = degraded_queues(300)
    next_manifest, next_keys = stage(writer_a, "committed", next_rows)
    stages = (
        partition("original", original)
        | {interrupted_key: interrupted_rows}
        | partition("writer-a", first)
        | partition("writer-b", second)
        | partition("committed", next_rows)
    )
    maximum_shard = max(value_bytes(rows) for rows in stages.values())
    assert maximum_shard < VALUE_LIMIT

    drop_reply(POINTER)
    try:
        writer_a.compare_and_set(POINTER, winner.version, next_manifest)
    except StateWriteIndeterminate:
        pass
    else:
        raise AssertionError(
            "A dropped baseline publication reply was not indeterminate"
        )

    try:
        writer_a.compare_and_set(POINTER, winner.version, next_manifest)
    except StateConflict:
        pass
    else:
        raise AssertionError("The original version remained writable after publication")

    committed = reader.get(POINTER)
    assert committed.value == next_manifest
    assert read_generation(reader, committed) == next_rows
    assert read_generation(reader, winner) == winner_rows
    peak = usage()
    peak_bytes = sum(charge(key, rows) for key, rows in stages.items())
    peak_bytes += charge(POINTER, next_manifest)
    assert peak["bytes"] == before["bytes"] + peak_bytes
    assert peak["entries"] == before["entries"] + len(stages) + 1
    assert peak["bytes"] <= SOURCE_LIMIT and peak["entries"] <= 1024

    # Test-owned attempts and readers are quiescent. Delete only their exact old versions.
    obsolete = original_keys | {interrupted_key: interrupted_version} | keys_a | keys_b
    for key, version in obsolete.items():
        writer_a.delete(key, expected_version=version)
    final = usage()
    active = {key: stages[key] for key in next_keys}
    active_bytes = sum(charge(key, rows) for key, rows in active.items())
    active_bytes += charge(POINTER, next_manifest)
    assert final["bytes"] == before["bytes"] + active_bytes
    assert final["entries"] == before["entries"] + len(active) + 1
    assert read_generation(reader, reader.get(POINTER)) == next_rows

    calls = max(client.budget.calls for client in (writer_a, writer_b, reader))
    assert calls <= 64
    print(
        f"Partitioned baseline passed: {value_bytes(original)} bytes unsharded, "
        f"{maximum_shard} bytes largest shard, {peak_bytes} peak added bytes, "
        f"{active_bytes} active bytes, {calls} calls on the busiest test client."
    )

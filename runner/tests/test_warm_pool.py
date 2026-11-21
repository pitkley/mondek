# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Linux process and report-identity regressions for warm worker ownership."""

import asyncio
import json
import os
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from mondek_runner.api import timestamp
from mondek_runner.bundle import snapshot
from mondek_runner.local import assignment
from mondek_runner.runtime import Runner, execute
from mondek_runner.state import State

SOURCE = """import asyncio
import os
import subprocess
import sys
from pathlib import Path

from mondek_runner import App, Datasource, Environment, check, ok

CALLS = 0

def mark(name, value):
    marker = Path(os.environ["WARM_TEST_MARKER"])
    (marker / name).write_text(str(value))

class Fresh(Datasource):
    def __init__(self):
        self.calls = 0

@check(id="fresh", expected_keys=("health",), timeout_seconds=3)
def fresh(*, datasource: Fresh):
    global CALLS
    CALLS += 1
    datasource.calls += 1
    return ok("health", f"{CALLS}:{datasource.calls}", value=os.getpid())

@check(id="held", expected_keys=("first", "last"), timeout_seconds=4)
async def held():
    yield ok("first", "Partial evidence", details="Optional evidence")
    mark("attempt", os.getpid())
    await asyncio.sleep(2)
    yield ok("last", "Complete")

@check(id="descendant", expected_keys=("first", "last"), timeout_seconds=3)
def descendant():
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    yield ok("first", "Partial before process death")
    mark("descendant", child.pid)
    os._exit(9)

@check(id="noisy", expected_keys=("first", "last"), timeout_seconds=3)
def noisy():
    yield ok("first", "Partial before diagnostic overflow")
    os.write(2, b"!" * 4097)
    yield ok("last", "Over budget")

@check(id="timeout", expected_keys=("first", "last"), timeout_seconds=0.5)
async def timeout():
    yield ok("first", "Partial before timeout")
    await asyncio.sleep(30)

app = App(source_id="warm-test", environment=Environment("local"),
          checks=[fresh, held, descendant, noisy, timeout], warm_worker_safe=True)
app.register_datasource(Fresh)
"""

UNSAFE_IMPORT = """
if sys.argv[0].endswith("warm_broker.py"):
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    mark("unsafe-child", child.pid)
"""


@unittest.skipUnless(
    sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds"
)
class WarmPoolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from mondek_runner.warm_pool import WarmPool

        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.bundles = self.root / "bundles"
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.enterContext(
            patch.dict(
                os.environ,
                {
                    "WARM_TEST_MARKER": str(self.root),
                    "PYTHONPATH": str(self.sources)
                    + os.pathsep
                    + os.environ.get("PYTHONPATH", ""),
                },
            )
        )
        self.pool = WarmPool()
        self.addAsyncCleanup(self.pool.close)
        self.configs = await self.consumer("warm_fixture", SOURCE)

    async def consumer(self, module: str, source: str):
        (self.sources / f"{module}.py").write_text(source)
        inventory = await snapshot(f"{module}:app", self.bundles)
        return {
            item["key"]: assignment(item, inventory, None)
            for item in inventory["checks"]
        }

    async def ready(self, key: str = "fresh"):
        config = self.configs[key]
        self.assertTrue(
            await self.pool.prepare(config, bundle_dir=self.bundles), self.pool.status()
        )
        return config

    async def run_warm(self, config):
        return await self.pool.execute(
            config, bundle_dir=self.bundles, lock_path=self.root / config["id"]
        )

    async def wait_file(self, name: str) -> int:
        target = self.root / name
        async with asyncio.timeout(5):
            while not target.exists() or not target.stat().st_size:
                await asyncio.sleep(0.01)
            return int(target.read_text())

    async def wait_gone(self, pid: int):
        async with asyncio.timeout(5):
            while Path(f"/proc/{pid}").exists():
                await asyncio.sleep(0.01)

    async def test_each_execution_has_fresh_globals_datasource_and_process(self):
        config = await self.ready()
        first = await self.run_warm(config)
        second = await self.run_warm(config)
        self.assertTrue(first["complete"], first)
        self.assertTrue(second["complete"], second)
        self.assertEqual(first["results"][0]["summary"], "1:1")
        self.assertEqual(second["results"][0]["summary"], "1:1")
        self.assertNotEqual(first["results"][0]["value"], second["results"][0]["value"])
        self.assertNotEqual(
            first["results"][0]["value"], self.pool.pid_for(config["source_revision"])
        )

        generation = {**config, "generation": 2}
        self.assertTrue(await self.pool.prepare(generation, bundle_dir=self.bundles))
        changed = await self.run_warm(generation)
        self.assertTrue(changed["complete"], changed)
        self.assertEqual(changed["results"][0]["summary"], "1:1")

    async def test_child_death_cleans_descendants_and_keeps_sibling_usable(self):
        await self.ready()
        results = await asyncio.gather(
            self.run_warm(self.configs["descendant"]),
            self.run_warm(self.configs["fresh"]),
        )
        crashed, sibling = results
        self.assertFalse(crashed["complete"], crashed)
        self.assertEqual(
            crashed["results"][0]["summary"], "Partial before process death"
        )
        self.assertTrue(sibling["complete"], sibling)
        await self.wait_gone(await self.wait_file("descendant"))
        self.assertTrue((await self.run_warm(self.configs["fresh"]))["complete"])

    async def test_output_and_time_limits_keep_flushed_partial_measurements(self):
        await self.ready()
        for key, reason in (("noisy", "4 KiB stderr"), ("timeout", "timed out")):
            with self.subTest(key=key):
                outcome = await self.run_warm(self.configs[key])
                self.assertFalse(outcome["complete"], outcome)
                self.assertIn(reason, outcome["diagnostic"])
                self.assertEqual(outcome["results"][0]["key"], "first")
        self.assertTrue((await self.run_warm(self.configs["fresh"]))["complete"])

    async def test_cancelled_child_releases_lock_without_disrupting_broker(self):
        config = await self.ready("held")
        task = asyncio.create_task(self.run_warm(config))
        pid = await self.wait_file("attempt")
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        await self.wait_gone(pid)
        self.assertTrue((await self.run_warm(config))["complete"])

    async def test_integrity_is_rechecked_after_preload_fail_closed(self):
        config = await self.ready()
        revision = config["source_revision"]
        directory = self.bundles / revision
        manifest = json.loads((directory / "manifest.json").read_text())
        source = directory / next(iter(manifest["files"]))
        source.write_text(source.read_text() + "\n# changed after readiness\n")

        outcome = await self.run_warm(config)
        self.assertFalse(outcome["complete"], outcome)
        self.assertEqual(outcome["results"], [])
        self.assertIn("snapshot verification failed", outcome["diagnostic"])
        self.assertFalse(self.pool.should_prepare(revision))
        self.assertIsNone(await self.run_warm(config))
        fallback = await execute(config, bundle_dir=self.bundles)
        self.assertFalse(fallback["complete"], fallback)

    async def test_a_silent_broker_disables_warm_launches_for_later_reports(self):
        config = await self.ready()
        revision = config["source_revision"]
        broker_pid = self.pool.pid_for(revision)
        os.kill(broker_pid, signal.SIGSTOP)
        try:
            result = await self.run_warm({**config, "timeout_seconds": 0.2})
            self.assertFalse(result["complete"])
            self.assertIn("timed out", result["diagnostic"])
            self.assertIn("missed launch deadline", self.pool.status()["diagnostic"])
            self.assertFalse(self.pool.should_prepare(revision))
            self.assertIsNone(await self.run_warm(config))
            self.assertTrue(
                (await execute(config, bundle_dir=self.bundles))["complete"]
            )
        finally:
            os.kill(broker_pid, signal.SIGCONT)

    async def test_new_installed_metadata_invalidates_an_existing_broker(self):
        config = await self.ready()
        distribution = self.sources / "additional_test_package-1.0.dist-info"
        distribution.mkdir()
        (distribution / "METADATA").write_text(
            "Name: additional-test-package\nVersion: 1.0\n"
        )
        outcome = await self.run_warm(config)
        self.assertFalse(outcome["complete"])
        self.assertEqual(outcome["results"], [])
        self.assertIn("snapshot verification failed", outcome["diagnostic"])

    async def test_reprepare_waits_for_the_owned_registry_retirement(self):
        config = await self.ready()
        revision = config["source_revision"]
        original = self.pool.brokers[revision]
        closing = asyncio.Event()
        release = asyncio.Event()
        close = original.close

        async def blocked_close():
            closing.set()
            await release.wait()
            await close()

        with patch.object(original, "close", blocked_close):
            prune = asyncio.create_task(self.pool.prune(set()))
            await asyncio.wait_for(closing.wait(), 5)
            reprepare = asyncio.create_task(
                self.pool.prepare(config, bundle_dir=self.bundles)
            )
            try:
                await asyncio.sleep(0)
                self.assertIn(revision, self.pool.references())
                self.assertFalse(reprepare.done())
            finally:
                release.set()
            await prune
            self.assertTrue(await reprepare, self.pool.status())
        self.assertIsNot(self.pool.brokers[revision], original)
        self.assertTrue((await self.run_warm(config))["complete"])

    async def test_broker_loss_completes_same_allocation_once_then_allows_exec(self):
        config = await self.ready("held")
        runner_state = State(str(self.root / "state"))
        self.addCleanup(runner_state.close)
        runner = Runner(runner_state, "http://127.0.0.1:1", consumer="warm_fixture:app")
        runner.bundle_dir = self.bundles
        runner.warm_pool = self.pool
        original = runner_state.allocate(config, time.time() + 1, timestamp())
        identity = {
            key: original[key] for key in ("id", "sequence", "started_at", "session_id")
        }
        task = asyncio.create_task(runner.collect(config, original))
        child_pid = await self.wait_file("attempt")
        broker_pid = self.pool.pid_for(config["source_revision"])
        os.kill(broker_pid, signal.SIGKILL)
        await asyncio.wait_for(task, 5)
        (first,) = runner_state.batch()
        self.assertEqual({key: first[key] for key in identity}, identity)
        self.assertFalse(first["complete"])
        self.assertEqual(first["results"][0]["summary"], "Partial evidence")
        self.assertEqual(int((self.root / "attempt").read_text()), child_pid)

        following = runner_state.allocate(config, time.time() + 1, timestamp())
        await runner.collect(config, following)
        reports = runner_state.batch()
        self.assertEqual(
            [item["id"] for item in reports], [identity["id"], following["id"]]
        )
        self.assertTrue(reports[-1]["complete"], reports[-1])
        self.assertNotEqual(int((self.root / "attempt").read_text()), child_pid)

    async def test_opt_out_and_import_subprocess_refusal_are_bounded(self):
        no_opt_in = await self.consumer(
            "cold_fixture",
            SOURCE.replace("warm_worker_safe=True", "warm_worker_safe=False"),
        )
        config = no_opt_in["fresh"]
        self.assertFalse(await self.pool.prepare(config, bundle_dir=self.bundles))
        self.assertIsNone(await self.run_warm(config))
        self.assertTrue((await execute(config, bundle_dir=self.bundles))["complete"])

        unsafe = await self.consumer("unsafe_fixture", SOURCE + UNSAFE_IMPORT)
        config = unsafe["fresh"]
        self.assertFalse(
            await asyncio.wait_for(
                self.pool.prepare(config, bundle_dir=self.bundles), 5
            )
        )
        await self.wait_gone(await self.wait_file("unsafe-child"))
        self.assertIsNone(await self.run_warm(config))

    async def test_runner_death_kills_broker_and_live_disposable_child(self):
        config = self.configs["held"]
        source = """
import asyncio
import json
import sys
from pathlib import Path
from mondek_runner.warm_pool import WarmPool

async def main():
    config = json.loads(sys.argv[1])
    directory, root = map(Path, sys.argv[2:])
    pool = WarmPool()
    if not await pool.prepare(config, bundle_dir=directory):
        raise ValueError(pool.status())
    (root / "broker").write_text(str(pool.pid_for(config["source_revision"])))
    lock = root / "parent-worker.lock"
    await pool.execute(config, bundle_dir=directory, lock_path=lock)

asyncio.run(main())
"""
        parent = await asyncio.create_subprocess_exec(
            sys.executable,
            "-c",
            source,
            json.dumps(config),
            str(self.bundles),
            str(self.root),
        )
        try:
            broker_pid, worker_pid = await asyncio.gather(
                self.wait_file("broker"), self.wait_file("attempt")
            )
            parent.kill()
            await asyncio.wait_for(parent.wait(), 5)
            await self.wait_gone(broker_pid)
            await self.wait_gone(worker_pid)
        finally:
            if parent.returncode is None:
                parent.kill()
                await parent.wait()

    async def test_third_revision_uses_exec_until_a_slot_drains(self):
        first = await self.ready("held")
        second = (await self.consumer("second_fixture", SOURCE))["fresh"]
        third = (await self.consumer("third_fixture", SOURCE))["fresh"]
        self.assertTrue(await self.pool.prepare(second, bundle_dir=self.bundles))
        task = asyncio.create_task(self.run_warm(first))
        await self.wait_file("attempt")

        self.assertFalse(await self.pool.prepare(third, bundle_dir=self.bundles))
        self.assertIsNone(await self.run_warm(third))
        self.assertTrue((await execute(third, bundle_dir=self.bundles))["complete"])
        await self.pool.prune({second["source_revision"]})
        self.assertIn(first["source_revision"], self.pool.references())
        self.assertTrue((await task)["complete"])
        await self.pool.prune({second["source_revision"]})
        self.assertNotIn(first["source_revision"], self.pool.references())
        self.assertTrue(await self.pool.prepare(third, bundle_dir=self.bundles))
        self.assertEqual(self.pool.status()["ready_revisions"], 2)

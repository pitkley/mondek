# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from mondek_runner import App, Environment, RunnerContext, Target
from mondek_runner.authoring import validate_params
from mondek_runner.bundle import dependencies
from mondek_runner.packs.linux import Interface, LinuxHost, linux_checks


class LinuxPackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.host = LinuxHost(
            Target("host:a", "A"),
            Environment("prod"),
            root=str(self.root),
            interfaces=(Interface("eth0"),),
        )
        self.write("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 500 kB\n")
        self.write("proc/loadavg", "1 2 3 1/10 123\n")
        self.write("proc/stat", "cpu 1 2 3 4\ncpu0 1 2 3 4\ncpu1 1 2 3 4\n")
        self.write("sys/class/net/eth0/operstate", "up\n")
        dev = self.root.stat().st_dev
        self.mount_line = (
            f"1 0 {os.major(dev)}:{os.minor(dev)} / / rw - ext4 /dev/test rw\n"
        )
        self.write("proc/1/mountinfo", self.mount_line)

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def result(self, kind, **params):
        binding = next(
            b
            for b in linux_checks(self.host)
            if b.key.startswith("linux." + kind + ":")
        )
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            return binding.function(
                params=dict(binding.function.mondek_definition["params"]) | params
            )

    def test_memory_uses_available_and_threshold_equality(self):
        self.assertEqual(self.result("memory").health, "OK")
        self.assertEqual(self.result("memory", warning=50).health, "WARN")
        self.assertEqual(self.result("memory", warning=20, critical=50).health, "CRIT")
        self.assertIn(
            "critical at or above 50%",
            self.result("memory", warning=20, critical=50).details,
        )
        for text in (
            "MemTotal: 1000 kB\n",
            "MemTotal: 1000 kB\nMemAvailable: 1001 kB\n",
            "MemTotal: 0 kB\nMemAvailable: 0 kB\n",
        ):
            self.write("proc/meminfo", text)
            self.assertEqual(self.result("memory").health, "UNKNOWN")

    def test_long_unicode_mount_labels_preserve_distinct_resource_identity(self):
        paths = ("/" + "é" * 120 + "/a", "/" + "é" * 120 + "/b")
        host = replace(self.host, filesystems=paths)
        app = App(
            source_id="long-mounts",
            runner=RunnerContext(
                "a",
                capabilities=("linux-host",),
                target=host.target,
                local_environment=host.environment,
            ),
            checks=linux_checks(host),
        )
        rows = [
            item
            for item in app.metadata("a" * 64)
            if item["key"].startswith("linux.filesystem:")
        ]
        self.assertEqual(len({row["key"] for row in rows}), 2)
        self.assertEqual(len({row["outputs"][0]["target"]["key"] for row in rows}), 2)
        for row in rows:
            self.assertLessEqual(len(row["label"].encode()), 200)
            self.assertLessEqual(
                len(row["outputs"][0]["target"]["label"].encode()), 200
            )

    def test_invalid_operator_selection_explains_the_limit(self):
        self.host = replace(self.host, discover=True)
        result = self.result("discovery", filesystem_include=",".join(["x"] * 65))
        self.assertEqual(result.health, "UNKNOWN")
        self.assertIn(
            "filesystem_include: select at most 64 glob patterns", result.details
        )

    def test_load_is_per_online_cpu_and_rejects_nonfinite(self):
        result = self.result("load")
        self.assertEqual((result.health, result.value), ("WARN", 1))
        self.write("proc/loadavg", "1 nan 3 1/10 1\n")
        self.assertEqual(self.result("load").health, "UNKNOWN")
        self.write("proc/loadavg", "1 1 1 1/10 1\n")
        self.write("proc/stat", "cpu 1 2 3 4\n")
        self.assertEqual(self.result("load").health, "UNKNOWN")

    def test_missing_selected_mount_never_falls_back_to_root(self):
        self.host = replace(self.host, filesystems=("/missing",))
        with patch(
            "mondek_runner.packs.linux.os.statvfs",
            side_effect=AssertionError("must not measure parent"),
        ):
            result = self.result("filesystem")
        self.assertEqual(result.health, "CRIT")
        self.assertIsNotNone(result.source_at)
        self.assertEqual(len(linux_checks(self.host)), 4)

    def test_capacity_reserved_blocks_inode_exhaustion_and_device_mismatch(self):
        stats = SimpleNamespace(
            f_blocks=100, f_bfree=20, f_bavail=10, f_frsize=4096, f_files=100, f_ffree=1
        )
        with patch("mondek_runner.packs.linux.os.statvfs", return_value=stats):
            result = self.result("filesystem")
        self.assertAlmostEqual(result.value, 100 * 80 / 90)
        self.assertEqual(result.health, "CRIT")
        self.write("proc/1/mountinfo", "1 0 0:0 / / rw - ext4 /dev/test rw\n")
        self.assertEqual(self.result("filesystem").health, "UNKNOWN")

    def test_mount_escape_race_and_ambiguity(self):
        self.host = replace(self.host, filesystems=("/a b",))
        (self.root / "a b").mkdir()
        line = self.mount_line.replace(" / / rw", r" / /a\040b rw")
        self.write("proc/1/mountinfo", line)
        self.assertNotEqual(self.result("filesystem").health, "UNKNOWN")
        self.write("proc/1/mountinfo", line + line)
        self.assertEqual(self.result("filesystem").health, "UNKNOWN")
        with patch(
            "mondek_runner.packs.linux._mount_device",
            side_effect=[self.root.stat().st_dev, None],
        ):
            self.assertEqual(self.result("filesystem").health, "UNKNOWN")

    def test_automount_stack_uses_unique_visible_device_in_either_order(self):
        hidden = "2 1 0:65432 / / rw - autofs systemd-1 rw\n"
        for inventory in (hidden + self.mount_line, self.mount_line + hidden):
            with self.subTest(inventory=inventory):
                self.write("proc/1/mountinfo", inventory)
                self.assertNotEqual(self.result("filesystem").health, "UNKNOWN")
        # A visible device absent from the inventory is still ambiguous.
        self.write("proc/1/mountinfo", hidden + hidden.replace("65432", "65433"))
        self.assertEqual(self.result("filesystem").health, "UNKNOWN")

    def test_ramfs_is_excluded_without_hiding_real_storage(self):
        from mondek_runner.packs.linux import _select_resource

        host = replace(self.host, discover=True)
        policy = next(
            b for b in linux_checks(host) if b.key.startswith("linux.discovery:")
        )
        params = policy.function.mondek_definition["params"]
        resource = {
            "kind": "filesystem",
            "name": "/run/credentials/example.service",
            "filesystem_types": ["ramfs"],
        }
        self.assertFalse(_select_resource("", resource, params))
        resource["filesystem_types"] = ["cifs"]
        self.assertTrue(_select_resource("", resource, params))

    def test_unicode_unrelated_mount_and_empty_inventory(self):
        self.write(
            "proc/1/mountinfo", self.mount_line + "2 1 8:2 / /mnt/é rw - ext4 test rw\n"
        )
        self.assertNotEqual(self.result("filesystem").health, "UNKNOWN")
        self.write("proc/1/mountinfo", "")
        result = self.result("filesystem")
        self.assertEqual(result.health, "UNKNOWN")
        self.assertEqual(result.details, "empty mount inventory")

    def test_interface_missing_down_unknown_and_recovery(self):
        for state, health in (
            ("up", "OK"),
            ("down", "CRIT"),
            ("unknown", "CRIT"),
            ("garbage", "UNKNOWN"),
            ("up", "OK"),
        ):
            self.write("sys/class/net/eth0/operstate", state)
            self.assertEqual(self.result("interface").health, health)
        (self.root / "sys/class/net/eth0/operstate").unlink()
        self.assertEqual(self.result("interface").health, "UNKNOWN")
        (self.root / "sys/class/net/eth0").rmdir()
        self.assertEqual(self.result("interface").health, "CRIT")
        self.host = replace(self.host, interfaces=(Interface("lo", ("unknown",)),))
        self.write("sys/class/net/lo/operstate", "unknown")
        self.assertEqual(self.result("interface").health, "OK")

    def test_permission_and_read_bounds_are_unknown(self):
        with patch("mondek_runner.packs.linux._read", side_effect=PermissionError()):
            self.assertEqual(self.result("memory").health, "UNKNOWN")
        self.write("proc/meminfo", "x" * (1024 * 1024 + 1))
        self.assertEqual(self.result("memory").health, "UNKNOWN")

    def test_selection_identity_placement_and_shared_parameter_contract(self):
        host = replace(self.host, filesystems=("/a-b", "/a/b"))
        first = linux_checks(host)
        reordered = linux_checks(
            replace(host, filesystems=tuple(reversed(host.filesystems)))
        )
        self.assertEqual({b.key for b in first}, {b.key for b in reordered})
        self.assertEqual(len({b.key for b in first}), len(first))
        runner = RunnerContext(
            "a",
            capabilities=("linux-host",),
            target=host.target,
            local_environment=host.environment,
        )
        app = App(source_id="pack-test", runner=runner, checks=first)
        metadata = app.metadata("0" * 64)
        self.assertEqual(len(metadata), 5)
        self.assertTrue(all(b.group.key == host.target.key for b in first))
        other = App(
            source_id="pack-test",
            runner=replace(runner, target=Target("host:b", "B")),
            checks=first,
        )
        self.assertEqual(other.metadata("0" * 64), [])
        excluded = App(
            source_id="pack-test", runner=replace(runner, capabilities=()), checks=first
        )
        self.assertEqual(excluded.metadata("0" * 64), [])
        disks = [m for m in metadata if m["label"].startswith("Filesystem")]
        self.assertEqual(len(disks), 2)
        self.assertEqual(disks[0]["parameter_schema"], disks[1]["parameter_schema"])
        for item in disks:
            validate_params(item["params"], item["parameter_schema"], item["params"])
        self.assertEqual(
            linux_checks(
                replace(
                    host, filesystems=(), interfaces=(), memory=False, cpu_load=False
                )
            ),
            [],
        )

    def test_invalid_selection_and_no_io_during_declaration(self):
        for path in ("relative", "/a/../b", "/a//b", "/a/", "/x\n"):
            with self.assertRaises(ValueError):
                replace(self.host, filesystems=(path,))
        with self.assertRaises(ValueError):
            Interface("../x")
        with patch(
            "mondek_runner.packs.linux._read",
            side_effect=AssertionError("no inventory IO"),
        ):
            self.assertEqual(len(linux_checks(self.host)), 4)

    def test_nested_pack_source_is_dependency_fenced(self):
        before = dependencies()
        original = Path.read_bytes

        def changed(path):
            raw = original(path)
            return (
                raw + b"\n# changed"
                if path.as_posix().endswith("packs/linux.py")
                else raw
            )

        with patch.object(Path, "read_bytes", changed):
            after = dependencies()
        self.assertIn("packs/linux.py", before["sdk"])
        self.assertNotEqual(
            before["sdk"]["packs/linux.py"], after["sdk"]["packs/linux.py"]
        )

    def test_snap_images_are_excluded_and_existing_discoveries_retire(self):
        from mondek_runner.catalogs import prepare

        host = replace(self.host, discover=True)
        self.write(
            "proc/1/mountinfo",
            self.mount_line + "2 1 7:0 / /snap/lxd/40528 ro - squashfs /dev/loop0 ro\n"
            "3 1 0:2 / /run rw - tmpfs tmpfs rw\n"
            "4 1 8:2 / /var/snap/lxd/common/storage rw - ext4 disk rw\n",
        )

        def app():
            return App(
                source_id="snap-test",
                runner=RunnerContext(
                    "a",
                    capabilities=("linux-host",),
                    target=host.target,
                    local_environment=host.environment,
                ),
                checks=linux_checks(host),
            )

        initial = app()
        policy = next(
            key for key in initial.bindings if key.startswith("linux.discovery:")
        )
        defaults = initial.bindings[policy].function.mondek_definition["params"]
        include_images = {
            **defaults,
            "filesystem_excluded_types": defaults["filesystem_excluded_types"].replace(
                ",squashfs", ""
            ),
        }
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            before = prepare(initial, {}, {policy: include_images}, 100)
            self.assertIn("filesystem:/snap/lxd/40528", before["state"][policy])
            filtered = app()
            after = prepare(filtered, before["state"], {}, 101)
            self.assertNotIn("filesystem:/snap/lxd/40528", after["state"][policy])
            self.assertNotIn("filesystem:/run", after["state"][policy])
            self.assertIn(
                "filesystem:/var/snap/lxd/common/storage", after["state"][policy]
            )
            # Required root stays declared; removing the type exclusion opts back in.
            self.assertTrue(
                any(
                    b.function.mondek_definition["name"] == "Filesystem /"
                    for b in filtered.bindings.values()
                )
            )
            restored = prepare(app(), after["state"], {policy: include_images}, 102)
            self.assertIn("filesystem:/snap/lxd/40528", restored["state"][policy])

    def test_systemd_mount_stacks_do_not_block_host_discovery(self):
        from mondek_runner.packs.linux import _discover, _select_resource

        self.host = replace(self.host, discover=True)
        stack = (
            "991 988 0:53 / /run/user/1000 rw - tmpfs tmpfs rw\n"
            "1014 1013 0:45 / /proc/sys/fs/binfmt_misc rw - autofs systemd-1 rw\n"
            "1015 1014 0:48 / /proc/sys/fs/binfmt_misc rw - "
            "binfmt_misc binfmt_misc rw\n"
            "1050 1049 0:45 / /proc/sys/fs/binfmt_misc rw - autofs systemd-1 rw\n"
            "1051 1050 0:48 / /proc/sys/fs/binfmt_misc ro - "
            "binfmt_misc binfmt_misc rw\n"
            "1055 1054 0:53 / /run/user/1000 rw - tmpfs tmpfs rw\n"
        )
        self.write("proc/1/mountinfo", self.mount_line + stack)
        self.assertEqual(self.result("discovery").health, "OK")
        policy = next(
            b for b in linux_checks(self.host) if b.key.startswith("linux.discovery:")
        )
        params = policy.function.mondek_definition["params"]
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            resources = _discover(self.root, params)
            self.write(
                "proc/1/mountinfo",
                self.mount_line + "\n".join(reversed(stack.splitlines())) + "\n",
            )
            self.assertEqual(resources, _discover(self.root, params))
        self.assertFalse(
            _select_resource("", resources["filesystem:/run/user/1000"], params)
        )
        self.assertFalse(
            _select_resource(
                "", resources["filesystem:/proc/sys/fs/binfmt_misc"], params
            )
        )
        # A stack containing a non-excluded type must still get a result. Never
        # silently discard a real filesystem because a hidden layer is excluded.
        mixed = {
            "kind": "filesystem",
            "name": "/data",
            "filesystem_types": ["ext4", "tmpfs"],
        }
        self.assertTrue(_select_resource("", mixed, params))
        old = {"kind": "filesystem", "name": "/data", "filesystem_type": "ext4"}
        with self.assertRaises(KeyError):
            _select_resource("", old, params)

    def test_dynamic_selection_discovers_new_mounts_and_interfaces(self):
        from mondek_runner.packs.linux import _discover, _select_resource

        params = dict(
            filesystem_default_include=True,
            filesystem_include="",
            filesystem_exclude="/private/*",
            filesystem_excluded_types="proc,tmpfs",
            interface_default_include=True,
            interface_include="",
            interface_exclude="lo,veth*,br-*",
        )
        self.write(
            "proc/1/mountinfo",
            self.mount_line
            + "2 1 8:2 / /var/lib/kubelet/pods/a/volume rw - ext4 disk rw\n"
            "3 1 0:1 / /proc rw - proc proc rw\n",
        )
        for name in ("lo", "vethabc", "br-abc", "eth1"):
            self.write(f"sys/class/net/{name}/operstate", "up")
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            resources = _discover(self.root, params)
        selected = {
            key
            for key, value in resources.items()
            if _select_resource(key, value, params)
        }
        self.assertEqual(
            selected,
            {
                "filesystem:/",
                "filesystem:/var/lib/kubelet/pods/a/volume",
                "interface:eth0",
                "interface:eth1",
            },
        )
        params.update(
            filesystem_default_include=False,
            filesystem_include="/var/lib/kubelet/*",
            interface_default_include=False,
            interface_include="eth*",
            interface_exclude="eth0",
        )
        selected = {
            key
            for key, value in resources.items()
            if _select_resource(key, value, params)
        }
        self.assertEqual(
            selected, {"filesystem:/var/lib/kubelet/pods/a/volume", "interface:eth1"}
        )
        params["filesystem_exclude"] = "/var/*"
        self.assertFalse(
            _select_resource(
                "filesystem:/var/lib/kubelet/pods/a/volume",
                resources["filesystem:/var/lib/kubelet/pods/a/volume"],
                params,
            )
        )

    def test_dynamic_missing_is_unknown_but_explicit_required_is_critical(self):
        from mondek_runner.packs.linux import _filesystem, _interface

        params = dict(warning=80, critical=90, inode_warning=80, inode_critical=90)
        self.assertEqual(
            _filesystem(self.root, "/missing", params, required=False).health, "UNKNOWN"
        )
        self.assertEqual(_filesystem(self.root, "/missing", params).health, "CRIT")
        self.assertEqual(
            _interface(self.root, Interface("missing"), required=False).health,
            "UNKNOWN",
        )
        self.assertEqual(_interface(self.root, Interface("missing")).health, "CRIT")

    def test_dynamic_failed_scan_is_not_empty_inventory(self):
        from mondek_runner.packs.linux import EvidenceError, _discover

        self.write("proc/1/mountinfo", "")
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            with self.assertRaises(EvidenceError):
                _discover(self.root, {})
        self.write("proc/1/mountinfo", self.mount_line)
        with (
            patch("mondek_runner.packs.linux.sys.platform", "linux"),
            patch(
                "mondek_runner.packs.linux.os.scandir", side_effect=PermissionError()
            ),
        ):
            with self.assertRaises(PermissionError):
                _discover(self.root, {})

    def test_exact_glob_patterns_only_exclude_the_named_resource(self):
        from mondek_runner.packs.linux import _selected

        fixtures = (
            Path(__file__).resolve().parents[2]
            / "tests/fixtures/exact_glob_patterns.json"
        )
        for entry in json.loads(fixtures.read_text()):
            with self.subTest(name=entry["name"]):
                self.assertFalse(_selected(entry["name"], True, "", entry["pattern"]))
                self.assertTrue(_selected(entry["other"], True, "", entry["pattern"]))

    def test_selection_patterns_are_bounded_and_paths_with_spaces_work(self):
        from mondek_runner.packs.linux import Selection, _selected

        self.assertTrue(_selected("/some disk", False, "/some disk,/other*", ""))
        self.assertFalse(_selected("eth0", True, "eth*", "eth0"))
        for patterns in (("a,b",), ("x" * 257,), tuple("a" for _ in range(65))):
            with self.assertRaises(ValueError):
                Selection(include=patterns)
        with self.assertRaises(ValueError):
            replace(self.host, disappearance_grace_seconds=-1)

    def test_discovery_declaration_has_editable_policy_without_collection(self):
        with patch(
            "mondek_runner.packs.linux._read",
            side_effect=AssertionError("no declaration IO"),
        ):
            bindings = linux_checks(replace(self.host, discover=True))
        policy = next(
            binding
            for binding in bindings
            if binding.key.startswith("linux.discovery:")
        )
        definition = policy.function.mondek_definition
        self.assertEqual(definition["parameter_contract"], "mondek.linux.discovery.v1")
        self.assertTrue(hasattr(policy.function, "mondek_discovery"))
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            self.assertEqual(policy.function(params=definition["params"]).health, "OK")
        self.write("proc/1/mountinfo", "")
        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            self.assertEqual(
                policy.function(params=definition["params"]).health, "UNKNOWN"
            )

    def test_declared_discovery_provenance_preserves_identity_and_required_origin(self):
        from mondek_runner.catalogs import prepare

        runner = RunnerContext(
            "a",
            capabilities=("linux-host",),
            target=self.host.target,
            local_environment=self.host.environment,
        )

        def app(required):
            return App(
                source_id="pack-test",
                runner=runner,
                checks=linux_checks(
                    replace(
                        self.host,
                        discover=True,
                        interfaces=(Interface("eth0"),) if required else (),
                    )
                ),
            )

        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            required = app(True)
            prepare(required, {}, {}, 100)
            explicit = next(
                row
                for row in required.metadata("a" * 64)
                if row["key"].startswith("linux.interface:")
            )
            dynamic = app(False)
            prepared = prepare(dynamic, {}, {}, 100)
            discovered = next(
                row
                for row in dynamic.metadata("a" * 64)
                if row["key"].startswith("linux.interface:")
            )
            self.assertEqual(explicit["key"], discovered["key"])
            self.assertEqual(explicit["outputs"], discovered["outputs"])
            self.assertEqual(explicit["discovery"]["origin"], "required")
            self.assertEqual(discovered["discovery"]["origin"], "discovered")
            manager = discovered["discovery"]["manager_key"]
            self.assertEqual(prepared["selections"][manager]["status"], "accepted")
            self.assertEqual(discovered["discovery"]["resource_name"], "eth0")
            with patch(
                "mondek_runner.packs.linux.os.scandir", side_effect=PermissionError()
            ):
                failed = prepare(app(False), prepared["state"], {}, 101)
            self.assertEqual(failed["selections"][manager]["status"], "failed")
            self.assertEqual(failed["state"], prepared["state"])

    def test_catalog_churn_exclusion_grace_failure_and_group_override(self):
        from mondek_runner import CheckGroup
        from mondek_runner.catalogs import materialize, prepare

        host = replace(
            self.host, discover=True, interfaces=(), disappearance_grace_seconds=10
        )
        runner = RunnerContext(
            "a",
            capabilities=("linux-host",),
            target=host.target,
            local_environment=host.environment,
        )

        def app():
            return App(
                source_id="pack-test",
                runner=runner,
                checks=[
                    replace(binding, group=CheckGroup("custom", "Custom host"))
                    for binding in linux_checks(host)
                ],
            )

        with patch("mondek_runner.packs.linux.sys.platform", "linux"):
            first = app()
            state = prepare(first, {}, {}, 100)
            policy_key = next(
                key for key in first.bindings if key.startswith("linux.discovery:")
            )
            self.assertEqual(set(state["state"][policy_key]), {"interface:eth0"})
            dynamic_key = next(
                key for key in first.bindings if key.startswith("linux.interface:")
            )
            self.assertEqual(first.bindings[dynamic_key].group.key, "custom")
            frozen = first._catalogs
            with patch(
                "mondek_runner.packs.linux._read",
                side_effect=AssertionError("frozen replay must not discover"),
            ):
                replay = app()
                materialize(replay, frozen)
                self.assertEqual(set(replay.bindings), set(first.bindings))
            (self.root / "sys/class/net/eth0/operstate").unlink()
            (self.root / "sys/class/net/eth0").rmdir()
            absent = app()
            missing = prepare(absent, state["state"], {}, 101)
            self.assertIn(dynamic_key, absent.bindings)
            self.assertEqual(
                absent.bindings[dynamic_key].function(params={}).health, "UNKNOWN"
            )
            with patch(
                "mondek_runner.packs.linux.os.scandir", side_effect=PermissionError()
            ):
                failed = prepare(app(), missing["state"], {}, 200)
                self.assertIn("interface:eth0", failed["state"][policy_key])
                self.assertTrue(failed["errors"])
            retired = app()
            prepare(retired, missing["state"], {}, 111)
            self.assertNotIn(dynamic_key, retired.bindings)
            policies = dict(
                first.bindings[policy_key].function.mondek_definition["params"]
            )
            policies["interface_exclude"] = "eth*"
            excluded = app()
            prepare(excluded, state["state"], {policy_key: policies}, 102)
            self.assertNotIn(dynamic_key, excluded.bindings)
            self.assertTrue(
                any(key.startswith("linux.filesystem:") for key in excluded.bindings)
            )

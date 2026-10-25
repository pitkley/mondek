# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Fresh-interpreter SDK compatibility and transport import boundaries."""

import subprocess
import sys
import textwrap
import unittest


class PublicApiTests(unittest.TestCase):
    def fresh(self, code: str) -> None:
        completed = subprocess.run(
            [sys.executable, "-c", textwrap.dedent(code)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_transport_does_not_import_authoring_or_result_models(self):
        self.fresh("""
            import sys
            import mondek_runner
            assert 'mondek_runner.authoring' not in sys.modules
            assert 'mondek_runner.api' not in sys.modules
            import mondek_runner.transport
            assert 'mondek_runner.authoring' not in sys.modules
            assert 'mondek_runner.api' not in sys.modules
            assert 'mondek_runner.runtime' not in sys.modules
            assert 'mondek_runner.worker' not in sys.modules
            from mondek_runner._text import truncate_utf8
            assert truncate_utf8('é' * 1025) == 'é' * 1024
            assert truncate_utf8('é', 1) == ''
        """)

    def test_public_exports_preserve_star_import_identity_and_annotations(self):
        self.fresh("""
            from __future__ import annotations
            import importlib
            import pickle
            import typing
            import mondek_runner
            from mondek_runner import *
            expected = {
                'App', 'Binding', 'Capability', 'CheckGroup', 'Condition', 'Consumer',
                'Datasource', 'DatasourceFactory', 'Environment', 'FromFactory',
                'Discovery', 'DiscoveryCandidate', 'DiscoveryChoice',
                'Impact', 'ManagedResource', 'Output', 'Parameter',
                'Placement', 'PlacementContext',
                'Result', 'ResultBuilder', 'RunnerContext', 'Target',
                'build_result', 'check', 'crit', 'discover_checks', 'ok',
                'unknown', 'warn',
            }
            assert set(mondek_runner.__all__) == expected
            for name in expected:
                exported = getattr(mondek_runner, name)
                assert globals()[name] is exported
                module = importlib.import_module(exported.__module__)
                assert getattr(module, name) is exported
                assert name in dir(mondek_runner)
            def annotated() -> mondek_runner.Result:
                return ok('result', 'Measured')
            assert typing.get_type_hints(annotated)['return'] is Result
            value = annotated()
            assert pickle.loads(pickle.dumps(value)) == value
            assert mondek_runner.api is importlib.import_module(
                'mondek_runner.api')
            assert mondek_runner.authoring is importlib.import_module(
                'mondek_runner.authoring')
            assert mondek_runner.api.truncate_utf8 is importlib.import_module(
                'mondek_runner._text').truncate_utf8
        """)

    def test_attribute_discovery_stays_lazy_and_unknown_names_stay_missing(self):
        self.fresh("""
            import sys
            import mondek_runner
            assert 'Result' in dir(mondek_runner)
            assert 'api' in dir(mondek_runner)
            assert 'authoring' in dir(mondek_runner)
            assert 'mondek_runner.api' not in sys.modules
            assert not hasattr(mondek_runner, 'not_a_public_export')
            assert 'mondek_runner.authoring' not in sys.modules
            assert 'Result' not in mondek_runner.__dict__
            result_type = mondek_runner.Result
            assert mondek_runner.__dict__['Result'] is result_type
            assert 'mondek_runner.authoring' not in sys.modules
            assert mondek_runner.authoring.App is mondek_runner.App
        """)

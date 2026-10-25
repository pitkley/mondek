# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import asyncio
import copy
import json
import sys
import unittest
from types import ModuleType
from typing import Annotated

from mondek_runner import (
    App,
    Binding,
    Datasource,
    DatasourceFactory,
    Environment,
    FromFactory,
    Output,
    Parameter,
    Target,
    check,
    crit,
    discover_checks,
    ok,
    warn,
)
from mondek_runner.api import evaluate
from mondek_runner.authoring import (
    canonical,
    normalize_json_numbers,
    validate_params,
)


class Counter(Datasource):
    constructed = 0

    def __init__(self, secret: str):
        Counter.constructed += 1
        self.secret = secret


class Factory(DatasourceFactory):
    def new(self, secret: str) -> Counter:
        return Counter(secret)


class MethodFactory(DatasourceFactory):
    constructed = 0

    def __init__(self):
        MethodFactory.constructed += 1

    def new(self, secret: str, /, *, suffix: str) -> Counter:
        return Counter(secret + suffix)


class ClassMethodFactory(MethodFactory):
    @classmethod
    def new(cls, secret: str, /, *, suffix: str) -> Counter:
        return Counter(secret + suffix)


class StaticMethodFactory(MethodFactory):
    @staticmethod
    def new(secret: str, /, *, suffix: str) -> Counter:
        return Counter(secret + suffix)


@check(
    id="injected",
    name="Injected check",
    outputs=(Output("value", "Value", Target("remote", "Remote service", "service")),),
    params={"warning": 5, "critical": 10, "path": "/exports"},
    parameters={
        "path": Parameter("string", "Export path", choices=("/exports",)),
        "warning": Parameter("integer", "Warning", minimum=0),
        "critical": Parameter("integer", "Critical", minimum=0),
    },
    comparisons=(("warning", "lt", "critical"),),
)
def injected(source: Counter, environment: Environment, *, params: dict):
    return ok("value", f"{environment.id}:{source.secret}:{params['path']}")


@check(id="factory", expected_keys=("value",))
async def factory_check(
    source: Annotated[Counter, FromFactory(Factory, "factory-secret")],
):
    await asyncio.sleep(0)
    yield warn("value", source.secret)


class AuthoringTests(unittest.IsolatedAsyncioTestCase):
    async def test_factory_method_descriptors_validate_without_construction(self):
        for base in (MethodFactory, ClassMethodFactory, StaticMethodFactory):
            inherited = type("Inherited" + base.__name__, (base,), {})
            for factory in (base, inherited):
                with self.subTest(factory=factory.__name__):
                    Counter.constructed = MethodFactory.constructed = 0

                    @check(id="probe", expected_keys=("health",))
                    def probe(source):
                        return ok("health", source.secret)

                    probe.__annotations__ = {
                        "source": Annotated[
                            Counter, FromFactory(factory, "private-input", suffix="!")
                        ]
                    }
                    app = App(
                        source_id="factory-methods",
                        environment=Environment("local"),
                        checks=[probe],
                    )
                    app.register_datasource_factory(factory)
                    metadata = app.metadata("a" * 64)
                    app.private_settings()
                    self.assertNotIn("private-input", str(metadata))
                    self.assertEqual(Counter.constructed, 0)
                    self.assertEqual(MethodFactory.constructed, 0)
                    values = [
                        value
                        async for value in evaluate(probe, **app.arguments("probe", {}))
                    ]
                    self.assertEqual(values[0].summary, "private-input!")
                    app.arguments("probe", {})
                    self.assertEqual(Counter.constructed, 1)
                    self.assertEqual(MethodFactory.constructed, 1)

    async def test_factory_method_descriptors_keep_exact_argument_validation(self):
        for factory in (MethodFactory, ClassMethodFactory, StaticMethodFactory):
            for args, kwargs in (
                (("private-input",), {}),
                ((), {"secret": "private-input", "suffix": "!"}),
                (("private-input", "extra"), {"suffix": "!"}),
                (("private-input",), {"suffix": "!", "unknown": True}),
            ):
                with self.subTest(factory=factory.__name__, args=args, kwargs=kwargs):
                    Counter.constructed = MethodFactory.constructed = 0

                    @check(id="probe", expected_keys=("health",))
                    def probe(source):
                        return ok("health", source.secret)

                    probe.__annotations__ = {
                        "source": Annotated[
                            Counter, FromFactory(factory, *args, **kwargs)
                        ]
                    }
                    app = App(
                        source_id="factory-methods",
                        environment=Environment("local"),
                        checks=[probe],
                    )
                    app.register_datasource_factory(factory)
                    with self.assertRaises(TypeError):
                        app.metadata("a" * 64)
                    self.assertEqual(Counter.constructed, 0)
                    self.assertEqual(MethodFactory.constructed, 0)

    async def test_expanded_numeric_params_fit_the_wire_budget_before_export(self):
        params = {f"number_{index}": sys.float_info.max for index in range(8)} | {
            f"text_{index}": "x" * 620 for index in range(24)
        }
        self.assertLess(len(canonical(params)), 16384)
        self.assertGreater(len(canonical(normalize_json_numbers(params))), 16384)
        fields = {
            key: Parameter("number" if type(value) is float else "string", key)
            for key, value in params.items()
        }
        for parameters in ({}, fields):
            with self.subTest(delegated=bool(parameters)):

                @check(
                    id="large",
                    expected_keys=("value",),
                    params=params,
                    parameters=parameters,
                )
                def large(params):
                    raise AssertionError("metadata validation must not run the check")

                app = App(
                    source_id="large-params",
                    environment=Environment("local"),
                    checks=[large],
                )
                with self.assertRaisesRegex(ValueError, "16 KiB"):
                    app.metadata("a" * 64)

        smaller = {
            key: (value if type(value) is float else "x" * 400)
            for key, value in params.items()
        }
        schema = {
            "fields": {key: field.to_dict() for key, field in fields.items()},
            "comparisons": [],
        }
        self.assertEqual(validate_params(smaller, schema, smaller), smaller)
        self.assertLess(len(canonical(normalize_json_numbers(smaller))), 16384)
        self.assertIs(type(smaller["number_0"]), float)

        # Size normalization cannot make a float acceptable to an integer field.
        with self.assertRaisesRegex(ValueError, "integer"):
            validate_params(
                {"count": 1.0}, {"fields": {"count": {"type": "integer"}}}, {"count": 1}
            )

    async def test_integral_float_metadata_preserves_exact_values_without_rounding(
        self,
    ):
        original = {
            "numbers": [
                1e20,
                1e23,
                -1e23,
                sys.float_info.max,
                -0.0,
                0.125,
                1e-30,
                True,
                10**400,
            ],
            "nested": {"value": 1e30},
        }
        unchanged = copy.deepcopy(original)
        encoded = canonical(normalize_json_numbers(original))
        normalized = json.loads(encoded)
        self.assertEqual(original, unchanged)
        self.assertEqual(normalized, original)
        self.assertEqual(normalized, normalize_json_numbers(normalized))
        self.assertEqual(encoded, canonical(normalized))
        for index in range(5):
            self.assertIs(type(normalized["numbers"][index]), int)
        self.assertEqual(normalized["numbers"][1], 99999999999999991611392)
        self.assertNotEqual(normalized["numbers"][1], 10**23)
        self.assertEqual(normalized["numbers"][3], int(sys.float_info.max))
        self.assertIs(type(normalized["numbers"][5]), float)
        self.assertIs(type(normalized["numbers"][6]), float)
        self.assertIs(type(normalized["numbers"][7]), bool)
        for invalid in (float("inf"), float("-inf"), float("nan")):
            with self.assertRaisesRegex(ValueError, "finite"):
                normalize_json_numbers({"nested": [invalid]})

    async def test_parameter_integer_boundary_round_trips_without_runtime_overrides(
        self,
    ):
        conversion_limit = sys.get_int_max_str_digits()
        largest = 10**4096 - 1
        for value in (largest, -largest):
            for kind in ("integer", "number"):
                field = Parameter(
                    kind,
                    "Large exact value",
                    minimum=-largest,
                    maximum=largest,
                    choices=(value,),
                ).to_dict()
                params = {"value": value}
                schema = {"fields": {"value": field}, "comparisons": []}
                self.assertEqual(validate_params(params, schema, params), params)
                self.assertEqual(json.loads(canonical(params)), params)
        self.assertEqual(sys.get_int_max_str_digits(), conversion_limit)

    async def test_oversized_integers_reject_params_bounds_choices_and_nested_metadata(
        self,
    ):
        for value in (10**4096, -(10**4096), 10**4999):
            with self.subTest(digits="over4096", negative=value < 0):
                for nested in ({"value": value}, {"fields": [{"extra": value}]}):
                    with self.assertRaisesRegex(ValueError, "4096"):
                        canonical(nested)
                with self.assertRaisesRegex(ValueError, "4096"):
                    Parameter("integer", "Count", minimum=value).to_dict()
                with self.assertRaisesRegex(ValueError, "4096"):
                    Parameter("number", "Count", maximum=value).to_dict()
                with self.assertRaisesRegex(ValueError, "4096"):
                    Parameter("integer", "Count", choices=(value,)).to_dict()
                with self.assertRaisesRegex(ValueError, "4096"):
                    validate_params(
                        {"count": value},
                        {"fields": {"count": {"type": "integer"}}, "comparisons": []},
                        {"count": 1},
                    )

    async def test_parameter_contract_is_inherited_by_bindings_and_fences_revision(
        self,
    ):
        @check(
            id="capacity",
            expected_keys=("health",),
            params={"limit": 80},
            parameters={"limit": Parameter("number", "Used capacity", unit="percent")},
            parameter_contract="capacity.used-percent.v1",
        )
        def capacity(params):
            return ok("health", str(params["limit"]))

        app = App(
            source_id="storage",
            environment=Environment("node"),
            checks=[
                Binding(capacity, key="one"),
                Binding(capacity, key="two", params={"limit": 90}),
            ],
        )
        before = app.metadata("a" * 64)
        self.assertEqual(
            [item["parameter_contract"] for item in before],
            ["capacity.used-percent.v1", "capacity.used-percent.v1"],
        )
        self.assertEqual(before[0]["params"]["limit"], 80)
        self.assertEqual(before[1]["params"]["limit"], 90)
        capacity.mondek_definition["parameter_contract"] = "capacity.used-percent.v2"
        after = app.metadata("a" * 64)
        self.assertNotEqual(
            before[0]["definition_revision"], after[0]["definition_revision"]
        )
        self.assertEqual(before[0]["key"], after[0]["key"])
        self.assertEqual(before[0]["parameter_schema"], after[0]["parameter_schema"])

    async def test_parameter_contract_is_optional_and_requires_valid_delegation(self):
        @check(id="probe", expected_keys=("health",))
        def probe():
            return ok("health", "Ready")

        app = App(source_id="test", environment=Environment("node"), checks=[probe])
        self.assertNotIn("parameter_contract", app.metadata("a" * 64)[0])

        @check(
            id="delegated",
            expected_keys=("health",),
            params={"limit": 80},
            parameters={"limit": Parameter("integer", "Limit")},
        )
        def delegated(params):
            return ok("health", str(params["limit"]))

        app.add(delegated)
        delegated_metadata = app.metadata("a" * 64)[1]
        self.assertEqual(delegated_metadata["params_owner"], "ui")
        self.assertNotIn("parameter_contract", delegated_metadata)
        for value in ("", "has spaces", "../escape", "a" * 129, "line\nbreak", True, 1):
            with (
                self.subTest(value=value),
                self.assertRaisesRegex(ValueError, "parameter contract"),
            ):
                check(
                    expected_keys=("health",),
                    params={"limit": 80},
                    parameters={"limit": Parameter("integer", "Limit")},
                    parameter_contract=value,
                )
        for parameters in (None, {}):
            with self.assertRaisesRegex(ValueError, "UI-delegated"):
                check(
                    expected_keys=("health",),
                    params={"limit": 80},
                    parameters=parameters,
                    parameter_contract="capacity.v1",
                )
        # Full discovery repeats validation even for manually modified registration.
        probe.mondek_definition["parameter_contract"] = "capacity.v1"
        with self.assertRaisesRegex(ValueError, "UI-delegated"):
            app.metadata("a" * 64)

    async def test_binding_environment_defines_default_target_and_injection(self):
        @check(id="probe", expected_keys=("health",))
        def probe(environment: Environment):
            return ok("health", environment.id)

        app = App(
            source_id="test",
            environment=Environment("node-a"),
            checks=[Binding(probe, environment=Environment("node-b"))],
        )
        self.assertEqual(app.arguments("probe", {})["environment"].id, "node-b")
        self.assertEqual(
            app.metadata("a" * 64)[0]["outputs"][0]["target"]["key"], "node-b"
        )

    async def test_environment_identity_is_separate_from_reusable_display_name(self):
        @check(id="probe", expected_keys=("health",))
        def probe(environment: Environment):
            return ok("health", environment.id)

        app = App(
            source_id="test",
            environment=Environment("node-a", "Production", {"secret": "local"}),
            checks=[
                Binding(probe, key="first"),
                Binding(
                    probe, key="second", environment=Environment("node-b", "Production")
                ),
            ],
        )
        before = app.metadata("a" * 64)
        self.assertEqual([item["environment"] for item in before], ["node-a", "node-b"])
        self.assertEqual(
            [item["environment_label"] for item in before], ["Production", "Production"]
        )
        self.assertEqual(
            [item["outputs"][0]["target"]["key"] for item in before],
            ["node-a", "node-b"],
        )
        self.assertNotIn("secret", str(before))
        app.environment = Environment(
            "node-a", "Renamed production", {"secret": "local"}
        )
        after = app.metadata("a" * 64)
        self.assertEqual(after[0]["environment"], before[0]["environment"])
        self.assertEqual(after[0]["key"], before[0]["key"])
        self.assertEqual(after[0]["outputs"][0]["target"]["key"], "node-a")
        self.assertEqual(after[0]["environment_label"], "Renamed production")
        self.assertNotEqual(
            after[0]["definition_revision"], before[0]["definition_revision"]
        )
        self.assertEqual(after[1], before[1])

    async def test_unnamed_environment_uses_id_as_its_label(self):
        @check(id="probe", expected_keys=("health",))
        def probe():
            return ok("health", "Ready")

        app = App(source_id="test", environment=Environment("node-a"), checks=[probe])
        metadata = app.metadata("a" * 64)[0]
        self.assertEqual(metadata["environment"], "node-a")
        self.assertEqual(metadata["environment_label"], "node-a")

    async def test_source_defaults_and_schema_bounds_match_wire_contract(self):
        @check(id="fixed", expected_keys=("value",), params={"limit": 3})
        def fixed(*, params: dict):
            return ok("value", str(params["limit"]))

        app = App(source_id="checks", environment=Environment("a"), checks=[fixed])
        metadata = app.metadata("a" * 64)[0]
        self.assertEqual(metadata["params_owner"], "source")
        self.assertEqual(
            metadata["parameter_schema"]["fields"]["limit"]["type"], "integer"
        )
        for parameter in (
            Parameter("integer", "Limit", choices=(True,)),
            Parameter("string", "Path", choices=("bad\nvalue",)),
            Parameter("number", "Limit", minimum=10, maximum=1),
            Parameter("string", "Path", max_length=4096),
        ):
            with self.assertRaises(ValueError):
                parameter.to_dict()
        for index in range(511):
            app.add(Binding(fixed, key=f"fixed-{index}"))
        self.assertEqual(len(app.metadata("a" * 64)), 512)
        with self.assertRaisesRegex(ValueError, "512"):
            app.add(Binding(fixed, key="too-many"))

    async def test_helpers_timestamp_creation_and_keep_explicit_source_age(self):
        result = ok("local", "freshly checked")
        self.assertIsNotNone(result.source_at)

        async def reused():
            return result

        first = [value async for value in evaluate(reused)]
        second = [value async for value in evaluate(reused)]
        self.assertEqual(first[0].source_at, second[0].source_at)
        self.assertIsNone(ok("unknown-age", "legacy", source_at=None).source_at)
        self.assertEqual(
            warn(
                "cached", "old input", source_at="2009-09-15T00:00:00.000000Z"
            ).source_at,
            "2009-09-15T00:00:00.000000Z",
        )

    async def test_discovery_metadata_does_not_construct_or_publish_datasources(self):
        Counter.constructed = 0
        module = ModuleType("consumer")
        module.first, module.reexport = injected, injected
        self.assertEqual(discover_checks(module), [injected])
        app = App(
            source_id="checks",
            environment=Environment("node-a"),
            checks=[module, factory_check],
        )
        app.register_datasource(Counter, secret="local-only-secret")
        app.register_datasource_factory(Factory)
        metadata = app.metadata("a" * 64)
        self.assertEqual(Counter.constructed, 0)
        self.assertNotIn("secret", str(metadata))
        self.assertEqual(metadata[0]["outputs"][0]["target"]["key"], "remote")
        self.assertEqual(metadata[0]["params_owner"], "ui")
        result = [
            value
            async for value in evaluate(
                injected, **app.arguments("injected", metadata[0]["params"])
            )
        ]
        self.assertEqual(result[0].summary, "node-a:local-only-secret:/exports")
        app.arguments("injected", metadata[0]["params"])
        self.assertEqual(Counter.constructed, 1)
        result = [
            value
            async for value in evaluate(factory_check, **app.arguments("factory", {}))
        ]
        self.assertEqual(result[0].summary, "factory-secret")

    async def test_sync_coroutine_generators_and_partial_generator_failure(self):
        def sync():
            return ok("a", "fresh")

        def generator():
            yield warn("a", "first")
            raise OSError("source unavailable")

        async def coroutine():
            return [ok("a", "first"), crit("b", "second")]

        self.assertEqual(len([value async for value in evaluate(sync)]), 1)
        self.assertEqual(len([value async for value in evaluate(coroutine)]), 2)
        seen = []
        with self.assertRaisesRegex(OSError, "unavailable"):
            async for result in evaluate(generator):
                seen.append(result)
        self.assertEqual([value.key for value in seen], ["a"])

    async def test_identity_is_explicit_and_binding_targets_are_independent(self):
        app = App(
            source_id="checks",
            environment=Environment("runner"),
            checks=[
                Binding(injected, key="a", target=Target("a", "Node A")),
                Binding(injected, key="b", target=Target("b", "Node B")),
            ],
        )
        app.register_datasource(Counter, secret="secret")
        before = app.metadata("a" * 64)
        injected.__name__ = "renamed_function"
        self.assertEqual(before, app.metadata("a" * 64))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            app.add(Binding(injected, key="a"))
        with self.assertRaisesRegex(ValueError, "explicit"):
            App(
                source_id="x",
                environment=Environment("x"),
                checks=[check(expected_keys=("x",))(lambda: ok("x", "x"))],
            )

    async def test_invalid_injection_parameters_and_complete_ui_parameter_ownership(
        self,
    ):
        app = App(
            source_id="checks", environment=Environment("node-a"), checks=[injected]
        )
        with self.assertRaisesRegex(ValueError, "unregistered datasource"):
            app.metadata("a" * 64)
        app.register_datasource(Counter, secret="secret")
        item = app.metadata("a" * 64)[0]
        schema, defaults = item["parameter_schema"], item["params"]
        self.assertEqual(
            validate_params({**defaults, "warning": 6}, schema, defaults)["warning"], 6
        )
        for update in (
            {"warning": True},
            {"critical": 1},
            {"path": "/other"},
            {"extra": 1},
        ):
            with self.assertRaises(ValueError):
                validate_params({**defaults, **update}, schema, defaults)


if __name__ == "__main__":
    unittest.main()

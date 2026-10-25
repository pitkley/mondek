# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Consumer registration and dependency injection, without a polling/cache runtime.

Discovery validates signatures and metadata without constructing datasources. Each
worker owns its datasource instances; secrets stay in local constructor arguments.
"""

from __future__ import annotations

import importlib
import inspect
import json
import math
import pkgutil
import re
from collections.abc import Callable, Iterable, Mapping
from copy import copy, deepcopy
from dataclasses import asdict, dataclass, field, replace
from functools import cached_property
from hashlib import sha256
from types import MappingProxyType, ModuleType
from typing import Annotated, Any, Literal, get_args, get_origin, get_type_hints

from .api import validate_invocation_scope
from .catalogs import DiscoveryCatalog as DiscoveryCatalog

MAX_CHECKS = 512
INTEGER_LIMIT = 10**4096
KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/@-]{0,127}")


def stable_key(value: Any, what: str = "identity") -> str:
    if not isinstance(value, str) or not KEY.fullmatch(value):
        raise ValueError(f"{what} must be a stable 1–128 character identifier")
    return value


def label(value: Any, what: str = "label") -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value.encode()) > 200
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise ValueError(f"{what} must be nonempty text within 200 bytes")
    return value


def public_placement_reason(reason: str) -> str:
    """Bound explanatory text without truncating declaration membership."""
    encoded = reason.encode()
    return (
        encoded[:2045].decode(errors="ignore") + "..."
        if len(encoded) > 2048
        else reason
    )


def _coverage_text(value: Any, maximum: int, what: str) -> str:
    """Preserve the accepted wire text contract of metadata overrides."""
    label(value, what)
    if len(value.encode()) > maximum:
        raise ValueError(f"{what} must fit within {maximum} bytes")
    return value


def finite_number(value: Any) -> bool:
    """JSON integers remain exact; do not coerce them to binary64 for finiteness."""
    return (
        type(value) is int
        and -INTEGER_LIMIT < value < INTEGER_LIMIT
        or type(value) is float
        and math.isfinite(value)
    )


def validate_integer_literals(value: Any) -> None:
    """Stay below Python's default decimal conversion limit without changing it."""
    if type(value) is int and not -INTEGER_LIMIT < value < INTEGER_LIMIT:
        raise ValueError("JSON integers must have at most 4096 decimal digits")
    if isinstance(value, dict):
        for key, item in value.items():
            validate_integer_literals(key)
            validate_integer_literals(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            validate_integer_literals(item)


def normalize_json_numbers(value: Any) -> Any:
    """Preserve exact integral binary64 values across JSONB's decimal expansion."""
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError("JSON numbers must be finite")
        return int(value) if value.is_integer() else value
    if type(value) is int:
        validate_integer_literals(value)
    elif isinstance(value, dict):
        for key in value:
            validate_integer_literals(key)
        return {key: normalize_json_numbers(item) for key, item in value.items()}
    elif isinstance(value, (list, tuple)):
        return [normalize_json_numbers(item) for item in value]
    return value


def canonical(value: Any) -> bytes:
    validate_integer_literals(value)
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode()


def validate_construction_environment(
    values: Mapping[str, str | None] | None,
) -> dict[str, str | None] | None:
    """Private, explicitly declared inputs needed to reconstruct an App."""
    if values is None:
        return None
    if not isinstance(values, Mapping) or len(values) > 64:
        raise ValueError("construction environment requires at most 64 declared names")
    captured = {}
    for name, value in values.items():
        if not isinstance(name, str) or not re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_]{0,127}", name
        ):
            raise ValueError(
                "construction environment names require 1–128 identifier characters"
            )
        if value is not None and (
            not isinstance(value, str) or "\0" in value or len(value.encode()) > 65536
        ):
            raise ValueError(
                "construction environment values require bounded text or null"
            )
        captured[name] = value
    if len(canonical(captured)) > 65536:
        raise ValueError(
            "construction environment exceeds its 64 KiB private settings bound"
        )
    return captured


@dataclass(frozen=True)
class Environment:
    id: str
    name: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        stable_key(self.id, "environment id")
        label(self.name or self.id, "environment name")
        if len((self.name or self.id).encode()) > 128:
            raise ValueError("environment name exceeds 128 bytes")


@dataclass(frozen=True)
class Placement:
    """Source-owned execution constraints, independent of datasource health."""

    requires: tuple[str, ...] = ()
    runner_contexts: tuple[str, ...] | None = None
    monitored_environments: tuple[str, ...] | None = None
    locality: Literal["any", "same-environment", "runner-target"] = "any"
    policy: Callable[[PlacementContext], str | None] | None = None

    def __post_init__(self) -> None:
        for name, values, minimum in (
            ("requires", self.requires, 0),
            ("runner_contexts", self.runner_contexts, 1),
            ("monitored_environments", self.monitored_environments, 1),
        ):
            if values is None and name != "requires":
                continue
            if not isinstance(values, tuple) or not minimum <= len(values) <= 512:
                raise ValueError(f"{name} requires a tuple of {minimum}–512 stable IDs")
            for identity in values:
                stable_key(identity, name)
            object.__setattr__(self, name, tuple(sorted(set(values))))
        if self.locality not in ("any", "same-environment", "runner-target"):
            raise ValueError("locality must be any, same-environment or runner-target")
        if self.policy is not None and (
            not callable(self.policy)
            or inspect.iscoroutinefunction(self.policy)
            or inspect.iscoroutinefunction(self.policy.__call__)
        ):
            raise ValueError("placement policy requires a synchronous callable")
        if self.policy is not None:
            try:
                inspect.signature(self.policy).bind(None)
            except (TypeError, ValueError) as error:
                raise ValueError(
                    "placement policy must accept one context argument"
                ) from error


@dataclass(frozen=True)
class Capability:
    """Declared deployment access, optionally restricted to monitored scopes."""

    name: str
    environments: tuple[str, ...] | None = None

    def __post_init__(self) -> None:
        stable_key(self.name, "capability name")
        scope = Placement(monitored_environments=self.environments)
        object.__setattr__(self, "environments", scope.monitored_environments)


@dataclass(frozen=True)
class Target:
    key: str
    label: str
    kind: str = "host"

    def to_dict(self) -> dict[str, str]:
        stable_key(self.key, "target key")
        stable_key(self.kind, "target kind")
        if len(self.kind) > 64:
            raise ValueError("target kind exceeds 64 characters")
        label(self.label, "target label")
        return asdict(self)


@dataclass(frozen=True)
class RunnerContext:
    """Logical execution location; not a controller installation/session ID."""

    id: str
    name: str | None = None
    capabilities: tuple[str | Capability, ...] = ()
    target: Target | None = None
    local_environment: Environment | None = None

    def __post_init__(self) -> None:
        stable_key(self.id, "runner context")
        label(self.name or self.id, "runner context name")
        if not isinstance(self.capabilities, tuple) or len(self.capabilities) > 512:
            raise ValueError("capabilities requires a tuple of at most 512 grants")
        grants: dict[str, str | Capability] = {}
        for grant in self.capabilities:
            if isinstance(grant, str):
                name = stable_key(grant, "capability name")
            elif isinstance(grant, Capability):
                name = grant.name
                if grant.environments is None:
                    grant = name
            else:
                raise ValueError("capabilities require stable IDs or Capability values")
            if name in grants and grants[name] != grant:
                raise ValueError(f"conflicting grants for capability {name}")
            grants[name] = grant
        object.__setattr__(
            self, "capabilities", tuple(grants[name] for name in sorted(grants))
        )
        if self.target is not None:
            if not isinstance(self.target, Target):
                raise ValueError("runner context target requires a Target")
            self.target.to_dict()
        if self.local_environment is not None and not isinstance(
            self.local_environment, Environment
        ):
            raise ValueError("local_environment requires an Environment")

    def supports(self, capability: str, environment: Environment) -> bool:
        """Whether this deployment declares access for this monitored scope."""
        scopes = self._capability_scopes
        return capability in scopes and (
            scopes[capability] is None or environment.id in scopes[capability]
        )

    @cached_property
    def _capability_scopes(self) -> Mapping[str, frozenset[str] | None]:
        # This immutable index derives from a frozen declaration, not eligibility.
        # A replacement RunnerContext gets its own index. It is not a dataclass
        # field, so it never changes private settings or source identity.
        return MappingProxyType(
            {
                grant if isinstance(grant, str) else grant.name: None
                if isinstance(grant, str) or grant.environments is None
                else frozenset(grant.environments)
                for grant in self.capabilities
            }
        )


@dataclass(frozen=True)
class PlacementContext:
    """Copied declared inputs for a consumer's synchronous placement policy."""

    runner: RunnerContext
    environment: Environment
    check_id: str
    targets: tuple[Target, ...]


@dataclass(frozen=True)
class _PlacementRequirements:
    contexts: frozenset[str] | None
    capabilities: frozenset[str]
    environments: frozenset[str] | None
    locality: Literal["any", "same-environment", "runner-target"]
    policies: tuple[Callable[[PlacementContext], str | None], ...]


@dataclass(frozen=True)
class Condition:
    """An explicit shared condition; monitored environment remains assignment-bound."""

    key: str
    label: str
    namespace: str | None = None

    def __post_init__(self) -> None:
        stable_key(self.key, "condition key")
        label(self.label, "condition label")
        if self.namespace is not None:
            stable_key(self.namespace, "condition namespace")

    def to_dict(self, source_id: str) -> dict[str, str]:
        return {
            "namespace": stable_key(
                self.namespace if self.namespace is not None else source_id,
                "condition namespace",
            ),
            "key": stable_key(self.key, "condition key"),
            "label": label(self.label, "condition label"),
        }


@dataclass(frozen=True)
class CheckGroup:
    """Browsing metadata scoped by source and monitored environment, not identity."""

    key: str
    label: str

    def __post_init__(self) -> None:
        stable_key(self.key, "check group key")
        label(self.label, "check group label")

    def to_dict(self) -> dict[str, str]:
        return validate_check_group({"key": self.key, "label": self.label})


def validate_check_group(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or set(value) != {"key", "label"}:
        raise ValueError("check group requires exactly key and label")
    return {
        "key": stable_key(value["key"], "check group key"),
        "label": label(value["label"], "check group label"),
    }


@dataclass(frozen=True)
class Output:
    key: str
    label: str | None = None
    target: Target | None = None
    condition: Condition | None = None
    group: CheckGroup | None = None

    def __post_init__(self) -> None:
        if self.condition is not None and not isinstance(self.condition, Condition):
            raise ValueError("output condition requires a Condition declaration")
        if self.group is not None and not isinstance(self.group, CheckGroup):
            raise ValueError("output group requires a CheckGroup declaration")


@dataclass(frozen=True)
class Parameter:
    type: Literal["number", "integer", "string", "boolean"]
    label: str
    unit: str | None = None
    minimum: float | int | None = None
    maximum: float | int | None = None
    max_length: int | None = None
    choices: tuple[Any, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        if self.type not in ("number", "integer", "string", "boolean"):
            raise ValueError("unsupported parameter type")
        label(self.label, "parameter label")
        if self.unit is not None and (
            not isinstance(self.unit, str)
            or len(self.unit.encode()) > 64
            or any(ord(c) < 32 for c in self.unit)
        ):
            raise ValueError("parameter unit must be text within 64 bytes")
        for bound in (self.minimum, self.maximum):
            if bound is not None and (
                self.type not in ("number", "integer") or not finite_number(bound)
            ):
                raise ValueError(
                    "numeric parameter bounds require finite floats or integers "
                    "within 4096 decimal digits"
                )
        if (
            self.minimum is not None
            and self.maximum is not None
            and self.minimum > self.maximum
        ):
            raise ValueError("parameter minimum exceeds maximum")
        if self.max_length is not None and (
            self.type != "string"
            or type(self.max_length) is not int
            or not 1 <= self.max_length <= 2048
        ):
            raise ValueError("string max_length must be between 1 and 2048 bytes")
        if len(self.choices) > 32 or any(
            type(value) not in (str, int, float, bool)
            or isinstance(value, float)
            and not math.isfinite(value)
            for value in self.choices
        ):
            raise ValueError(
                "parameter choices require at most 32 finite scalar values"
            )
        result = {
            key: value
            for key, value in asdict(self).items()
            if value is not None and value != ()
        }
        if self.choices:
            result["choices"] = list(self.choices)
            for choice in self.choices:
                validate_params(
                    {"value": choice},
                    {
                        "fields": {
                            "value": {
                                key: value
                                for key, value in result.items()
                                if key != "choices"
                            }
                        },
                        "comparisons": [],
                    },
                    {"value": choice},
                )
        return normalize_json_numbers(result)


class Datasource:
    """Marker for locally configured dependencies injected by type annotation."""

    placement = Placement()


class DatasourceFactory:
    """Factories implement new(*args, **kwargs) and return a Datasource."""

    placement = Placement()

    def new(self, *args: Any, **kwargs: Any) -> Datasource:
        raise NotImplementedError


class FromFactory:
    def __init__(self, factory: type[DatasourceFactory], *args: Any, **kwargs: Any):
        self.factory, self.args, self.kwargs = factory, args, kwargs


@dataclass(frozen=True)
class ManagedResource:
    """Declared discovery ownership within one source/observer inventory."""

    manager_key: str
    kind: str
    name: str
    origin: str

    def to_dict(self) -> dict[str, Any]:
        stable_key(self.manager_key, "discovery manager key")
        if self.kind not in {"interface", "filesystem"} or self.origin not in {
            "required",
            "discovered",
        }:
            raise ValueError("invalid managed resource kind or origin")
        if (
            not isinstance(self.name, str)
            or not self.name
            or len(self.name.encode()) > 2048
        ):
            raise ValueError("invalid managed resource name")
        return {
            "version": 1,
            "kind": "resource",
            "manager_key": self.manager_key,
            "resource_kind": self.kind,
            "resource_name": self.name,
            "origin": self.origin,
        }


@dataclass(frozen=True)
class Binding:
    function: Callable[..., Any]
    key: str | None = None
    target: Target | None = None
    environment: Environment | None = None
    params: Mapping[str, Any] | None = None
    outputs: tuple[Output, ...] = ()
    name: str | None = None
    group: CheckGroup | None = None
    discovery: ManagedResource | None = None

    def __post_init__(self) -> None:
        if self.group is not None and not isinstance(self.group, CheckGroup):
            raise ValueError("binding group requires a CheckGroup declaration")


def discover_checks(module: ModuleType | str) -> list[Callable[..., Any]]:
    """Strict recursive discovery; failed imports invalidate the whole inventory."""
    root = importlib.import_module(module) if isinstance(module, str) else module
    found: list[Callable[..., Any]] = []
    seen: set[int] = set()

    def visit(item: ModuleType) -> None:
        for value in vars(item).values():
            if (
                callable(value)
                and hasattr(value, "mondek_definition")
                and id(value) not in seen
            ):
                seen.add(id(value))
                found.append(value)
        if hasattr(item, "__path__"):
            for info in sorted(
                pkgutil.iter_modules(item.__path__, item.__name__ + "."),
                key=lambda info: info.name,
            ):
                visit(importlib.import_module(info.name))

    visit(root)
    return found


def validate_params(
    params: Any, schema: dict[str, Any], defaults: dict[str, Any]
) -> dict[str, Any]:
    """A delegated set is complete; source-owned sets remain exact."""
    if not isinstance(params, dict) or set(params) != set(defaults):
        raise ValueError("parameters must contain the complete declared set")
    if len(canonical(normalize_json_numbers(params))) > 16384:
        raise ValueError("parameters exceed 16 KiB")
    fields = schema["fields"]
    if fields and set(fields) != set(params):
        raise ValueError("UI parameters require a complete field schema")
    for key, value in params.items():
        stable_key(key, "parameter name")
        if key not in fields:
            if value != defaults[key]:
                raise ValueError(f"{key} is owned by the source")
            continue
        spec = fields[key]
        kind = spec["type"]
        valid = (
            kind == "number"
            and finite_number(value)
            or kind == "integer"
            and type(value) is int
            or kind == "string"
            and isinstance(value, str)
            and not any(ord(char) < 32 or ord(char) == 127 for char in value)
            or kind == "boolean"
            and type(value) is bool
        )
        if not valid:
            raise ValueError(f"{key} must be {kind}")
        if kind in ("number", "integer"):
            for bound, predicate in (
                ("minimum", lambda n, value=value: value < n),
                ("maximum", lambda n, value=value: value > n),
            ):
                if bound in spec and predicate(spec[bound]):
                    raise ValueError(f"{key} violates {bound}")
        if kind == "string" and len(value.encode()) > spec.get("max_length", 2048):
            raise ValueError(f"{key} exceeds maximum length")
        if "choices" in spec and value not in spec["choices"]:
            raise ValueError(f"{key} is not an allowed choice")
    for comparison in schema["comparisons"]:
        if any(
            schema["fields"].get(comparison[side], {}).get("type")
            not in ("integer", "number")
            for side in ("left", "right")
        ):
            raise ValueError("comparisons require two declared numeric parameters")
        left, right = params[comparison["left"]], params[comparison["right"]]
        if comparison["op"] not in ("lt", "lte") or not (
            left < right if comparison["op"] == "lt" else left <= right
        ):
            raise ValueError(
                f"require {comparison['left']} {comparison['op']} {comparison['right']}"
            )
    return deepcopy(params)


class App:
    def __init__(
        self,
        *,
        source_id: str,
        environment: Environment | None = None,
        checks: Iterable[Callable[..., Any] | Binding | ModuleType] = (),
        name: str | None = None,
        construction_environment: Mapping[str, str | None] | None = None,
        runner: RunnerContext | None = None,
    ):
        self.source_id = stable_key(source_id, "source id")
        self.name = label(name or source_id)
        self.environment = environment
        self._implicit_runner_context = runner is None
        if environment is not None and not isinstance(environment, Environment):
            raise ValueError("environment requires an Environment")
        if runner is None:
            if environment is None:
                raise ValueError("supply a RunnerContext or a default Environment")
            # Existing consumers retain their default subject and observer label.
            runner = RunnerContext(
                environment.id,
                environment.name,
                target=Target(environment.id, environment.name or environment.id),
            )
        if not isinstance(runner, RunnerContext):
            raise ValueError("runner requires a RunnerContext")
        self.runner = runner
        self._construction_environment = validate_construction_environment(
            construction_environment
        )
        self.bindings: dict[str, Binding] = {}
        self._catalogs: dict[str, Any] = {}
        self._providers: dict[type, Callable[[], Any]] = {}
        self._provider_settings: dict[type, dict[str, Any]] = {}
        self._frozen_selectors: dict[str, dict[str, Any]] = {}
        self._instances: dict[type, Any] = {}
        self._factory_instances: dict[bytes, Any] = {}
        self._placement_requirements: dict[
            Callable[..., Any], _PlacementRequirements
        ] = {}
        for entry in checks:
            entries = (
                discover_checks(entry) if isinstance(entry, ModuleType) else [entry]
            )
            for item in entries:
                self.add(item)

    def add(self, entry: Callable[..., Any] | Binding) -> None:
        binding = entry if isinstance(entry, Binding) else Binding(entry)
        definition = getattr(binding.function, "mondek_definition", None)
        if not definition or not definition["id"]:
            raise ValueError("registered checks require an explicit @check(id=...)")
        key = stable_key(binding.key or definition["id"], "check key")
        environments = definition.get("environments", ())
        additions = []
        if environments:
            if binding.environment is not None:
                if binding.environment.id not in {env.id for env in environments}:
                    raise ValueError(
                        "binding environment is outside declared environments"
                    )
                environments = (binding.environment,)
            for environment in environments:
                # Component IDs can contain separators and reach 128 characters.
                # A framed hash keeps expansion stable under reorder/add/remove.
                digest = sha256(canonical([key, environment.id])).hexdigest()[:32]
                expanded = f"{key[:48]}@{environment.id[:32]}-{digest}"
                additions.append(
                    (expanded, replace(binding, key=expanded, environment=environment))
                )
        else:
            additions.append((key, binding))
        self._add_bindings(additions)

    def _add_bindings(self, additions: list[tuple[str, Binding]]) -> None:
        keys = [key for key, _ in additions]
        duplicate = next((key for key in keys if key in self.bindings), None)
        if duplicate or len(keys) != len(set(keys)):
            raise ValueError(
                f"duplicate check identity: {duplicate}; use an explicit Binding key"
            )
        if len(self.bindings) + len(additions) > MAX_CHECKS:
            raise ValueError("consumer exceeds 512 checks")
        self.bindings.update(additions)
        self._placement_requirements.clear()

    def _placement_for(
        self, key: str, function: Callable[..., Any]
    ) -> _PlacementRequirements:
        if function in self._placement_requirements:
            return self._placement_requirements[function]
        rules = [function.mondek_definition.get("placement", Placement())]
        # Repeated bindings often share one function. Resolve annotations without
        # constructing its datasource or requiring an excluded provider to exist.
        if getattr(function, "__annotations__", None):
            hints = get_type_hints(function, include_extras=True)
            for name in inspect.signature(function).parameters:
                annotation = hints.get(name)
                if get_origin(annotation) is Annotated:
                    datasource, *metadata = get_args(annotation)
                    selectors = [
                        item for item in metadata if isinstance(item, FromFactory)
                    ]
                    if isinstance(datasource, type) and issubclass(
                        datasource, Datasource
                    ):
                        if len(selectors) != 1:
                            raise ValueError(
                                f"{key}: requires one FromFactory selector"
                            )
                        rules.append(datasource.placement)
                        for selector in selectors:
                            if not isinstance(selector.factory, type) or not issubclass(
                                selector.factory, DatasourceFactory
                            ):
                                raise ValueError(f"{key}: invalid datasource factory")
                            rules.append(selector.factory.placement)
                elif isinstance(annotation, type) and issubclass(
                    annotation, Datasource
                ):
                    rules.append(annotation.placement)

        allowed: set[str] | None = None
        required: set[str] = set()
        environments: set[str] | None = None
        locality = "any"
        policies = []
        for rule in rules:
            if not isinstance(rule, Placement):
                raise ValueError(f"{key}: placement requires a Placement declaration")
            if rule.runner_contexts is not None:
                contexts = set(rule.runner_contexts)
                allowed = contexts if allowed is None else allowed & contexts
            required.update(rule.requires)
            if rule.monitored_environments is not None:
                scopes = set(rule.monitored_environments)
                environments = scopes if environments is None else environments & scopes
            if rule.locality == "runner-target" or (
                rule.locality == "same-environment" and locality == "any"
            ):
                locality = rule.locality
            if rule.policy is not None and not any(
                rule.policy is policy for policy in policies
            ):
                policies.append(rule.policy)
        if allowed == set():
            raise ValueError(f"{key}: conflicting execution placement constraints")
        if environments == set():
            raise ValueError(f"{key}: conflicting monitored environment constraints")
        constraints = _PlacementRequirements(
            frozenset(allowed) if allowed is not None else None,
            frozenset(required),
            frozenset(environments) if environments is not None else None,
            locality,
            tuple(policies),
        )
        self._placement_requirements[function] = constraints
        return constraints

    def _placement_exclusion(self, key: str, binding: Binding) -> str | None:
        requirements = self._placement_for(key, binding.function)
        allowed, required = requirements.contexts, requirements.capabilities
        environment = binding.environment or self.environment
        # Inherent source support is a contract, unlike access available on this
        # particular observer. Never silently crop an impossible requested scope.
        if (
            environment is not None
            and requirements.environments is not None
            and environment.id not in requirements.environments
        ):
            raise ValueError(
                f"{key}: monitored environment {environment.id} "
                "is outside source support"
            )
        execution = self.runner.id
        if allowed is not None and execution not in allowed:
            return "Runs only in runner contexts: " + ", ".join(sorted(allowed))
        if missing := {
            name for name in required if name not in self.runner._capability_scopes
        }:
            return "Runner context lacks declared capabilities: " + ", ".join(
                sorted(missing)
            )
        if environment is None:
            raise ValueError(f"{key}: declare the monitored environment")
        if missing := {
            name for name in required if not self.runner.supports(name, environment)
        }:
            return (
                f"Capabilities do not cover monitored environment {environment.id}: "
                + ", ".join(sorted(missing))
            )
        if requirements.locality != "any":
            local = self.runner.local_environment
            if local is None:
                raise ValueError(f"{key}: locality requires runner.local_environment")
            if requirements.locality == "runner-target" and self.runner.target is None:
                raise ValueError(
                    f"{key}: runner-target locality requires runner.target"
                )
            if local.id != environment.id:
                return (
                    f"Requires execution in {environment.id}; "
                    f"runner executes in {local.id}"
                )
        if requirements.locality == "runner-target" or requirements.policies:
            targets = self._resolved_targets(binding, environment)
            if requirements.locality == "runner-target" and any(
                (target.key, target.kind)
                != (self.runner.target.key, self.runner.target.kind)
                for target in targets
            ):
                required_targets = sorted(
                    {
                        f"{target.kind}:{target.key}"
                        for target in targets
                        if (target.key, target.kind)
                        != (self.runner.target.key, self.runner.target.kind)
                    }
                )
                return (
                    "Requires execution on target "
                    + ", ".join(required_targets)
                    + "; runner target is "
                    + f"{self.runner.target.kind}:{self.runner.target.key}"
                )
            reason = None
            for policy in requirements.policies:
                # Frozen dataclasses plus fresh deep copies prevent a policy's
                # nested metadata changes from affecting other rules or the App.
                # Capabilities and Targets contain only frozen scalar/tuple
                # fields. Copy mutable Environment metadata without walking all
                # grants again for every binding and every worker validation.
                runner = copy(self.runner)
                if runner.local_environment is not None:
                    object.__setattr__(
                        runner,
                        "local_environment",
                        replace(
                            runner.local_environment,
                            metadata=deepcopy(runner.local_environment.metadata),
                        ),
                    )
                context = PlacementContext(
                    runner,
                    replace(environment, metadata=deepcopy(environment.metadata)),
                    key,
                    targets,
                )
                result = policy(context)
                if result is not None:
                    if inspect.iscoroutine(result):
                        result.close()
                    label(result, "placement policy exclusion reason")
                    reason = reason or result
            if reason is not None:
                return reason
        return None

    def _default_target(self, binding: Binding, environment: Environment) -> Target:
        return (
            binding.target
            or (self.runner.target if binding.environment is None else None)
            or Target(
                environment.id,
                environment.name or environment.id,
                "host"
                if self._implicit_runner_context
                and not binding.function.mondek_definition.get("environments")
                else "environment",
            )
        )

    def _resolved_targets(
        self, binding: Binding, environment: Environment
    ) -> tuple[Target, ...]:
        default = self._default_target(binding, environment)
        outputs = (
            binding.outputs
            or binding.function.mondek_definition["outputs"]
            or tuple(Output(key) for key in binding.function.expected_keys)
        )
        targets = tuple(output.target or default for output in outputs)
        for target in targets:
            target.to_dict()
        return targets

    def selected_bindings(self) -> dict[str, Binding]:
        """Select by declared placement, never by credentials or connectivity."""
        return {
            key: binding
            for key, binding in self.bindings.items()
            if self._placement_exclusion(key, binding) is None
        }

    def placement_summary(self) -> dict[str, Any]:
        excluded = []
        for key, binding in self.bindings.items():
            if reason := self._placement_exclusion(key, binding):
                excluded.append({"key": key, "reason": public_placement_reason(reason)})
        return {
            "runner_context": self.runner.id,
            "runner_context_label": self.runner.name or self.runner.id,
            "capabilities": [
                grant if isinstance(grant, str) else asdict(grant)
                for grant in self.runner.capabilities
            ],
            "local_environment": self.runner.local_environment.id
            if self.runner.local_environment is not None
            else None,
            "excluded_checks": excluded,
        }

    def register_datasource(self, datasource: type[Datasource], **kwargs: Any) -> None:
        if not issubclass(datasource, Datasource):
            raise ValueError("datasource must extend Datasource")
        inspect.signature(datasource).bind(**kwargs)
        self._register_provider(datasource, kwargs)

    def register_datasource_factory(
        self, factory: type[DatasourceFactory], **kwargs: Any
    ) -> None:
        if not issubclass(factory, DatasourceFactory):
            raise ValueError("factory must extend DatasourceFactory")
        inspect.signature(factory).bind(**kwargs)
        self._register_provider(factory, kwargs)

    def _register_provider(self, kind: type, kwargs: dict[str, Any]) -> None:
        settings = json.loads(canonical(kwargs))
        self._provider_settings[kind] = settings
        self._providers[kind] = lambda: kind(**deepcopy(settings))

    @staticmethod
    def _type_key(kind: type) -> str:
        return kind.__module__ + "." + kind.__qualname__

    def private_settings(self) -> dict[str, Any]:
        """Declared local configuration, persisted privately and never advertised."""
        selectors = {}
        for key, binding in self.bindings.items():
            for name, annotation in get_type_hints(
                binding.function, include_extras=True
            ).items():
                if get_origin(annotation) is Annotated:
                    for item in get_args(annotation)[1:]:
                        if isinstance(item, FromFactory):
                            selectors[key + ":" + name] = {
                                "factory": self._type_key(item.factory),
                                "args": item.args,
                                "kwargs": item.kwargs,
                            }
        construction = (
            {"construction_environment": self._construction_environment}
            if self._construction_environment is not None
            else {}
        )
        return json.loads(
            canonical(
                {
                    **construction,
                    **({"catalogs": self._catalogs} if self._catalogs else {}),
                    "environment": asdict(self.environment)
                    if self.environment
                    else None,
                    "runner_context": asdict(self.runner),
                    "implicit_runner_context": self._implicit_runner_context,
                    "binding_environments": {
                        key: asdict(binding.environment)
                        if binding.environment
                        else None
                        for key, binding in self.bindings.items()
                    },
                    "providers": {
                        self._type_key(kind): settings
                        for kind, settings in self._provider_settings.items()
                    },
                    "selectors": selectors,
                }
            )
        )

    def restore_private_settings(self, settings: dict[str, Any]) -> None:
        """Old snapshots use old declared settings even if deployment env changed."""
        construction = validate_construction_environment(
            settings.get("construction_environment")
        )
        if construction != self._construction_environment:
            raise ValueError(
                "consumer construction environment differs from prepared declaration"
            )
        providers = {self._type_key(kind): kind for kind in self._providers}
        if set(providers) != set(settings["providers"]) or set(self.bindings) != set(
            settings["binding_environments"]
        ):
            raise ValueError("consumer registration changed with deployment settings")
        for key, kwargs in settings["providers"].items():
            self._register_provider(providers[key], kwargs)
        environment = settings["environment"]
        self.environment = Environment(**environment) if environment else None
        self._implicit_runner_context = settings["implicit_runner_context"]
        if context := settings["runner_context"]:
            self.runner = RunnerContext(
                context["id"],
                context["name"],
                tuple(
                    grant
                    if isinstance(grant, str)
                    else Capability(
                        grant["name"],
                        tuple(grant["environments"])
                        if grant["environments"] is not None
                        else None,
                    )
                    for grant in context["capabilities"]
                ),
                Target(**context["target"]) if context["target"] else None,
                Environment(**context["local_environment"])
                if context.get("local_environment") is not None
                else None,
            )
        elif self.environment is not None:
            self.runner = RunnerContext(
                self.environment.id,
                self.environment.name,
                target=Target(
                    self.environment.id, self.environment.name or self.environment.id
                ),
            )
        else:
            raise ValueError("prepared settings require a runner context")
        for key, environment in settings["binding_environments"].items():
            self.bindings[key] = replace(
                self.bindings[key],
                environment=Environment(**environment) if environment else None,
            )
        self._frozen_selectors = deepcopy(settings["selectors"])
        self._placement_requirements.clear()

    def _instance(self, kind: type) -> Any:
        if kind not in self._instances:
            self._instances[kind] = self._providers[kind]()
        return self._instances[kind]

    def arguments(
        self, key: str, params: dict[str, Any], *, instantiate: bool = True
    ) -> dict[str, Any]:
        binding = self.bindings[key]
        if reason := self._placement_exclusion(key, binding):
            raise ValueError(f"{key}: excluded from this runner context. {reason}")
        hints = get_type_hints(binding.function, include_extras=True)
        kwargs: dict[str, Any] = {}
        for name, parameter in inspect.signature(binding.function).parameters.items():
            if parameter.kind in (
                parameter.POSITIONAL_ONLY,
                parameter.VAR_POSITIONAL,
                parameter.VAR_KEYWORD,
            ):
                raise ValueError("checks require named injectable parameters")
            annotation = hints.get(name)
            if name == "params":
                kwargs[name] = deepcopy(params)
            elif annotation is Environment:
                kwargs[name] = binding.environment or self.environment
                if kwargs[name] is None:
                    raise ValueError(f"{key}: declare the monitored environment")
            elif annotation is RunnerContext:
                kwargs[name] = self.runner
            elif get_origin(annotation) is Annotated:
                datasource, *metadata = get_args(annotation)
                selectors = [item for item in metadata if isinstance(item, FromFactory)]
                if (
                    len(selectors) != 1
                    or not isinstance(datasource, type)
                    or not issubclass(datasource, Datasource)
                ):
                    raise ValueError(
                        f"{name} requires a Datasource and one FromFactory"
                    )
                selector = selectors[0]
                frozen = self._frozen_selectors.get(key + ":" + name)
                if frozen:
                    if self._type_key(selector.factory) != frozen["factory"]:
                        raise ValueError(
                            "datasource factory type changed from prepared source"
                        )
                    selector = FromFactory(
                        selector.factory, *frozen["args"], **frozen["kwargs"]
                    )
                if selector.factory not in self._providers:
                    raise ValueError(f"unregistered factory for {name}")
                canonical([selector.args, selector.kwargs])
                descriptor = inspect.getattr_static(selector.factory, "new")
                # Attribute access already binds class methods and leaves static
                # methods receiver-free. Only instance methods need a placeholder
                # during constructor-free validation; inherited descriptors work
                # the same way as methods declared on this factory itself.
                receiver = (
                    ()
                    if isinstance(descriptor, (classmethod, staticmethod))
                    else (None,)
                )
                inspect.signature(selector.factory.new).bind(
                    *receiver, *selector.args, **selector.kwargs
                )
                if instantiate:
                    identity = canonical(
                        [
                            selector.factory.__module__,
                            selector.factory.__qualname__,
                            selector.args,
                            selector.kwargs,
                        ]
                    )
                    if identity not in self._factory_instances:
                        self._factory_instances[identity] = self._instance(
                            selector.factory
                        ).new(*selector.args, **selector.kwargs)
                    value = self._factory_instances[identity]
                    if not isinstance(value, datasource):
                        raise ValueError(
                            f"factory for {name} returned wrong datasource type"
                        )
                    kwargs[name] = value
            elif isinstance(annotation, type) and issubclass(annotation, Datasource):
                if annotation not in self._providers:
                    raise ValueError(f"unregistered datasource for {name}")
                if instantiate:
                    kwargs[name] = self._instance(annotation)
            elif parameter.default is parameter.empty:
                raise ValueError(f"parameter {name} has no injection or default")
        return kwargs

    def metadata(self, revision: str) -> list[dict[str, Any]]:
        return self._metadata(revision, self.selected_bindings().items())

    def _metadata_for_check(self, revision: str, key: str) -> list[dict[str, Any]]:
        # Preserve custom App.metadata behavior. Ordinary consumers build only
        # the selected definition after authenticating the complete snapshot.
        if type(self).metadata is not App.metadata:
            return [item for item in self.metadata(revision) if item["key"] == key]
        return self._metadata(revision, ((key, self.bindings[key]),))

    def _metadata(
        self,
        revision: str,
        bindings: Iterable[tuple[str, Binding]],
        *,
        validate_arguments: bool = True,
        allow_unbound: bool = False,
    ) -> list[dict[str, Any]]:
        checks = []
        for key, binding in bindings:
            definition = binding.function.mondek_definition
            environment = binding.environment or self.environment
            if environment is None and not allow_unbound:
                raise ValueError(f"{key}: declare the monitored environment")
            # An explicit per-environment instance represents that monitored
            # scope unless the source provides a more specific remote subject.
            target = (
                self._default_target(binding, environment)
                if environment is not None
                else binding.target or self.runner.target
            )
            outputs = (
                binding.outputs
                or definition["outputs"]
                or tuple(Output(key) for key in binding.function.expected_keys)
            )
            for output in outputs:
                # Inspect declarations before projecting known fields: subclass
                # attributes (including inherited nulls) must not vanish here.
                validate_invocation_scope(
                    {
                        name: None
                        for name in ("environment", "environment_label")
                        if hasattr(output, name)
                    }
                )
            if not 1 <= len(outputs) <= 16 or len(
                {output.key for output in outputs}
            ) != len(outputs):
                raise ValueError("checks require 1–16 unique output keys")
            schema = {
                "fields": {
                    name: spec.to_dict()
                    for name, spec in definition["parameters"].items()
                },
                "comparisons": [
                    {"left": left, "op": op, "right": right}
                    for left, op, right in definition["comparisons"]
                ],
            }
            if len(schema["fields"]) > 32 or len(schema["comparisons"]) > 32:
                raise ValueError("parameters require at most 32 fields and comparisons")
            params = dict(
                definition["params"] if binding.params is None else binding.params
            )
            if not definition["parameters"]:
                kinds = {
                    int: "integer",
                    float: "number",
                    str: "string",
                    bool: "boolean",
                }
                for parameter_name, default in params.items():
                    if type(default) not in kinds:
                        raise ValueError("source parameters must be scalar values")
                    schema["fields"][parameter_name] = {
                        "type": kinds[type(default)],
                        "label": parameter_name,
                    }
            validate_params(params, schema, params)
            if validate_arguments:
                self.arguments(key, params, instantiate=False)
            item = {
                "key": key,
                "label": label(binding.name or definition["name"] or definition["id"]),
                "environment": environment.id if environment else None,
                "environment_label": (environment.name or environment.id)
                if environment
                else None,
                "params_owner": "ui" if definition["parameters"] else "source",
                "parameter_schema": schema,
                "params": params,
                "outputs": [
                    {
                        "key": stable_key(output.key, "output key"),
                        "label": label(output.label or output.key),
                        "target": (output.target or target).to_dict()
                        if output.target or target
                        else None,
                        **(
                            {"condition": output.condition.to_dict(self.source_id)}
                            if output.condition is not None
                            else {}
                        ),
                        **(
                            {"group": (output.group or binding.group).to_dict()}
                            if output.group or binding.group
                            else {}
                        ),
                    }
                    for output in outputs
                ],
            }
            catalog = getattr(binding.function, "mondek_discovery", None)
            if binding.discovery is not None:
                item["discovery"] = binding.discovery.to_dict()
            elif catalog is not None and catalog.capability is not None:
                item["discovery"] = {
                    "version": 1,
                    "kind": "manager",
                    "capability": catalog.capability,
                }
            if definition.get("parameter_contract") is not None:
                if item["params_owner"] != "ui":
                    raise ValueError(
                        "parameter contracts require explicit UI-delegated parameters"
                    )
                item["parameter_contract"] = stable_key(
                    definition["parameter_contract"], "parameter contract"
                )
            for field_name, lower, upper in (
                ("interval_seconds", 0.1, 86400),
                ("timeout_seconds", 0.1, 300),
                ("freshness_seconds", 0.1, 172800),
            ):
                value = definition[field_name]
                if (
                    type(value) not in (int, float)
                    or not math.isfinite(value)
                    or not lower <= value <= upper
                ):
                    raise ValueError(f"invalid {field_name}")
                item[field_name] = value
            item = normalize_json_numbers(item)
            item["definition_revision"] = sha256(
                canonical([revision, item])
            ).hexdigest()
            checks.append(item)
        return checks

    def coverage_metadata(self, checks: list[dict[str, Any]]) -> dict[str, Any]:
        """Describe every registration without constructing excluded dependencies.

        Selected descriptors come from the actual public metadata, including a
        consumer's metadata override. Unselected declarations only need their
        public contract, never private provider registration or arguments.
        Ordinary authenticated selected workers reuse discovery's catalogue;
        custom metadata overrides retain full validation and recompute it.
        """
        if len(self.bindings) > MAX_CHECKS:
            raise ValueError("coverage exceeds 512 registered checks")
        selected = {item["key"]: item for item in checks}
        if len(selected) != len(checks) or not set(selected).issubset(self.bindings):
            raise ValueError("coverage selected keys differ from registered checks")
        candidates = []
        custom_metadata = getattr(self.metadata, "__func__", None) is not App.metadata
        for key, binding in self.bindings.items():
            reason = self._placement_exclusion(key, binding)
            if (reason is None) != (key in selected):
                raise ValueError("coverage placement differs from selected metadata")
            item = (
                selected[key]
                if key in selected
                else self._metadata(
                    "0" * 64,
                    ((key, binding),),
                    validate_arguments=False,
                    allow_unbound=True,
                )[0]
            )
            environment = item.get("environment")
            environment_label = item.get("environment_label")
            if environment is not None:
                _coverage_text(environment, 128, "coverage environment")
                if environment_label is not None:
                    label(environment_label, "coverage environment label")
            elif environment_label is not None:
                raise ValueError("unbound coverage environment cannot have a label")
            outputs = []
            for output in item["outputs"]:
                validate_invocation_scope(output)
                target = output["target"]
                if target is not None:
                    target = {
                        name: _coverage_text(
                            target[name], maximum, f"coverage target {name}"
                        )
                        for name, maximum in (
                            ("key", 200),
                            ("label", 200),
                            ("kind", 64),
                        )
                    }
                outputs.append(
                    {
                        "key": stable_key(output["key"], "coverage output key"),
                        "label": label(output["label"], "coverage output label"),
                        "target": target,
                        **(
                            {"group": validate_check_group(output["group"])}
                            if "group" in output
                            else {}
                        ),
                    }
                )
            if not 1 <= len(outputs) <= 16 or len(
                {output["key"] for output in outputs}
            ) != len(outputs):
                raise ValueError("coverage requires 1–16 unique outputs per check")
            resolved = (environment is not None or key in selected) and all(
                output["target"] is not None for output in outputs
            )
            custom_excluded = custom_metadata and key not in selected
            if custom_excluded:
                # Selected metadata overrides can redefine scope arbitrarily.
                # The base Binding cannot prove that an excluded scope matches.
                resolved = False
            if key in selected and not resolved:
                raise ValueError("selected coverage requires a resolved scope")
            requirements = self._placement_for(key, binding.function)
            # This comparable digest contains public contract/defaults only.
            # Executable definition hashes also bind private deployment settings
            # and cannot be compared across different runner installations.
            public_definition = {
                name: value
                for name, value in item.items()
                if name
                in {
                    "key",
                    "label",
                    "environment",
                    "environment_label",
                    "params_owner",
                    "parameter_schema",
                    "parameter_contract",
                    "params",
                    "outputs",
                    "interval_seconds",
                    "timeout_seconds",
                    "freshness_seconds",
                }
            }
            public_definition["environment"] = environment
            public_definition["environment_label"] = environment_label
            placement = {
                "requires": sorted(requirements.capabilities),
                "runner_contexts": sorted(requirements.contexts)
                if requirements.contexts is not None
                else None,
                "monitored_environments": sorted(requirements.environments)
                if requirements.environments is not None
                else None,
                "locality": requirements.locality,
                "policies": [
                    getattr(policy, "__module__", type(policy).__module__)
                    + "."
                    + getattr(policy, "__qualname__", type(policy).__qualname__)
                    for policy in requirements.policies
                ],
            }
            candidates.append(
                {
                    "key": stable_key(key, "coverage check key"),
                    "label": label(item["label"], "coverage check label"),
                    "selected": key in selected,
                    "exclusion_reason": public_placement_reason(reason)
                    if reason
                    else None,
                    "environment": environment,
                    "environment_label": environment_label,
                    "scope_resolved": resolved,
                    "scope_reason": (
                        "Custom metadata may redefine this excluded scope. "
                        "Declare authoritative excluded scopes in coverage_metadata."
                        if custom_excluded
                        else None
                        if resolved
                        else "The excluded check inherits a monitored environment or "
                        "target that this deployment does not declare."
                    ),
                    "definition_revision": sha256(
                        canonical(
                            normalize_json_numbers([public_definition, placement])
                        )
                    ).hexdigest(),
                    "outputs": outputs,
                }
            )
        return {
            "runner_context": {
                "id": self.runner.id,
                "label": self.runner.name or self.runner.id,
                "local_environment": self.runner.local_environment.id
                if self.runner.local_environment
                else None,
                "target": self.runner.target.to_dict() if self.runner.target else None,
                "capabilities": [
                    {"name": grant, "environments": None}
                    if isinstance(grant, str)
                    else {
                        "name": grant.name,
                        "environments": list(grant.environments)
                        if grant.environments is not None
                        else None,
                    }
                    for grant in self.runner.capabilities
                ],
            },
            "candidates": candidates,
        }


Consumer = App


def load_app(entrypoint: str) -> App:
    module_name, separator, attribute = entrypoint.partition(":")
    if (
        not separator
        or not all(part.isidentifier() for part in module_name.split("."))
        or not attribute.isidentifier()
    ):
        raise ValueError("consumer entry point must be module:app")
    app = getattr(importlib.import_module(module_name), attribute)
    if not isinstance(app, App):
        raise ValueError("consumer entry point must refer to an App")
    return app

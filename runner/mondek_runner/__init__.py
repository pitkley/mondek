# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Public authoring API, loaded on demand so transport helpers stay lightweight."""

from importlib import import_module
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .api import (
        Impact,
        Result,
        ResultBuilder,
        build_result,
        check,
        crit,
        ok,
        unknown,
        warn,
    )
    from .authoring import (
        App,
        Binding,
        Capability,
        CheckGroup,
        Condition,
        Consumer,
        Datasource,
        DatasourceFactory,
        Environment,
        FromFactory,
        ManagedResource,
        Output,
        Parameter,
        Placement,
        PlacementContext,
        RunnerContext,
        Target,
        discover_checks,
    )
    from .discovery import Discovery, DiscoveryCandidate, DiscoveryChoice

__all__ = [
    "App",
    "Binding",
    "Capability",
    "CheckGroup",
    "Condition",
    "Consumer",
    "Datasource",
    "DatasourceFactory",
    "Discovery",
    "DiscoveryCandidate",
    "DiscoveryChoice",
    "Environment",
    "FromFactory",
    "ManagedResource",
    "Impact",
    "Output",
    "Parameter",
    "Placement",
    "PlacementContext",
    "Result",
    "ResultBuilder",
    "RunnerContext",
    "Target",
    "build_result",
    "check",
    "crit",
    "discover_checks",
    "ok",
    "unknown",
    "warn",
]

_RESULT_EXPORTS = frozenset(
    (
        "Impact",
        "Result",
        "ResultBuilder",
        "build_result",
        "check",
        "crit",
        "ok",
        "unknown",
        "warn",
    )
)
_MODULE_EXPORTS = frozenset(("api", "authoring"))


def __getattr__(name: str) -> Any:
    if name in _MODULE_EXPORTS:
        return import_module("." + name, __name__)
    if name not in __all__:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    module = import_module(
        ".discovery"
        if name in {"Discovery", "DiscoveryCandidate", "DiscoveryChoice"}
        else ".api"
        if name in _RESULT_EXPORTS
        else ".authoring",
        __name__,
    )
    value = getattr(module, name)
    globals()[name] = value
    return value


def __dir__() -> list[str]:
    return sorted(set(globals()) | set(__all__) | _MODULE_EXPORTS)

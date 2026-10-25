# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bounded dynamic declarations, separated from frozen execution snapshots."""

from __future__ import annotations

import math
from collections.abc import Callable
from copy import deepcopy
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .authoring import App, Binding


@dataclass(frozen=True)
class DiscoveryCatalog:
    """Attach to a policy check as ``function.mondek_discovery``.

    Discovery returns all observed resources; selection also applies to absent
    resources retained during grace. Binding construction must perform no I/O.
    It is called with the frozen descriptor and presence on execution replay.
    """

    discover: Callable[[dict[str, Any]], dict[str, dict[str, Any]]]
    bind: Callable[[str, dict[str, Any], bool], Binding]
    select: Callable[[str, dict[str, Any], dict[str, Any]], bool] | None = None
    interval_seconds: float = 60
    grace_seconds: float = 300
    capability: str | None = None

    def __post_init__(self) -> None:
        if self.capability not in {None, "linux.resources.v1"}:
            raise ValueError("unsupported discovery selection capability")
        if not callable(self.discover) or not callable(self.bind):
            raise ValueError("catalog discovery and binding require callables")
        if self.select is not None and not callable(self.select):
            raise ValueError("catalog selection requires a callable")
        for value, minimum, maximum in (
            (self.interval_seconds, 1, 86400),
            (self.grace_seconds, 0, 604800),
        ):
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or not minimum <= value <= maximum
            ):
                raise ValueError("catalog interval or disappearance grace is invalid")


def declarations(app: App) -> dict[str, DiscoveryCatalog]:
    result = {}
    for key, binding in app.bindings.items():
        declaration = getattr(binding.function, "mondek_discovery", None)
        if declaration is not None:
            if not isinstance(declaration, DiscoveryCatalog):
                raise ValueError("mondek_discovery requires a DiscoveryCatalog")
            result[key] = declaration
    return result


def materialize(app: App, frozen: dict[str, Any]) -> None:
    """Expand authenticated catalog data without invoking discovery or selection."""
    from .authoring import canonical

    declared = declarations(app)
    if not isinstance(frozen, dict) or not set(frozen).issubset(declared):
        raise ValueError("frozen catalogs differ from consumer declarations")
    if len(canonical(frozen)) > 512 * 1024:
        raise ValueError("frozen catalogs exceed 512 KiB")
    app._catalogs = deepcopy(frozen)
    for key, resources in frozen.items():
        if not isinstance(resources, dict) or len(resources) > 512:
            raise ValueError("catalog must contain at most 512 resources")
        for resource_key, resource in sorted(resources.items()):
            if (
                not isinstance(resource_key, str)
                or not resource_key
                or len(resource_key.encode()) > 2048
                or not isinstance(resource, dict)
                or set(resource) != {"descriptor", "present"}
                or not isinstance(resource["descriptor"], dict)
                or type(resource["present"]) is not bool
            ):
                raise ValueError("invalid frozen catalog resource")
            binding = declared[key].bind(
                resource_key, deepcopy(resource["descriptor"]), resource["present"]
            )
            if app.bindings[key].group is not None:
                binding = replace(binding, group=app.bindings[key].group)
            if getattr(binding.function, "mondek_discovery", None) is not None:
                raise ValueError("catalog resources cannot declare nested catalogs")
            app.add(binding)


def prepare(
    app: App,
    previous: dict[str, Any],
    policies: dict[str, Any],
    now: float,
) -> dict[str, Any]:
    """Discover once; keep grace bookkeeping outside the snapshot identity."""
    from .authoring import canonical, normalize_json_numbers, validate_params

    declared = declarations(app)
    selected = app.selected_bindings()
    frozen, state, errors = {}, {}, []
    interval = None
    selections = {}
    for key, catalog in declared.items():
        if key not in selected:
            continue
        interval = min(interval or catalog.interval_seconds, catalog.interval_seconds)
        metadata = app._metadata_for_check("discovery", key)[0]
        defaults = metadata["params"]
        params = policies.get(key, defaults)
        try:
            validate_params(params, metadata["parameter_schema"], defaults)
        except ValueError:
            # A source update can replace its policy contract. Advertise the new
            # declaration instead of wedging discovery on the old active shape;
            # controller admission still decides whether it can be activated.
            params = defaults
            errors.append(
                f"{key}: active policy is incompatible with the new declaration; "
                "using source defaults for discovery"
            )
        old = deepcopy(previous.get(key, {}))
        succeeded = True
        try:
            observed = catalog.discover(deepcopy(params))
            if not isinstance(observed, dict) or len(observed) > 4096:
                raise ValueError("catalog must contain at most 4096 observed resources")
            observed = normalize_json_numbers(observed)
            if len(canonical(observed)) > 512 * 1024:
                raise ValueError("catalog evidence exceeds 512 KiB")
            current = {}
            for resource_key in sorted(set(old) | set(observed)):
                present = resource_key in observed
                descriptor = (
                    observed[resource_key]
                    if present
                    else old[resource_key]["descriptor"]
                )
                if (
                    not isinstance(resource_key, str)
                    or not resource_key
                    or len(resource_key.encode()) > 2048
                    or not isinstance(descriptor, dict)
                ):
                    raise ValueError("invalid discovered resource")
                if catalog.select is not None:
                    chosen = catalog.select(resource_key, deepcopy(descriptor), params)
                    if type(chosen) is not bool:
                        raise ValueError("catalog selection must return a boolean")
                    if not chosen:
                        continue
                missing_since = (
                    None if present else old[resource_key].get("missing_since")
                )
                if not present and missing_since is None:
                    missing_since = now
                if not present and now - missing_since >= catalog.grace_seconds:
                    continue
                current[resource_key] = {
                    "descriptor": descriptor,
                    "present": present,
                    "missing_since": missing_since,
                }
        except Exception as error:
            succeeded = False
            # Incomplete evidence never means an empty successful inventory.
            current = old
            for resource in current.values():
                if resource.get("missing_since") is not None:
                    resource["missing_since"] = now
            errors.append(
                f"{key}: discovery failed ({type(error).__name__}); "
                "prior resources retained"
            )
        if catalog.capability:
            selections[key] = {
                "status": "accepted" if succeeded else "failed",
                "params": deepcopy(params),
            }
        state[key] = current
        frozen[key] = {
            resource_key: {
                "descriptor": record["descriptor"],
                "present": record["present"],
            }
            for resource_key, record in current.items()
        }
    materialize(app, frozen)
    return {
        "state": state,
        "interval": interval,
        "errors": errors,
        "selections": selections,
    }

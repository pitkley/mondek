# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""An ordinary installed consumer: no source checkout imports or SDK stubs."""

import asyncio
from collections.abc import AsyncIterator, Iterator
from typing import assert_type

from mondek_runner import Target
from mondek_runner.packs.linux import Interface, LinuxHost, Selection, linux_checks

from mondek_runner import (
    Binding,
    CheckGroup,
    Discovery,
    DiscoveryCandidate,
    DiscoveryChoice,
)
from mondek_runner import App, Environment, Output, Parameter, Result, check, ok


@check(
    id="synchronous",
    outputs=(Output("value"),),
    params={"limit": 2},
    parameters={"limit": Parameter("integer", "Limit")},
)
def synchronous(*, params: dict[str, int]) -> Result:
    return ok("value", str(params["limit"]))


@check(id="asynchronous", expected_keys=("value",))
async def asynchronous(*, environment: Environment) -> Result:
    return ok("value", environment.id)


@check(id="streaming", expected_keys=("value",))
def streaming(*, environment: Environment) -> Iterator[Result]:
    yield ok("value", environment.id)


@check(id="async-streaming", expected_keys=("value",))
async def async_streaming(*, environment: Environment) -> AsyncIterator[Result]:
    yield ok("value", environment.id)


assert_type(synchronous(params={"limit": 3}), Result)
environment = Environment("test")
assert_type(streaming(environment=environment), Iterator[Result])
assert_type(async_streaming(environment=environment), AsyncIterator[Result])


async def main() -> None:
    assert_type(await asynchronous(environment=environment), Result)
    async for result in async_streaming(environment=environment):
        assert_type(result, Result)


app = App(
    source_id="typed",
    environment=environment,
    checks=[synchronous, asynchronous, streaming, async_streaming],
)
assert len(app.metadata("a" * 64)) == 4
asyncio.run(main())


review = Discovery(
    "Review volumes",
    "Update the consumer inventory.",
    choices=(
        DiscoveryChoice(
            "monitor",
            "Monitor",
            parameters={"limit": Parameter("integer", "Limit")},
            params={"limit": 90},
        ),
    ),
    candidates=(DiscoveryCandidate("data", "Data volume"),),
)
assert_type(ok("inventory", "Discovered", discovery=review), Result)
group = CheckGroup("operations", "Operations")
assert_type(Output("value", group=group).group, CheckGroup | None)
assert_type(Binding(synchronous, group=group).group, CheckGroup | None)

# Optional pack declarations retain a typed, ordinary Binding interface.

linux_bindings = linux_checks(
    LinuxHost(
        Target("host:typed", "Typed Linux"),
        environment,
        filesystems=("/",),
        interfaces=(Interface("eth0"),),
        discover=True,
        filesystem_selection=Selection(default_include=False, include=("/srv/*",)),
    )
)
assert_type(linux_bindings, list[Binding])

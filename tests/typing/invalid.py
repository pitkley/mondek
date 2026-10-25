# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Each marked line must produce an installed-consumer Pyright diagnostic."""

from valid import asynchronous, synchronous

from mondek_runner import Discovery, DiscoveryChoice, Parameter, Placement, check, ok
from mondek_runner import Binding, CheckGroup, Output

CheckGroup(123, "Group")  # error: reportArgumentType
Output("health", group="host")  # error: reportArgumentType
Binding(synchronous, group={})  # error: reportArgumentType

check(outputs=("not an Output",))  # error: reportArgumentType
check(parameters={"limit": 3})  # error: reportArgumentType
check(comparisons=(("warn", "eq", "crit"),))  # error: reportArgumentType
Parameter("float", "Limit")  # error: reportArgumentType
Placement(locality="nearby")  # error: reportArgumentType
synchronous(params="wrong")  # error: reportArgumentType
synchronous(3)  # error: reportCallIssue
synchronous(unknown=3)  # error: reportCallIssue


async def wrong_call() -> None:
    await asynchronous(environment=123)  # error: reportArgumentType


ok("inventory", "Observed", discovery={})  # error: reportArgumentType
DiscoveryChoice("m", "M", parameters={"x": 3})  # error: reportArgumentType
Discovery("Review", "Edit source", ("ignore",), ())  # error: reportArgumentType

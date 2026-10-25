# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Deploy explicitly configured node files, processes and filesystem paths."""

import os

from .node_resources import configuration_from_settings, make_app

raw = os.environ.get("MONDEK_NODE_RESOURCES_SETTINGS")
app = make_app(
    configuration_from_settings(raw or ""),
    construction_environment={"MONDEK_NODE_RESOURCES_SETTINGS": raw},
)

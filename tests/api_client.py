# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Generate a disposable stdlib read client for HTTP contract qualification.

This is test tooling, not a distributed SDK. Python JSON integers are retained as
integers; clients using binary floats for all JSON numbers have different limits.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


def generate(spec: dict[str, Any]) -> str:
    source = [
        "import json",
        "from urllib.request import Request, urlopen",
        "from urllib.parse import quote, urlencode",
        "class Client:",
        "    def __init__(self, origin): self.origin = origin.rstrip('/')",
        "    def _get(self, path, query):",
        "        url = self.origin + path + ('?' + urlencode(query) if query else '')",
        "        with urlopen(Request(url, headers={'Accept':'application/json'}), timeout=5) as response:",
        "            return json.load(response)",
    ]
    for path, item in spec["paths"].items():
        operation = item.get("get")
        if not operation:
            continue
        name = operation["operationId"]
        if not re.fullmatch(r"[a-zA-Z_]\w*", name):
            raise ValueError(f"Invalid client operation name: {name}")
        path_keys = re.findall(r"{(\w+)}", path)
        query_keys = [
            p["name"] for p in operation.get("parameters", []) if p.get("in") == "query"
        ]
        source.extend(
            [
                f"    def {name}(self, **parameters):",
                f"        path = {path!r}",
                f"        for key in {path_keys!r}:",
                "            path = path.replace('{' + key + '}', quote(str(parameters.pop(key)), safe=''))",
                f"        if set(parameters) - set({query_keys!r}): raise ValueError('Unknown query parameter')",
                "        return self._get(path, parameters)",
            ]
        )
    return "\n".join(source) + "\n"


if __name__ == "__main__":
    import sys

    Path(sys.argv[2]).write_text(generate(json.loads(Path(sys.argv[1]).read_text())))

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e
COPY --from=ghcr.io/astral-sh/uv:0.12.5@sha256:e85be844203885286c60ffad8a858d48afb6c5a5c237ca0e67f12e74b8f174b1 /uv /usr/local/bin/uv
WORKDIR /app
COPY runner /app/runner
COPY examples/consumers /app/examples/consumers
# Install the SDK and separately packaged consumer. Runtime code stays on the
# runner; the frozen dependency graph comes from the committed consumer lock.
# Keep the repository layout so the relative SDK source resolves identically.
ENV UV_PROJECT_ENVIRONMENT=/app/.venv UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy
RUN uv sync --project /app/examples/consumers --locked --no-dev --no-editable --compile-bytecode --no-cache --python /usr/local/bin/python
# Each check starts an isolated Python worker. Precompile the standard library
# before disabling bytecode writes; otherwise every run recompiles its imports.
RUN python -m compileall -q /usr/local/lib/python3.13
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 MONDEK_STATE_DIR=/state
RUN mkdir /state && chown 65532:65532 /state
USER 65532:65532
CMD ["python", "-m", "mondek_runner"]

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e
WORKDIR /app
COPY tests/fixtures/service.py /app/service.py
# Frequent health probes run as a non-root user and cannot cache stdlib imports.
RUN python -m compileall -q /usr/local/lib/python3.13 /app
ENV PYTHONUNBUFFERED=1 FIXTURE_STATE_DIR=/state
RUN mkdir /state && chown 65532:65532 /state
USER 65532:65532
EXPOSE 8080
CMD ["python", "/app/service.py"]

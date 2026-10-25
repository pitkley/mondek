# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e
WORKDIR /app
COPY runner /app/runner
COPY tests/performance/consumer.py tests/performance/supervisor.py tests/performance/sample.py /app/
RUN printf 'profile sample\n' > /app/sample.txt && python -m compileall -q /usr/local/lib/python3.13 /app && mkdir /state && chown 65532:65532 /state
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app/runner:/app
USER 65532:65532
CMD ["python", "/app/supervisor.py"]

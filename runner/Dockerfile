# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e AS runtime
# Debian gzip's notice spells its GFDL-1.3 reference as GFDL-3.
RUN ln -s GFDL-1.3 /usr/share/common-licenses/GFDL-3
WORKDIR /app
COPY runner/mondek_runner /app/runner/mondek_runner
COPY examples /app/examples
COPY LICENSE THIRD_PARTY_LICENSES.md /usr/share/doc/mondek/
COPY licensing/runtime/python /usr/share/doc/mondek/runtime/python/
COPY licensing/runtime-sources.json /usr/share/doc/mondek/runtime-sources.json
# This sample executes installed source and does not install packages at runtime.
# Remove both pip and ensurepip's vendored installer wheel from the final image.
RUN rm -rf /usr/local/lib/python3.13/site-packages/pip \
    /usr/local/lib/python3.13/site-packages/pip-*.dist-info \
    /usr/local/lib/python3.13/ensurepip /usr/local/bin/pip*
RUN python -m compileall -q /usr/local/lib/python3.13 /app/runner /app/examples
RUN mkdir /state && chown 65532:65532 /state
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/app/runner:/app/examples PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 65532:65532
CMD ["python", "-m", "mondek_runner"]

# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
FROM hexpm/elixir:1.20.3-erlang-29.0.5-debian-bookworm-20260824-slim@sha256:d0e7ade81190dda2517d441797f8ec4c36226742cc0d2789084b2d1ffbb457d8 AS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY controller/mix.exs controller/mix.lock ./
COPY controller/config ./config
RUN mix deps.get --only prod --check-locked && mix deps.compile

FROM node:24.19.0-bookworm-slim@sha256:a9f5f7c91a432850b2a8a7797adf5eadb6c733ceed61167806cee7ea7fbc29df AS assets
WORKDIR /app/assets
COPY controller/assets/package.json controller/assets/package-lock.json ./
RUN npm ci --ignore-scripts
COPY --from=dependencies /app/deps /app/deps
COPY controller/assets ./
RUN npm run build

FROM dependencies AS build
COPY controller/lib ./lib
COPY controller/priv ./priv
COPY --from=assets /app/priv/static/assets ./priv/static/assets
RUN mix compile --warnings-as-errors && mix phx.digest && mix release

FROM debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS runtime
# libsctp1 satisfies the bundled Erlang runtime's SCTP library dependency.
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*
# Debian gzip's notice spells its GFDL-1.3 reference as GFDL-3.
RUN ln -s GFDL-1.3 /usr/share/common-licenses/GFDL-3
WORKDIR /app
COPY --from=build --chown=65532:65532 /app/_build/prod/rel/mondek ./
COPY LICENSE THIRD_PARTY_LICENSES.md /usr/share/doc/mondek/
COPY licensing/runtime/otp /usr/share/doc/mondek/runtime/otp/
COPY licensing/runtime/elixir /usr/share/doc/mondek/runtime/elixir/
COPY licensing/runtime-sources.json /usr/share/doc/mondek/runtime-sources.json
COPY --chmod=755 controller/docker-entrypoint.sh /app/docker-entrypoint.sh
ENV HOME=/app LANG=C.UTF-8 PHX_SERVER=true PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
USER 65532:65532
EXPOSE 4000
ENTRYPOINT ["/app/docker-entrypoint.sh"]

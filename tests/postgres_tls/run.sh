#!/usr/bin/env bash
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture=$(mktemp -d)
project="mondek-postgres-tls-$$"
cleanup() {
  docker compose -p "$project" -f "$fixture/compose.yaml" down --volumes
  rm -rf "$fixture"
}
trap cleanup EXIT
cd "$fixture"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 -subj /CN=Mondek-test-CA 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj /CN=localhost 2>/dev/null
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n' > extensions
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 1 -extfile extensions 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout unrelated.key -out unrelated.crt -days 1 -subj /CN=Unrelated-test-CA 2>/dev/null
chmod 644 server.key
cat > pg_hba.conf <<'EOF'
local all all trust
hostssl sameuser all all trust
hostnossl plain all all trust
EOF
cat > compose.yaml <<'EOF'
services:
  postgres:
    image: postgres:18.6-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2
    environment:
      POSTGRES_USER: mondek
      POSTGRES_DB: mondek
      POSTGRES_HOST_AUTH_METHOD: trust
    ports:
      - "127.0.0.1:55439:5432"
    volumes:
      - .:/tls:ro
    command: [sh, -c, 'cp /tls/server.key /tmp/server.key && chown postgres /tmp/server.key && chmod 600 /tmp/server.key && exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tls/server.crt -c ssl_key_file=/tmp/server.key -c hba_file=/tls/pg_hba.conf']
EOF
docker compose -p "$project" up -d --wait
for _attempt in $(seq 1 30); do
  if docker compose -p "$project" exec -T postgres pg_isready -U mondek -d mondek; then break; fi
  sleep 1
done
docker compose -p "$project" exec -T postgres createdb -U mondek plain
cd "$repo/controller"
PGHOST=localhost PGPORT=55439 PGUSER=mondek PGDATABASE=mondek \
  MONDEK_TLS_TEST_CA="$fixture/ca.crt" MONDEK_TLS_TEST_UNTRUSTED_CA="$fixture/unrelated.crt" MIX_ENV=test \
  mix run --no-start profiles/postgres_tls.exs

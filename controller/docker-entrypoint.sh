#!/bin/sh
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
set -eu
/app/bin/mondek eval 'Mondek.Release.migrate()'
exec /app/bin/mondek start

#!/usr/bin/env bash
# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

# Called only on disposable GitHub-hosted packaged runners. Keep the previous
# cleanup for heavy qualification; smoke needs 60 GiB of build/test headroom.
df -h /
case "${MONDEK_CI_MODE:?CI mode is required}" in
  smoke)
    available_kib=$(df -Pk / | awk 'NR == 2 {print $4}')
    if [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
      printf '%s\n' 'Could not determine available disk space' >&2
      exit 1
    fi
    if (( available_kib >= 60 * 1024 * 1024 )); then
      printf '%s\n' 'At least 60 GiB free; skipping Android SDK cleanup for smoke'
      exit 0
    fi
    ;;
  full|browser) ;;
  *) printf 'Unknown CI mode: %s\n' "$MONDEK_CI_MODE" >&2; exit 2 ;;
esac
sudo rm -rf -- /usr/local/lib/android/sdk
df -h /

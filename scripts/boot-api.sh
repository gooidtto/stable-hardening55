#!/bin/sh
# API bootstrap wrapper. It runs before the existing stable boot and never
# changes client credentials or runtime protocol definitions.
set -eu
if [ -z "${RAILWAY_PUBLIC_DOMAIN:-}" ] || [ -z "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] || [ -z "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
  if [ -n "${RAILWAY_TOKEN:-}" ] || [ -n "${RAILWAY_API_TOKEN:-}" ]; then
    set +e
    python3 /opt/xray/scripts/railway_setup.py
    rc=$?
    set -e
    if [ "$rc" -eq 10 ]; then
      echo "RAILWAY_API_REDEPLOY=REQUESTED"
      exit 0
    fi
    if [ "$rc" -ne 0 ]; then
      echo "FATAL: Railway API networking bootstrap failed" >&2
      exit "$rc"
    fi
  fi
fi
exec /opt/xray/scripts/boot.sh

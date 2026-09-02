#!/bin/sh
set -eu
umask 077
D="${RAILWAY_VOLUME_MOUNT_PATH:-${DATA_DIR:-/data}}"
mkdir -p "$D"

# Railway system variables can appear slightly after the container process starts.
# Wait for the CURRENT deployment networking data. If Railway does not expose
# them to the process, reuse the last known-good endpoint snapshot on the volume
# so node discovery can continue without rotating client identity.
resolve_public_domain() {
  value="${RAILWAY_PUBLIC_DOMAIN:-}"
  if [ -n "$value" ]; then printf '%s' "$value"; return 0; fi
  value="${RAILWAY_PUBLIC_URL:-}"
  case "$value" in
    https://*) value="${value#https://}"; value="${value%%/*}"; printf '%s' "$value"; return 0;;
    http://*) value="${value#http://}"; value="${value%%/*}"; printf '%s' "$value"; return 0;;
  esac
  return 1
}

PUBLIC_DOMAIN=""
TCP_HOST=""
TCP_PORT=""
NETWORK_WAIT_SECONDS="${RAILWAY_NETWORK_WAIT_SECONDS:-90}"
case "$NETWORK_WAIT_SECONDS" in ''|*[!0-9]*) NETWORK_WAIT_SECONDS=90;; esac

n=0
while [ "$n" -lt "$NETWORK_WAIT_SECONDS" ]; do
  if value="$(resolve_public_domain 2>/dev/null)"; then PUBLIC_DOMAIN="$value"; fi
  TCP_HOST="${RAILWAY_TCP_PROXY_DOMAIN:-}"
  TCP_PORT="${RAILWAY_TCP_PROXY_PORT:-}"
  if [ -n "$PUBLIC_DOMAIN" ] && [ -n "$TCP_HOST" ] && [ -n "$TCP_PORT" ]; then
    break
  fi
  if [ "$n" -eq 0 ]; then echo "NETWORKING_DISCOVERY=WAITING_FOR_CURRENT_RAILWAY_ENDPOINTS"; fi
  sleep 1
  n=$((n + 1))
done

NETWORKING_SOURCE="current-deployment-environment"
NETWORKING_AUTHORITATIVE="true"

# Fallback: use the persisted last-known-good Railway endpoints. This is only
# allowed when the current deployment did not expose the Railway variables at
# all; it never overwrites the snapshot with guessed values.
if [ -z "$PUBLIC_DOMAIN" ] || [ -z "$TCP_HOST" ] || [ -z "$TCP_PORT" ]; then
  if [ -s "$D/networking-snapshot.json" ]; then
    snapshot_values="$(python3 - "$D/networking-snapshot.json" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
    p=str(d.get("public_domain", "")).strip()
    t=d.get("tcp_proxy", {}) or {}
    h=str(t.get("domain", "")).strip()
    port=str(t.get("port", "")).strip()
    if p and h and port.isdigit() and 1 <= int(port) <= 65535:
        print(p); print(h); print(port)
except Exception:
    pass
PY
)"
    if [ "$(printf '%s\n' "$snapshot_values" | wc -l)" -ge 3 ]; then
      OLD_PUBLIC="$(printf '%s\n' "$snapshot_values" | sed -n '1p')"
      OLD_TCP_HOST="$(printf '%s\n' "$snapshot_values" | sed -n '2p')"
      OLD_TCP_PORT="$(printf '%s\n' "$snapshot_values" | sed -n '3p')"
      if [ -n "$OLD_PUBLIC" ] && [ -n "$OLD_TCP_HOST" ] && [ -n "$OLD_TCP_PORT" ]; then
        PUBLIC_DOMAIN="$OLD_PUBLIC"
        TCP_HOST="$OLD_TCP_HOST"
        TCP_PORT="$OLD_TCP_PORT"
        NETWORKING_SOURCE="persisted-last-known-good"
        NETWORKING_AUTHORITATIVE="false"
        echo "NETWORKING_DISCOVERY=FALLBACK_PERSISTED_ENDPOINTS"
      fi
    fi
fi

[ -n "$PUBLIC_DOMAIN" ] || { echo "FATAL: no Railway public endpoint available (current environment or persisted snapshot)" >&2; exit 1; }
[ -n "$TCP_HOST" ] && [ -n "$TCP_PORT" ] || { echo "FATAL: no Railway TCP Proxy available (current environment or persisted snapshot)" >&2; exit 1; }
case "$TCP_PORT" in ''|*[!0-9]*) echo "FATAL: Railway TCP Proxy port must be numeric" >&2; exit 1;; esac
[ "$TCP_PORT" -ge 1 ] && [ "$TCP_PORT" -le 65535 ] || { echo "FATAL: Railway TCP Proxy port out of range" >&2; exit 1; }

export RAILWAY_PUBLIC_DOMAIN="$PUBLIC_DOMAIN"
export RAILWAY_TCP_PROXY_DOMAIN="$TCP_HOST"
export RAILWAY_TCP_PROXY_PORT="$TCP_PORT"

if [ "$NETWORKING_SOURCE" = "current-deployment-environment" ]; then
  printf '{"source":"current-deployment-environment","authoritative":true,"public_domain":"%s","tcp_proxy_domain":"%s","tcp_proxy_port":%s,"application_port":8080}\n' "$PUBLIC_DOMAIN" "$TCP_HOST" "$TCP_PORT" > "$D/networking-snapshot.json.tmp"
  mv -f "$D/networking-snapshot.json.tmp" "$D/networking-snapshot.json"
  chmod 600 "$D/networking-snapshot.json"
fi

echo "STARTUP_LIFECYCLE=networking-discovery"
echo "RAILWAY_NETWORKING_SOURCE=$NETWORKING_SOURCE"
echo "RAILWAY_NETWORKING_AUTHORITATIVE=$NETWORKING_AUTHORITATIVE"
echo "RAILWAY_CURRENT_PUBLIC=$PUBLIC_DOMAIN"
echo "RAILWAY_CURRENT_TCP=$TCP_HOST:$TCP_PORT"
echo "NETWORKING_DISCOVERY=PASS wait_seconds=$n source=$NETWORKING_SOURCE"
echo "RAILWAY_ENDPOINTS_RESOLVED=PASS"
echo "PERSISTENCE_POLICY=preserve-existing-runtime"
echo "NODE_REGENERATION=only-if-required"
echo "SUBSCRIPTION_REGENERATION=only-if-required"
echo "UUID_ROTATION=disabled"
echo "REALITY_KEY_ROTATION=disabled"
echo "XRAY_GATEWAY_START=preserve-stable-runtime"
exec /opt/xray/scripts/guard.sh

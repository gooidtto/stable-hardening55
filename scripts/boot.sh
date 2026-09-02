#!/bin/sh
set -eu
umask 077
D="${RAILWAY_VOLUME_MOUNT_PATH:-${DATA_DIR:-/data}}"
mkdir -p "$D"

# Railway system variables can appear slightly after the container process starts.
# Wait for the CURRENT deployment networking data instead of failing immediately.
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

[ -n "$PUBLIC_DOMAIN" ] || { echo "FATAL: current Railway public endpoint unavailable after ${NETWORK_WAIT_SECONDS}s" >&2; exit 1; }
[ -n "$TCP_HOST" ] && [ -n "$TCP_PORT" ] || { echo "FATAL: current Railway TCP Proxy unavailable after ${NETWORK_WAIT_SECONDS}s" >&2; exit 1; }
case "$TCP_PORT" in ''|*[!0-9]*) echo "FATAL: Railway TCP Proxy port must be numeric" >&2; exit 1;; esac
[ "$TCP_PORT" -ge 1 ] && [ "$TCP_PORT" -le 65535 ] || { echo "FATAL: Railway TCP Proxy port out of range" >&2; exit 1; }

printf '{"source":"current-deployment-environment","authoritative":true,"public_domain":"%s","tcp_proxy_domain":"%s","tcp_proxy_port":%s,"application_port":8080}\n' "$PUBLIC_DOMAIN" "$TCP_HOST" "$TCP_PORT" > "$D/networking-snapshot.json.tmp"
mv -f "$D/networking-snapshot.json.tmp" "$D/networking-snapshot.json"
chmod 600 "$D/networking-snapshot.json"
echo "STARTUP_LIFECYCLE=networking-discovery"
echo "RAILWAY_NETWORKING_SOURCE=current-deployment-environment"
echo "RAILWAY_NETWORKING_AUTHORITATIVE=true"
echo "RAILWAY_CURRENT_PUBLIC=$PUBLIC_DOMAIN"
echo "RAILWAY_CURRENT_TCP=$TCP_HOST:$TCP_PORT"
echo "NETWORKING_DISCOVERY=PASS wait_seconds=$n"
echo "PERSISTENCE_POLICY=preserve-existing-runtime"
echo "NODE_REGENERATION=only-if-required"
echo "SUBSCRIPTION_REGENERATION=only-if-required"
echo "UUID_ROTATION=disabled"
echo "REALITY_KEY_ROTATION=disabled"
echo "XRAY_GATEWAY_START=preserve-stable-runtime"
exec /opt/xray/scripts/guard.sh

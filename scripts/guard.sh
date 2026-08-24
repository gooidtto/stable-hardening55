#!/bin/sh
set -eu

# Runtime-discovered deployment. No project/release/node names are hard-coded.
# Railway networking is authoritative for the current deployment.
PUBLIC_DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"
TCP_HOST="${RAILWAY_TCP_PROXY_DOMAIN:-}"
TCP_PORT="${RAILWAY_TCP_PROXY_PORT:-}"
[ -n "$PUBLIC_DOMAIN" ] || { echo "FATAL: RAILWAY_PUBLIC_DOMAIN unavailable" >&2; exit 1; }
[ -n "$TCP_HOST" ] && [ -n "$TCP_PORT" ] || { echo "FATAL: Railway TCP Proxy unavailable" >&2; exit 1; }
case "$TCP_PORT" in ''|*[!0-9]*) echo "FATAL: RAILWAY_TCP_PROXY_PORT must be numeric" >&2; exit 1;; esac
[ "$TCP_PORT" -ge 1 ] && [ "$TCP_PORT" -le 65535 ] || { echo "FATAL: Railway TCP Proxy port out of range" >&2; exit 1; }

# Cloudflare is capability-based: complete configuration enables optional Node 5;
# absent configuration leaves the four-node Railway topology intact.
# Canonical variables are preferred; legacy aliases are accepted only as migration aliases.
cf_value() {
  name="$1"
  eval "value=\${$name:-}"
  printf '%s' "$value"
}
CF_TOKEN="$(cf_value CLOUDFLARE_TUNNEL_TOKEN)"; [ -n "$CF_TOKEN" ] || CF_TOKEN="$(cf_value CF_TUNNEL_TOKEN)"; [ -n "$CF_TOKEN" ] || CF_TOKEN="$(cf_value TUNNEL_TOKEN)"
CF_ID="$(cf_value CLOUDFLARE_TUNNEL_ID)"; [ -n "$CF_ID" ] || CF_ID="$(cf_value CF_TUNNEL_ID)"; [ -n "$CF_ID" ] || CF_ID="$(cf_value TUNNEL_ID)"
CF_HOST="$(cf_value CLOUDFLARE_PUBLIC_HOSTNAME)"; [ -n "$CF_HOST" ] || CF_HOST="$(cf_value CF_PUBLIC_HOSTNAME)"
CF_ORIGIN="$(cf_value CLOUDFLARE_ORIGIN_SERVICE)"; [ -n "$CF_ORIGIN" ] || CF_ORIGIN="$(cf_value CF_ORIGIN_SERVICE)"
CF_PORT="$(cf_value CLOUDFLARE_XHTTP_PORT)"; [ -n "$CF_PORT" ] || CF_PORT="$(cf_value WS_PORT)"; [ -n "$CF_PORT" ] || CF_PORT="$(cf_value CLOUDFLARE_WS_PORT)"; [ -n "$CF_PORT" ] || CF_PORT="$(cf_value CF_WS_PORT)"
CF_PATH="$(cf_value CLOUDFLARE_XHTTP_PATH)"; [ -n "$CF_PATH" ] || CF_PATH="$(cf_value WS_PATH)"; [ -n "$CF_PATH" ] || CF_PATH="$(cf_value CLOUDFLARE_WS_PATH)"; [ -n "$CF_PATH" ] || CF_PATH="$(cf_value CF_WS_PATH)"

cf_count=0; [ -n "$CF_TOKEN" ] && cf_count=$((cf_count+1)); [ -n "$CF_ID" ] && cf_count=$((cf_count+1)); [ -n "$CF_HOST" ] && cf_count=$((cf_count+1)); [ -n "$CF_ORIGIN" ] && cf_count=$((cf_count+1)); [ -n "$CF_PORT" ] && cf_count=$((cf_count+1)); [ -n "$CF_PATH" ] && cf_count=$((cf_count+1))
if [ "$cf_count" -ne 0 ] && [ "$cf_count" -ne 6 ]; then
  missing=""; [ -n "$CF_TOKEN" ] || missing="${missing}CLOUDFLARE_TUNNEL_TOKEN,"; [ -n "$CF_ID" ] || missing="${missing}CLOUDFLARE_TUNNEL_ID,"; [ -n "$CF_HOST" ] || missing="${missing}CLOUDFLARE_PUBLIC_HOSTNAME,"; [ -n "$CF_ORIGIN" ] || missing="${missing}CLOUDFLARE_ORIGIN_SERVICE,"; [ -n "$CF_PORT" ] || missing="${missing}CLOUDFLARE_XHTTP_PORT,"; [ -n "$CF_PATH" ] || missing="${missing}CLOUDFLARE_XHTTP_PATH,"
  echo "FATAL: incomplete Cloudflare XHTTP configuration; missing=${missing%,}" >&2; exit 1
fi
if [ "$cf_count" -eq 6 ]; then
  case "$CF_PORT" in ''|*[!0-9]*) echo "FATAL: Cloudflare XHTTP port must be numeric" >&2; exit 1;; esac
  [ "$CF_PORT" -ge 1 ] && [ "$CF_PORT" -le 65535 ] || { echo "FATAL: Cloudflare XHTTP port out of range" >&2; exit 1; }
  case "$CF_PORT" in 8080|10086|10087|10088|10089) echo "FATAL: Cloudflare XHTTP port conflicts with an internal port" >&2; exit 1;; esac
  case "$CF_PATH" in /*) ;; *) echo "FATAL: Cloudflare XHTTP path must start with /" >&2; exit 1;; esac
fi
export CLOUDFLARE_TUNNEL_TOKEN="$CF_TOKEN" CLOUDFLARE_TUNNEL_ID="$CF_ID" CLOUDFLARE_PUBLIC_HOSTNAME="$CF_HOST" CLOUDFLARE_ORIGIN_SERVICE="$CF_ORIGIN" CLOUDFLARE_XHTTP_PORT="$CF_PORT" CLOUDFLARE_XHTTP_PATH="$CF_PATH"

export NODE_MODE="${NODE_MODE:-auto}"
export EXPECTED_NODES="${EXPECTED_NODES:-auto}"

python3 /opt/xray/scripts/runtime-manifest.py

echo "PRODUCTION_GUARD=PASS"
echo "NODE_MODE=$NODE_MODE"
echo "EXPECTED_NODES=$EXPECTED_NODES"
echo "RAILWAY_PUBLIC_DOMAIN=$PUBLIC_DOMAIN"
echo "RAILWAY_TCP_PROXY=$TCP_HOST:$TCP_PORT"
[ "$cf_count" -eq 6 ] && echo "CLOUDFLARE_CAPABILITY=enabled" || echo "CLOUDFLARE_CAPABILITY=disabled"
[ "$cf_count" -eq 6 ] && echo "CLOUDFLARE_TRANSPORT=XHTTP_TLS"
exec /opt/xray/scripts/start.sh

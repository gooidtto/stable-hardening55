#!/bin/sh
set -eu
umask 077
BUILD_ID="upload-baseline-2026-08-24"
SOURCE_BUILD="upload-baseline-2026-08-24"
D="${RAILWAY_VOLUME_MOUNT_PATH:-${DATA_DIR:-/data}}"
C="${XRAY_CONFIG:-${D}/config.json}"
mkdir -p "$D" "$(dirname "$C")"
write_secret(){ f="$1"; v="$2"; t="$f.tmp"; printf '%s\n' "$v" >"$t"; chmod 600 "$t"; mv -f "$t" "$f"; }
PUBLIC_DOMAIN="${RAILWAY_PUBLIC_DOMAIN:-}"; TCP_HOST="${RAILWAY_TCP_PROXY_DOMAIN:-}"; TCP_PORT="${RAILWAY_TCP_PROXY_PORT:-}"
[ -n "$PUBLIC_DOMAIN" ] || { echo "FATAL: RAILWAY_PUBLIC_DOMAIN unavailable" >&2; exit 1; }
[ -n "$TCP_HOST" ] && [ -n "$TCP_PORT" ] || { echo "FATAL: Railway TCP Proxy unavailable" >&2; exit 1; }
UUID_FILE="$D/uuid.txt"
if [ -s "$UUID_FILE" ]; then UUID=$(tr -d '[:space:]' <"$UUID_FILE"); echo "UUID_PERSISTENCE=REUSED"; else UUID=$(xray uuid); write_secret "$UUID_FILE" "$UUID"; echo "UUID_PERSISTENCE=CREATED"; fi
PRIV_FILE="$D/reality_private_key.txt"; PUB_FILE="$D/reality_public_key.txt"; TOKEN_FILE="$D/subscription_token.txt"
if [ -s "$PRIV_FILE" ] && [ -s "$PUB_FILE" ]; then PRIVATE_KEY=$(tr -d '[:space:]' <"$PRIV_FILE"); PUBLIC_KEY=$(tr -d '[:space:]' <"$PUB_FILE"); else OUT="$(xray x25519 2>&1)"; PRIVATE_KEY=$(printf '%s\n' "$OUT" | awk -F': ' '/^PrivateKey/{print $2;exit}'); PUBLIC_KEY=$(printf '%s\n' "$OUT" | awk -F': ' '/^Password/{print $2;exit}'); [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || { echo "FATAL: failed to generate REALITY keys" >&2; exit 1; }; write_secret "$PRIV_FILE" "$PRIVATE_KEY"; write_secret "$PUB_FILE" "$PUBLIC_KEY"; fi
if [ -s "$TOKEN_FILE" ]; then TOKEN=$(tr -d '[:space:]' <"$TOKEN_FILE"); else TOKEN=$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))'); write_secret "$TOKEN_FILE" "$TOKEN"; fi
CF_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-${CF_TUNNEL_TOKEN:-${TUNNEL_TOKEN:-}}}"; CF_ID="${CLOUDFLARE_TUNNEL_ID:-${CF_TUNNEL_ID:-${TUNNEL_ID:-}}}"; CF_HOST="${CLOUDFLARE_PUBLIC_HOSTNAME:-${CF_PUBLIC_HOSTNAME:-}}"; CF_ORIGIN="${CLOUDFLARE_ORIGIN_SERVICE:-${CF_ORIGIN_SERVICE:-}}"; CF_PORT="${CLOUDFLARE_XHTTP_PORT:-${WS_PORT:-${CLOUDFLARE_WS_PORT:-${CF_WS_PORT:-}}}}"; CF_PATH="${CLOUDFLARE_XHTTP_PATH:-${WS_PATH:-${CLOUDFLARE_WS_PATH:-${CF_WS_PATH:-}}}}"
export DATA_DIR="$D" XRAY_CONFIG="$C" UUID PRIVATE_KEY PUBLIC_KEY PUBLIC_DOMAIN RAILWAY_TCP_PROXY_DOMAIN="$TCP_HOST" RAILWAY_TCP_PROXY_PORT="$TCP_PORT" GATEWAY_PORT=8080 REALITY_RAW_SNI="${REALITY_RAW_SNI:-www.cloudflare.com}" REALITY_RAW_TARGET="${REALITY_RAW_TARGET:-www.cloudflare.com:443}" REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}" REALITY_XHTTP_SNI="${REALITY_XHTTP_SNI:-www.apple.com}" REALITY_XHTTP_TARGET="${REALITY_XHTTP_TARGET:-www.apple.com:443}" REALITY_GRPC_SNI="${REALITY_GRPC_SNI:-www.bing.com}" REALITY_GRPC_TARGET="${REALITY_GRPC_TARGET:-www.bing.com:443}" GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-grpc-service}" XHTTP_PATH="${XHTTP_PATH:-/xhttp}"
export CLOUDFLARE_TUNNEL_TOKEN="$CF_TOKEN" CLOUDFLARE_TUNNEL_ID="$CF_ID" CLOUDFLARE_PUBLIC_HOSTNAME="$CF_HOST" CLOUDFLARE_ORIGIN_SERVICE="$CF_ORIGIN" CLOUDFLARE_XHTTP_PORT="$CF_PORT" CLOUDFLARE_XHTTP_PATH="$CF_PATH" WS_PORT="$CF_PORT" WS_PATH="$CF_PATH"
CF_MISSING=""
[ -n "$CF_TOKEN" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_TUNNEL_TOKEN"
[ -n "$CF_ID" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_TUNNEL_ID"
[ -n "$CF_HOST" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_PUBLIC_HOSTNAME"
[ -n "$CF_ORIGIN" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_ORIGIN_SERVICE"
[ -n "$CF_PORT" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_XHTTP_PORT"
[ -n "$CF_PATH" ] || CF_MISSING="$CF_MISSING CLOUDFLARE_XHTTP_PATH"
if [ -n "$CF_MISSING" ]; then echo "CLOUDFLARE_CONFIG_MISSING=$(printf '%s' "$CF_MISSING" | sed 's/^ *//')"; else echo "CLOUDFLARE_CONFIG_MISSING=none"; fi
python3 /opt/xray/scripts/generate.py
RUNTIME="$D/runtime.json"; [ -s "$RUNTIME" ] || { echo "FATAL: runtime state was not generated" >&2; exit 1; }
EXPECTED=$(python3 - "$RUNTIME" <<'PY'
import json,sys
print(int(json.load(open(sys.argv[1])).get("nodes",{}).get("count",0) or 0))
PY
)
case "$EXPECTED" in 4|5) ;; *) echo "FATAL: invalid runtime node count: $EXPECTED" >&2; exit 1;; esac
CF_ENABLED=$(python3 - "$RUNTIME" <<'PY'
import json,sys
print("1" if json.load(open(sys.argv[1])).get("cloudflare",{}).get("enabled") is True else "0")
PY
)
CF_PORT_STATE=$(python3 - "$RUNTIME" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])).get("cloudflare",{}).get("xhttp_port"); print(v if v is not None else "")
PY
)
python3 - "$D/subscription.txt" "$RUNTIME" "$UUID" <<'PY'
import json,re,sys
from pathlib import Path
sub=Path(sys.argv[1]); runtime=json.loads(Path(sys.argv[2]).read_text()); uuid=sys.argv[3]; lines=[x.strip() for x in sub.read_text().splitlines() if x.strip()]
expected=int(runtime["nodes"]["count"]); public=runtime["public_domain"]; tcp=runtime["tcp_proxy"]
if len(lines)!=expected: raise SystemExit(f"FATAL: expected {expected} nodes, got {len(lines)}")
ids=[]
for i,line in enumerate(lines,1):
    m=re.match(r"vless://([^@]+)@([^:]+):(\d+)\?",line)
    if not m or m.group(1)!=uuid: raise SystemExit(f"FATAL: subscription UUID mismatch at node {i}")
    ids.append((m.group(2),m.group(3)))
if ids[0] != (public,"443"): raise SystemExit("FATAL: NODE1 endpoint does not match current Railway public domain")
for idx in (1,2,3):
    if ids[idx] != (str(tcp["domain"]),str(tcp["port"])): raise SystemExit(f"FATAL: Node{idx+1} endpoint does not match current Railway TCP proxy")
if expected==5:
    cf=runtime.get("cloudflare",{}); host=str(cf.get("public_hostname","") or "")
    if ids[4] != (host,"443"): raise SystemExit("FATAL: NODE5 endpoint does not match current Cloudflare hostname")
    if "type=xhttp" not in lines[4] or "#VLESS%20XHTTP%20TLS%20%C2%B7%20Cloudflare%20Tunnel" not in lines[4]: raise SystemExit("FATAL: NODE5 subscription is not VLESS XHTTP TLS Cloudflare")
    if "type=ws" in lines[4] or "cloudflare-ws-tls" in lines[4]: raise SystemExit("FATAL: NODE5 regression to WebSocket detected")
print(f"SUBSCRIPTION_ENDPOINT_INVARIANT=PASS public={public} tcp={tcp['domain']}:{tcp['port']} nodes={expected}")
print(f"SUBSCRIPTION_COUNT={len(lines)}")
PY
python3 - "$C" "$UUID" <<'PY'
import json,sys
from pathlib import Path
config=json.loads(Path(sys.argv[1]).read_text()); uuid=sys.argv[2]; ids=[c.get("id") for i in config.get("inbounds",[]) for c in i.get("settings",{}).get("clients",[]) if c.get("id")]
if not ids or any(x!=uuid for x in ids): raise SystemExit("FATAL: Xray UUID does not match deployment UUID")
print("UUID_INVARIANT=OK")
PY
xray run -test -config "$C"
XP=""; GP=""; CFP=""
cleanup(){ kill "$XP" "$GP" "$CFP" 2>/dev/null || true; wait "$XP" 2>/dev/null || true; wait "$GP" 2>/dev/null || true; wait "$CFP" 2>/dev/null || true; }
trap cleanup INT TERM EXIT
xray run -config "$C" & XP=$!
if [ "$CF_ENABLED" = 1 ]; then
  cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:2000 run --token "$CF_TOKEN" >/data/cloudflared.log 2>&1 & CFP=$!
  i=0
  while :; do
    if python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:2000/ready", timeout=1).read()' 2>/dev/null; then echo "CLOUDFLARED_READY=pass"; break; fi
    if ! kill -0 "$CFP" 2>/dev/null; then echo "FATAL: cloudflared exited before readiness" >&2; tail -50 /data/cloudflared.log >&2 || true; exit 1; fi
    i=$((i+1)); [ "$i" -lt "${CLOUDFLARE_READY_TIMEOUT:-45}" ] || { echo "FATAL: cloudflared readiness timeout" >&2; tail -50 /data/cloudflared.log >&2 || true; exit 1; }; sleep 1
  done
fi
wait_port(){ h="$1"; p="$2"; label="$3"; i=0; while :; do if python3 -c 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),1);s.close()' "$h" "$p" 2>/dev/null; then echo "READY_CHECK=$label:$p"; return 0; fi; if ! kill -0 "$XP" 2>/dev/null; then echo "FATAL: xray exited before $label:$p" >&2; exit 1; fi; i=$((i+1)); [ "$i" -lt "${READY_TIMEOUT:-90}" ] || { echo "FATAL: readiness timeout $label:$p" >&2; exit 1; }; sleep 1; done; }
wait_port 127.0.0.1 10086 xhttp-http; wait_port 127.0.0.1 10087 raw-reality-vision; wait_port 127.0.0.1 10088 xhttp-reality; wait_port 127.0.0.1 10089 grpc-reality
if [ "$CF_ENABLED" = 1 ]; then wait_port 127.0.0.1 "$CF_PORT_STATE" cloudflare-xhttp-origin; fi
echo "BUILD_ID=$BUILD_ID SOURCE_BUILD=$SOURCE_BUILD NODE5=VLESS_XHTTP_TLS_CLOUDFLARE"
echo "========== DEPLOYMENT SUMMARY =========="
echo "RELEASE=$BUILD_ID"
echo "NODE_MODE=${NODE_MODE:-auto}"
echo "NODES=$EXPECTED"
if [ "$CF_ENABLED" = 1 ]; then echo "CLOUDFLARE=enabled"; echo "TRANSPORT=XHTTP_TLS"; echo "CLOUDFLARED=READY"; else echo "CLOUDFLARE=disabled"; fi
echo "SUBSCRIPTION_COUNT=$EXPECTED"
echo "SUBSCRIPTION_CHECK=PASS"
echo "XRAY=READY"
echo "GATEWAY=STARTING"
echo "PERSISTENCE_MODE=STABLE"
echo "========================================="
exec python3 /opt/xray/scripts/gateway.py

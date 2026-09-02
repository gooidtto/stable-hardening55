#!/usr/bin/env python3
"""Stable runtime generator.

Generate the Xray runtime only when a client-visible identity/configuration input
has changed or required runtime artifacts are missing. Otherwise preserve the
existing config, subscription and runtime metadata byte-for-byte.
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

D = Path(os.environ.get("DATA_DIR", "/data"))
D.mkdir(parents=True, exist_ok=True)
C = Path(os.environ.get("XRAY_CONFIG", str(D / "config.json")))
SUB = D / "subscription.txt"
RUNTIME = D / "runtime.json"
SNAP = D / "stable-runtime-inputs.json"


def env(name, default=""):
    return (os.environ.get(name) or default).strip()


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def inputs():
    # Do not persist secret values; only fingerprints are stored.
    values = {
        "public_domain": env("PUBLIC_DOMAIN"),
        "tcp_proxy_domain": env("RAILWAY_TCP_PROXY_DOMAIN"),
        "tcp_proxy_port": env("RAILWAY_TCP_PROXY_PORT"),
        "uuid": env("UUID"),
        "reality_private_key": env("PRIVATE_KEY"),
        "reality_public_key": env("PUBLIC_KEY"),
        "raw_sni": env("REALITY_RAW_SNI", "www.cloudflare.com").lower().rstrip("."),
        "raw_target": env("REALITY_RAW_TARGET", "www.cloudflare.com:443"),
        "xhttp_sni": env("REALITY_XHTTP_SNI", "www.apple.com").lower().rstrip("."),
        "xhttp_target": env("REALITY_XHTTP_TARGET", "www.apple.com:443"),
        "grpc_sni": env("REALITY_GRPC_SNI", "www.bing.com").lower().rstrip("."),
        "grpc_target": env("REALITY_GRPC_TARGET", "www.bing.com:443"),
        "fingerprint": env("REALITY_FINGERPRINT", "chrome"),
        "xhttp_path": env("XHTTP_PATH", "/xhttp"),
        "grpc_service_name": env("GRPC_SERVICE_NAME", "grpc-service"),
        "cf_token": env("CLOUDFLARE_TUNNEL_TOKEN"),
        "cf_id": env("CLOUDFLARE_TUNNEL_ID"),
        "cf_host": env("CLOUDFLARE_PUBLIC_HOSTNAME").lower().rstrip("."),
        "cf_origin": env("CLOUDFLARE_ORIGIN_SERVICE"),
        "cf_port": env("CLOUDFLARE_XHTTP_PORT"),
        "cf_path": env("CLOUDFLARE_XHTTP_PATH"),
    }
    return {k: sha(v) for k, v in values.items()}


def load(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def artifacts_valid():
    if not C.is_file() or C.stat().st_size < 32:
        return False
    if not SUB.is_file() or SUB.stat().st_size < 32:
        return False
    runtime = load(RUNTIME)
    if not runtime or runtime.get("public_domain") != env("PUBLIC_DOMAIN"):
        return False
    tcp = runtime.get("tcp_proxy", {}) or {}
    if str(tcp.get("domain", "")) != env("RAILWAY_TCP_PROXY_DOMAIN"):
        return False
    if str(tcp.get("port", "")) != env("RAILWAY_TCP_PROXY_PORT"):
        return False
    if int((runtime.get("nodes", {}) or {}).get("count", 0) or 0) not in (4, 5):
        return False
    return True


def main():
    current = inputs()
    previous = load(SNAP) or {}
    same = previous.get("inputs") == current
    if same and artifacts_valid():
        print("RUNTIME_PERSISTENCE=REUSED")
        print("NODE_REGENERATION=SKIPPED")
        print("SUBSCRIPTION_REGENERATION=SKIPPED")
        print("CLIENT_IDENTITY=UNCHANGED")
        print(f"RUNTIME_INPUT_FINGERPRINT={sha(json.dumps(current, sort_keys=True, separators=(',', ':')))}")
        return 0

    reason = "initial" if not previous else "inputs-changed-or-artifacts-missing"
    print(f"RUNTIME_PERSISTENCE=REBUILD reason={reason}")
    print("NODE_REGENERATION=REQUIRED")
    print("SUBSCRIPTION_REGENERATION=REQUIRED")
    subprocess.run([sys.executable, "/opt/xray/scripts/generate.py"], check=True)
    SNAP.write_text(json.dumps({"schema": 1, "inputs": current}, indent=2) + "\n")
    try:
        os.chmod(SNAP, 0o600)
    except OSError:
        pass
    print("RUNTIME_PERSISTENCE=SNAPSHOT_SAVED")
    print(f"RUNTIME_INPUT_FINGERPRINT={sha(json.dumps(current, sort_keys=True, separators=(',', ':')))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# syntax=docker/dockerfile:1
ARG XRAY_VERSION=26.3.27
ARG CLOUDFLARED_VERSION=2026.7.3
FROM ghcr.io/xtls/xray-core:${XRAY_VERSION} AS xray
FROM cloudflare/cloudflared:${CLOUDFLARED_VERSION} AS cloudflared
FROM python:3.12-alpine3.22
ARG XRAY_VERSION
ARG CLOUDFLARED_VERSION
ENV XRAY_VERSION=${XRAY_VERSION} CLOUDFLARED_VERSION=${CLOUDFLARED_VERSION} PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN apk add --no-cache openssl ca-certificates && mkdir -p /etc/xray /data /opt/xray/scripts /opt/xray/config /opt/xray/site
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY scripts/ /opt/xray/scripts/
COPY config/ /opt/xray/config/
COPY site/ /opt/xray/site/
# Keep runtime source immutable: never patch protocol definitions during image build.
# The build must fail if Node 5 regresses to the deprecated WebSocket transport,
# or if the runtime loses the Railway endpoint/8080 invariants.
RUN python3 -m py_compile /opt/xray/scripts/*.py && \
    grep -q 'vless-xhttp-cloudflare' /opt/xray/scripts/generate.py && \
    grep -q 'type":"xhttp"' /opt/xray/scripts/generate.py && \
    grep -q 'cloudflare-xhttp-tls' /opt/xray/scripts/generate.py && \
    grep -q 'tcp_proxy_expected_target":8080' /opt/xray/scripts/runtime-manifest.py && \
    grep -q 'SUBSCRIPTION_ENDPOINT_INVARIANT=PASS' /opt/xray/scripts/start.sh &&     grep -q 'DEPLOYMENT SUMMARY' /opt/xray/scripts/start.sh &&     grep -q 'application/json' /opt/xray/scripts/gateway.py && \
    grep -q 'NODE5 endpoint does not match current Cloudflare hostname' /opt/xray/scripts/start.sh && \
    ! grep -q 'cloudflare-ws-tls' /opt/xray/scripts/generate.py && \
    ! grep -q 'type":"ws"' /opt/xray/scripts/generate.py && \
    chmod 0755 /usr/local/bin/xray /usr/local/bin/cloudflared /opt/xray/scripts/*.sh /opt/xray/scripts/*.py && \
    chmod 0644 /opt/xray/config/* /opt/xray/site/*
ENV BUILD_ID=upload-baseline-2026-08-24 \
    SOURCE_BUILD=upload-baseline-2026-08-24 \
    NODE_MODE=auto \
    EXPECTED_NODES=auto \
    PORT=8080 \
    GATEWAY_PORT=8080 \
    XRAY_CONFIG=/etc/xray/config.json \
    DATA_DIR=/data \
    REALITY_RAW_SNI=www.cloudflare.com \
    REALITY_RAW_TARGET=www.cloudflare.com:443 \
    REALITY_FINGERPRINT=chrome \
    REALITY_XHTTP_SNI=www.apple.com \
    REALITY_XHTTP_TARGET=www.apple.com:443 \
    REALITY_GRPC_SNI=www.bing.com \
    REALITY_GRPC_TARGET=www.bing.com:443 \
    GRPC_SERVICE_NAME=grpc-service \
    XHTTP_PATH=/xhttp \
    READY_TIMEOUT=90 \
    CLOUDFLARE_READY_TIMEOUT=45 \
    GATEWAY_MAX_CONNECTIONS=512 \
    GATEWAY_READ_TIMEOUT=20 \
    GATEWAY_UPSTREAM_TIMEOUT=10 \
    GATEWAY_IDLE_TIMEOUT=900 \
    GATEWAY_MAX_INITIAL=131072 \
    GATEWAY_LOGLEVEL=INFO
RUN echo "SOURCE_BUILD=${SOURCE_BUILD} BUILD_ID=${BUILD_ID} NODE5=VLESS_XHTTP_TLS_CLOUDFLARE"
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/ready', timeout=8).read()"
WORKDIR /opt/xray
ENTRYPOINT ["/opt/xray/scripts/boot.sh"]

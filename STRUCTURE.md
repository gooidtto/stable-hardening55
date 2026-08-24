# Repository Structure

```text
.
├── .github/
│   └── workflows/
│       └── package-release.yml   Release ZIP + SHA-256 packaging
├── config/
│   └── reality-sni-candidates.txt
├── scripts/
│   ├── boot.sh                   Container entrypoint
│   ├── start.sh                  Runtime supervisor / service lifecycle
│   ├── guard.sh                  Startup and production validation
│   ├── generate.py               Runtime config + subscription generator
│   ├── gateway.py                HTTP/TCP gateway and subscription endpoint
│   └── runtime-manifest.py       Runtime manifest generation
├── site/
│   └── index.html                Public landing/status page
├── Dockerfile                    Reproducible runtime image
├── railway.toml                  Railway deployment configuration
├── RELEASE-MANIFEST.json         Release metadata
├── README.md                     Deployment and architecture documentation
├── .gitignore                    Local/generated-file exclusions
└── .dockerignore                 Docker build-context exclusions
```

## Runtime state

Generated credentials, subscription state, runtime manifests, logs, and other mutable deployment state belong under `/data` and must not be committed to Git.

## Source of truth

Static repository files define the executable implementation. Railway runtime networking is authoritative for generated public endpoints. Persistent `/data` state is used for identity continuity and change detection only.

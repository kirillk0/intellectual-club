# Intellectual Club

## Repository layout

- `server/` — Phoenix/Ash application
- `frontend/` — Vite SPA built into `server/priv/static/assets`
- `native_tools/` — Rust workspace for native helper binaries and outlet runners
- `bin/` — repository-level helper scripts
- `docs/` — system documentation

## Docker

The root `Dockerfile` builds the Phoenix release from `server/` and the SPA from `frontend/`.

The root `compose.yaml` is configured for the PostgreSQL-backed deployment profile.

The shell outlet image is built from `native_tools/outlet-shell-image/Dockerfile`.

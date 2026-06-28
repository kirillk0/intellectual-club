# Intellectual Club

## Repository layout

- `server/` — Phoenix/Ash application
- `frontend/` — Vite SPA built into `server/priv/static/assets`
- `data/` — local runtime files, including file storage
- `native_tools/` — Rust workspace for native helper binaries and outlet runners
- `bin/` — repository-level helper scripts
- `docs/` — system documentation
- `assets/` — local temporary artifacts and runtime files (gitignored)

## Local development

1. `cd server && mix setup`
2. `./bin/dev-screen start`
3. Open `http://localhost:4000`

Helpful commands:

- `./bin/dev-screen status`
- `./bin/dev-screen attach`
- `./bin/dev-screen stop`
- `./bin/run-dev-server` to run the server in the foreground

Local development and tests use PostgreSQL through `DATABASE_URL` or the dev launcher database configuration.

## Docker

The root `Dockerfile` builds the Phoenix release from `server/` and the SPA from `frontend/`.

The root `compose.yaml` is configured for the PostgreSQL-backed deployment profile.

The shell outlet image is built from `native_tools/outlet-shell-image/Dockerfile`.

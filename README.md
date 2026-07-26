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

Create an administrator in a one-off Compose container:

```bash
docker compose run --rm app bin/create-admin
```

The same release command can be used with a published image. Attach an interactive
terminal and provide a PostgreSQL URL reachable from the container:

```bash
docker run --rm -it \
  --network <network> \
  -e DATABASE_URL='postgresql://<user>:<password>@<host>/<database>' \
  <image> bin/create-admin
```

The command applies pending database migrations, then prompts for the username and
password. It always creates a new administrator and refuses to modify an existing
username.

The shell outlet image is built from `native_tools/outlet-shell-image/Dockerfile`.

# Native Tools

This directory contains native helper tools for Intellectual Club.

The Rust workspace builds all native binaries together:

- `openai-oauth` — OpenAI OAuth PKCE helper with token refresh support
- `intellectual-club-launcher` — desktop/CLI launcher that runs embedded PostgreSQL and the Phoenix release
- `outlet-core` — shared HTTP transport, pairing, file helpers, runner loop, and provider interfaces
- `outlet-shell` — reusable shell outlet tools
- `outlet-shell-daemon` — headless binary for containers and server environments
- `outlet-shell-desktop` — desktop GUI for managing multiple shell outlet profiles

Build all binaries:

```bash
cargo build --manifest-path native_tools/Cargo.toml --release
```

Run the shell daemon locally:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p outlet-shell-daemon -- \
  --server-url http://localhost:4000 \
  --token '<token>'
```

Run the desktop app:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p outlet-shell-desktop
```

Run OpenAI OAuth:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth -- --refresh '<refresh_token>'
```

Run the desktop launcher GUI from a dev artifact bundle:

```bash
./build/dev/bin/intellectual-club-launcher
```

Run the launcher from CLI:

```bash
./build/dev/bin/intellectual-club-launcher start
./build/dev/bin/intellectual-club-launcher status --json
./build/dev/bin/intellectual-club-launcher backup
./build/dev/bin/intellectual-club-launcher move-files --to /path/to/files
./build/dev/bin/intellectual-club-launcher stop
```

The launcher stores config, PostgreSQL data, file storage, backups, runtime status, and
cached PostgreSQL installations in OS-specific app data directories via
`directories::ProjectDirs`.

## Shell Outlet Image

The canonical shell Docker image uses `outlet-shell-daemon` as the entrypoint command while keeping a Python utility environment for agent work.

Build and run:

```bash
docker build -t outlet-shell -f native_tools/outlet-shell-image/Dockerfile .
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_TOKEN="<token>" \
  outlet-shell
```

The image contains common CLI tools and the Python data/science utility packages from `native_tools/outlet-shell-image/requirements.additional.txt`. The host folder `./share` can be mounted into the container at `/mnt/share` if you want a shared workspace.

## Shell Daemon Settings

Required settings:

- `OUTLET_SERVER_URL` or `--server-url`
- `OUTLET_TOKEN` or `--token`

Optional settings:

- `OUTLET_RUNNER_ID` or `--runner-id`
- `OUTLET_LOG_LEVEL` or `--log-level`
- `OUTLET_MAX_CONCURRENCY` or `--max-concurrency`
- `OUTLET_POLL_MAX_WAIT_SECONDS` or `--poll-max-wait`
- `OUTLET_COMPLETE_MAX_RETRIES` or `--complete-max-retries`
- `OUTLET_COMPLETE_MAX_SECONDS` or `--complete-max-seconds`
- `SHELL_OUTLET_MAX_STREAM_CHARS`
- `SHELL_OUTLET_MAX_SUMMARY_CHARS`
- `SHELL_OUTLET_WINDOWS_FORCE_UTF8`

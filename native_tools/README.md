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

## Desktop Shell Releases

The `Publish Outlet Shell Desktop` GitHub Actions workflow builds and publishes:

- a macOS arm64 application bundle;
- a Windows x64 executable;
- SHA-256 checksums for both archives.

Every push to `main` that changes the desktop app, its local dependencies, the
Cargo workspace manifests, or the release workflow builds and publishes a new
release automatically. The tag combines the commit UTC timestamp and short SHA:

```text
outlet-shell-desktop-20260711T074742Z-45940cc0a1a8
```

Re-running the workflow for the same commit reuses the existing release without
requiring a version or a manually created tag.

Run OpenAI OAuth:

```bash
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth
cargo run --manifest-path native_tools/Cargo.toml -p openai-oauth -- --refresh '<refresh_token>'
```

Build and run the desktop launcher from the development macOS app bundle:

```bash
./bin/build-dev-artifacts
open "build/dev/Intellectual Club.app"
```

Opening the app starts PostgreSQL and the bundled BEAM release, then opens the web UI.
Closing the launcher window leaves both services running. Run the bundled launcher from
CLI to manage them:

```bash
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" start
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" restart
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" status --json
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" logs
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" open
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" create-admin
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" backup
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" move-files --to /path/to/files
"build/dev/Intellectual Club.app/Contents/MacOS/intellectual-club-launcher" stop
```

The unsigned Apple Silicon production bundle is published automatically in GitHub
Releases. It supports macOS 15 and newer.

The launcher stores config, PostgreSQL data, file storage, backups, runtime status, and
cached PostgreSQL installations in OS-specific app data directories via
`directories::ProjectDirs`.

The `create-admin` command prompts for credentials without echoing the password, starts
the embedded PostgreSQL instance when needed, applies pending migrations, and creates a
new administrator. The same form is available in the launcher's `Administrators` page.

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
- `OUTLET_BACKGROUND_CONTROL_CAPACITY` or `--background-control-capacity`
- `OUTLET_POLL_MAX_WAIT_SECONDS` or `--poll-max-wait`
- `OUTLET_COMPLETE_MAX_RETRIES` or `--complete-max-retries`
- `OUTLET_COMPLETE_MAX_SECONDS` or `--complete-max-seconds`
- `OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS` or `--background-terminal-ttl-seconds` (must be greater than zero)
- `SHELL_OUTLET_MAX_STREAM_CHARS`
- `SHELL_OUTLET_MAX_SUMMARY_CHARS`
- `SHELL_OUTLET_WINDOWS_FORCE_UTF8`

## Background Tool Calls

The outlet protocol accepts `background_start`, `background_status`, and
`background_cancel` poll operations in addition to the default `execute` operation.
The server supplies a stable `background_task_id`; starting the same id again is
idempotent only when the function and arguments are unchanged.

Background execution is kept in memory by `outlet-core`. Foreground calls and running
background jobs share the configured provider concurrency limit, while status and
cancel control calls do not consume a provider slot. The runner reports a separate
`control_capacity` poll lane so those operations remain deliverable while provider
execution is saturated. Completed, failed, and canceled entries remain queryable for
24 hours by default. The TTL is configurable with
`OUTLET_BACKGROUND_TERMINAL_TTL_SECONDS` or
`--background-terminal-ttl-seconds`. Runner process restarts intentionally do not
recover in-memory background jobs. After a terminal result expires, the runner keeps
the request digest for the rest of the runner session: replaying that UUID cannot run
the side effect again and returns the stable `outlet_task_expired` error.

`outlet-shell` advertises background support for `run_command`. Its stdout and stderr
are exposed as cursor-based progress entries, and cancellation terminates the command
process tree. The in-memory progress log is capped at 400,000 characters and reports a
truncation marker and total observed character count when the cap is reached.

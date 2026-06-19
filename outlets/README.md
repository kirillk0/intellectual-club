# Outlets

This directory contains standalone outlet runners that connect to the server over HTTP long polling.

The primary v1 implementation is the Rust workspace in [`rust/`](./rust):

- `outlet-core` — shared HTTP transport, pairing, file helpers, runner loop, and provider interfaces
- `outlet-shell` — reusable shell outlet tools
- `outlet-shell-daemon` — headless binary for containers and server environments
- `outlet-shell-desktop` — desktop GUI for managing multiple shell outlet profiles

The existing Python runner remains in this directory as a legacy/fallback implementation while Rust becomes the documented default.

## Wire protocol

Rust outlets use the existing server endpoints:

- `POST /api/outlet/poll/`
- `POST /api/outlet/complete/`
- `POST /api/outlet/calls/:call_id/files`
- `GET /api/outlet/calls/:call_id/files/:file_id`
- `POST /api/outlet/pair/start/`
- `POST /api/outlet/pair/poll/`

Tool discovery is still performed through the special `outlet.list_tools` call.

## Shell daemon

The daemon mode is intended for containers and other administrator-managed environments. It does not read or write config files and does not run pairing.

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

Legacy Python runner variables such as `OUTLET_CONFIG_DIR`, `OUTLET_TOKEN_FILE`, and `OUTLET_NO_PAIRING` are intentionally ignored by the Rust daemon.

Run locally:

```bash
cargo run --manifest-path outlets/rust/Cargo.toml -p outlet-shell-daemon -- \
  --server-url http://localhost:4000 \
  --token '<token>'
```

Build a release binary:

```bash
cargo build --manifest-path outlets/rust/Cargo.toml --release -p outlet-shell-daemon
```

## Desktop GUI

The desktop app is intended for users who want an agent to control their own computer. It supports multiple Club instances from one window.

Features:

- add a connection through the outlet pairing flow
- start and stop each profile
- re-pair an existing profile
- delete profiles
- auto-start selected profiles when the GUI launches

Run locally:

```bash
cargo run --manifest-path outlets/rust/Cargo.toml -p outlet-shell-desktop
```

Desktop profiles are stored as a local JSON file in the OS application config directory via the `directories` crate. The format is v1:

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "uuid",
      "name": "Shell Outlet",
      "server_url": "http://localhost:4000",
      "token": "runner-token",
      "runner_id": "runner-id",
      "auto_start": true,
      "created_at": "2026-06-19T00:00:00Z",
      "updated_at": "2026-06-19T00:00:00Z"
    }
  ]
}
```

On Unix-like systems the config file is chmodded to `0600`.

## Docker shell outlet

The canonical shell Docker image uses `outlet-shell-daemon` as the entrypoint command while keeping the existing toolbox environment for agent work.

Build and run:

```bash
docker build -t outlet-shell -f outlets/shell/Dockerfile .
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_TOKEN="<token>" \
  outlet-shell
```

The image still contains common CLI tools and the Python data/science utility packages from `outlets/shell/requirements.additional.txt`. The host folder `./share` can be mounted into the container at `/mnt/share` if you want a shared workspace.

## Available shell tools

- `run_command`
- `read_image`
- `download_file`
- `upload_file`

## Legacy Python runner

For fallback testing, the Python runner can still be started directly:

```bash
python -m pip install -r outlets/shell/requirements.txt
python -m outlets.shell.shell_outlet
```

The Python runner still supports persisted token files and pairing from the terminal. New daemon deployments should use the Rust daemon instead.

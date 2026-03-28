# Outlets

This directory contains standalone outlet runners that connect to the server over HTTP long polling.

## Common environment variables

- `OUTLET_SERVER_URL` (required): server base URL, for example `http://localhost:4000`
- `OUTLET_TOKEN` (optional): outlet token; if omitted, the runner starts the pairing flow
- `OUTLET_CONFIG_DIR` (optional): directory for persisted runner config
- `OUTLET_TOKEN_FILE` (optional): explicit token file path
- `OUTLET_RUNNER_ID` (optional): fixed runner id
- `OUTLET_LOG_LEVEL` (optional): logging level, `INFO` by default
- `OUTLET_MAX_CONCURRENCY` (optional): max parallel calls, default `20`
- `OUTLET_POLL_MAX_WAIT_SECONDS` (optional): long-poll max wait, default `25`
- `OUTLET_POLL_CHECK_INTERVAL_SECONDS` (optional): server-side poll interval, default `1`
- `SHELL_OUTLET_WINDOWS_FORCE_UTF8` (optional): for the shell outlet on Windows, force UTF-8 PowerShell I/O bootstrap by default; set to `0`/`false` to disable

## How configuration is resolved

At startup, an outlet runner resolves settings in this order:

1. CLI flags such as `--server-url`, `--token`, `--token-file`, and `--config-dir`
2. Matching environment variables such as `OUTLET_SERVER_URL`, `OUTLET_TOKEN`, `OUTLET_TOKEN_FILE`, and `OUTLET_CONFIG_DIR`
3. Persisted token JSON file, if a token was not provided explicitly
4. Browser pairing flow, if a token is still missing and pairing is enabled

Important details:

- `server_url` is never loaded from the persisted JSON file. It only comes from `--server-url` or `OUTLET_SERVER_URL`.
- `token` is loaded from `--token` or `OUTLET_TOKEN` first. The persisted JSON file is only used when no explicit token was provided.
- Pairing is enabled by default. Disable it with `--no-pairing` or `OUTLET_NO_PAIRING=true`.

## Where the persisted config file lives

The runner only writes a config file when it completes pairing and needs to persist the received token.

The token file path is resolved like this:

1. If `--token-file` or `OUTLET_TOKEN_FILE` is set, that exact file path is used.
2. Otherwise, if `--config-dir` or `OUTLET_CONFIG_DIR` is set, the file is stored as `<config-dir>/<runner-name>.json`.
3. Otherwise, the default location is `~/.config/intellectual-club/outlets/<runner-name>.json`.

For the shell outlet, the runner name is `shell-outlet`, so the default file path is:

```text
~/.config/intellectual-club/outlets/shell-outlet.json
```

If `OUTLET_CONFIG_DIR=/data`, the shell outlet persists the token here instead:

```text
/data/shell-outlet.json
```

If `OUTLET_TOKEN_FILE=/run/secrets/outlet-token.json`, the runner uses exactly that file and does not derive any other path.

The persisted JSON currently contains:

- `server_url`
- `token`
- `tool_instance_id`
- `saved_at`

The saved token is only reused when the `server_url` in the file matches the current `--server-url` / `OUTLET_SERVER_URL`.

## Typical startup scenarios

### Explicit token, no file writes

If you start the runner with `OUTLET_TOKEN=...` or `--token ...`, the runner uses that token directly. No pairing happens, and no config file is created automatically.

### Stored token reuse

If no explicit token is provided, the runner checks the resolved token file path. If the file exists and its `server_url` matches the current server URL, that token is reused.

### First run with pairing

If no explicit token is provided and no reusable stored token exists, the runner starts the browser pairing flow. After approval, it saves the received token into the resolved token file path shown above.

## Shell outlet

Build and run:

```bash
docker build -t outlet-shell -f outlets/shell/Dockerfile .
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_TOKEN="<token>" \
  outlet-shell
```

If you want the container to persist a paired token between restarts, mount a writable directory and point `OUTLET_CONFIG_DIR` at it:

```bash
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_CONFIG_DIR="/data" \
  -v outlet-shell-data:/data \
  outlet-shell
```

This stores the paired token at `/data/shell-outlet.json` inside the container, backed by the `outlet-shell-data` volume.

The repository includes [`outlets/shell/.env.template`](./shell/.env.template) as an example of the same settings. It does not currently include a Compose file; use the template with your own Compose setup if needed.

For a non-Docker install, create a Python environment and install the runtime requirements:

```bash
python -m pip install -r outlets/shell/requirements.txt
```

You can then start the outlet either as a module or as a script:

```bash
python -m outlets.shell.shell_outlet
python outlets/shell/shell_outlet.py
```

If you also want the extra preinstalled data/science/utility packages that are baked into the Docker image for agent work, install:

```bash
python -m pip install -r outlets/shell/requirements.additional.txt
```

If `OUTLET_TOKEN` is empty, the container prints a verification URL and a short code. Open the URL in the browser while logged in and approve the request.

The host folder `./share` is mounted into the container at `/mnt/share`.

Available tools:

- `run_command`
- `read_image`
- `download_file`
- `upload_file`

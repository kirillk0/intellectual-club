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

## Shell outlet

Build and run:

```bash
docker build -t outlet-shell -f outlets/shell/Dockerfile .
docker run --rm \
  -e OUTLET_SERVER_URL="http://localhost:4000" \
  -e OUTLET_TOKEN="<token>" \
  outlet-shell
```

Or with Docker Compose:

```bash
cd outlets/shell
cp .env.template .env
docker compose up --build
```

If `OUTLET_TOKEN` is empty, the container prints a verification URL and a short code. Open the URL in the browser while logged in and approve the request.

The host folder `./share` is mounted into the container at `/mnt/share`.

Available tools:

- `run_command`
- `read_image`
- `download_file`
- `upload_file`

# CI/CD application logs

## Storage and retention

The CI/CD host (`/opt/intellectual-club`) sends the app container's stdout/stderr
through Docker's `syslog` driver to a **dedicated systemd journal namespace**,
`intellectual-club`. The stable syslog tag is `intellectual-club-app`. Unlike Docker's
`json-file` logs, this journal is not deleted when a deployment removes a container.
It also survives host reboots: files live under
`/var/log/journal/<machine-id>.intellectual-club/`.

`ops/logging/journald.conf` configures:

- persistent, compressed storage with a ten-day retention window;
- hourly journal file rotation (age-based deletion is file-based, not per record,
  and happens during journal activity/rotation, not at an exact ten-day cutoff);
- a 1 GiB journal budget and 2 GiB free-space reserve;
- 1 MiB journal files and up to 1024 files, allowing ten days of hourly rotation;
- no journald rate limiting for application bursts.

The disk limits take precedence: unusually high log volume or low free space can
shorten retention. Journald removes archived files, so these are not hard disk
quotas. Other containers and the host's default journal are not affected.
Docker also keeps a bounded local cache (three 10 MiB files) for `docker logs`.
That cache is container-specific; use `journalctl` for history across deployments.
Syslog does not preserve Docker's stdout/stderr stream metadata (stdout maps to
info priority, stderr to error). Docker's RFC 3164 messages include a hostname,
so journald keeps the tag in the message text rather than `SYSLOG_IDENTIFIER`.
Filter this dedicated namespace with `_TRANSPORT=syslog`, **not** `-t`.

## Installation

Requires a rootful Docker host with systemd journal namespace support (tested on
Debian 12 / systemd 252). No additional logging daemon is needed.

1. Copy `ops/logging/` to the host and run `sudo bash ops/logging/install.sh`.
   This starts/restarts **only the application journal namespace** and installs a
   Docker unit dependency so the logging socket is available after a host reboot.
   It neither restarts Docker nor changes its global logging driver.
2. Merge the `app.logging` block from `ops/logging/compose.logging.yaml` into
   `/opt/intellectual-club/compose.yaml`. The existing CI/CD deploy script uses
   this host-managed file; no workflow or image changes are required.
   Alternatively, supply the file with `-f` on **every** Compose deployment.
   Do not change the default development Compose file: macOS Docker Desktop
   does not expose the host's systemd journal socket.
3. Validate with `docker compose -p intellectual-club-v2 -f
   /opt/intellectual-club/compose.yaml config --quiet`.
4. Under the existing `/opt/intellectual-club/deploy.lock`, save the old
   container's logs before deleting it, then recreate only `app`:

   ```sh
   cd /opt/intellectual-club
   docker compose -p intellectual-club-v2 -f compose.yaml \
     up -d --no-deps --force-recreate --pull never app
   ```

   Changing the logging driver requires recreation, not `docker restart`.
   Preserve the running image when applying this independently of a release.
   Do not run migrations or recreate the database/outlets for a logging change.

The initial migration imports the previous container's available Docker logs
into the namespace with the same tag. Imported messages retain their original
Docker timestamp in the message text; their journal ingestion time is the
migration time. Logs from containers already deleted before this setup cannot
be recovered.

## Reading and checking logs

Run on the CI/CD host (root or a user with journal read access):

```sh
# All app containers/deployments in the last ten days.
journalctl --namespace=intellectual-club _TRANSPORT=syslog \
  --since '10 days ago' -o short-iso-precise --no-pager

# Follow the app even while deployments replace its container.
journalctl --namespace=intellectual-club _TRANSPORT=syslog -f

# Current container only (Docker's local cache).
docker logs --tail 100 -f intellectual-club-v2-app-1

# Storage, integrity, and effective retention configuration.
journalctl --namespace=intellectual-club --disk-usage
journalctl --namespace=intellectual-club --verify
systemd-analyze cat-config systemd/journald@intellectual-club.conf
systemctl status systemd-journald@intellectual-club.service
```

To export plain text, redirect the first command to a file. To explicitly rotate
and expire archived files now (normally automatic):

```sh
journalctl --namespace=intellectual-club --rotate --vacuum-time=10d
```

## Rollback

Restore the previous `app.logging` configuration (or remove the block to use the
host's default driver), then recreate only `app` under the deployment lock.
Keep the namespace and journal files to retain access to previously collected
logs. Do not delete them or vacuum them as part of rollback. The logging setup
does not require restarting the desktop outlet or the Docker daemon.

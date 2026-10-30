#!/usr/bin/env bash
set -euo pipefail

# Install only host logging infrastructure; do not restart Docker or the app.
if [ "$(id -u)" -ne 0 ]; then
  echo "Run this installer as root on the Docker host." >&2
  exit 1
fi

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL_UNIT=systemd-journald@intellectual-club.service
CONFIG_DIR=/etc/systemd/journald@intellectual-club.conf.d
DOCKER_DROP_IN=/etc/systemd/system/docker.service.d

# Fail before changing files on hosts without journal namespace support.
systemctl cat systemd-journald@.service >/dev/null
systemctl cat docker.service >/dev/null
install -d -m 0755 "$CONFIG_DIR" "$DOCKER_DROP_IN"
install -m 0644 "$SOURCE_DIR/journald.conf" "$CONFIG_DIR/retention.conf"
install -m 0644 "$SOURCE_DIR/docker-service.conf" "$DOCKER_DROP_IN/intellectual-club-logging.conf"
systemctl daemon-reload
# Restart only this namespace; its systemd-owned sockets remain available.
systemctl restart "$JOURNAL_UNIT"
test -S /run/systemd/journal.intellectual-club/dev-log
systemctl is-active --quiet "$JOURNAL_UNIT"
echo "Application journal ready. Apply compose.logging.yaml to app separately."

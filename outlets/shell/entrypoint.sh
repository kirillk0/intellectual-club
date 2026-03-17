#!/usr/bin/env bash
set -euo pipefail

OUTLET_USER="${OUTLET_USER:-agent}"

# Ensure the shared folder exists and is writable, even when it is a bind mount.
mkdir -p /mnt/share || true
chmod 0777 /mnt/share || true

# Ensure the config folder exists and is writable (token file storage).
mkdir -p /data || true
if chown "${OUTLET_USER}:${OUTLET_USER}" /data 2>/dev/null; then
  chmod 0700 /data || true
else
  chmod 0777 /data || true
fi

exec runuser -u "${OUTLET_USER}" -- "$@"

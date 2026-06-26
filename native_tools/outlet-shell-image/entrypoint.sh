#!/usr/bin/env bash
set -euo pipefail

OUTLET_USER="${OUTLET_USER:-agent}"

# Ensure the shared folder exists and is writable, even when it is a bind mount.
mkdir -p /mnt/share || true
chmod 0777 /mnt/share || true

exec runuser -u "${OUTLET_USER}" -- "$@"

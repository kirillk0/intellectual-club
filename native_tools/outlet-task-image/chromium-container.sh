# Sourced by Debian's /usr/bin/chromium wrapper (installed as /etc/chromium.d/90-container).
# Task containers run commands as root, without a GPU, with Docker's default 64 MB
# /dev/shm and usually without a display.
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --no-sandbox --disable-dev-shm-usage --disable-gpu"
if [ -z "${DISPLAY:-}" ]; then
  # Headful use stays possible under xvfb-run, which sets DISPLAY.
  export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --headless=new"
fi

# syntax=docker/dockerfile:1
# Default workspace image for outlet-task-container: one container per chat family.
# Build context is this directory; see README.md.
ARG PYTHON_IMAGE=python:3.12-bookworm
ARG NODE_IMAGE=node:24.16.0-bookworm-slim

FROM ${NODE_IMAGE} AS node

FROM ${PYTHON_IMAGE}

LABEL org.intellectual-club.keep="true" \
      org.opencontainers.image.title="Intellectual Club task workspace" \
      org.opencontainers.image.description="Default outlet-task-container image: Python 3.12, Node 24 and PDF, Office, OCR, browser and media tools for agent work" \
      org.opencontainers.image.source="https://github.com/kirillk0/intellectual-club"

# Commands run as root through `/bin/sh -c`, not a login shell: configure via ENV only.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_PATH=/usr/local/lib/node_modules

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Agents write bash. dash already diverts /bin/sh (dpkg-reconfigure no longer switches
# it on bookworm), so point the managed symlink at bash directly.
RUN ln -sfn bash /usr/bin/sh && test "$(readlink -f /bin/sh)" = /usr/bin/bash

COPY apt-packages.txt /usr/local/lib/outlet-task-image/
RUN apt-get update \
    && sed -e 's/#.*//' /usr/local/lib/outlet-task-image/apt-packages.txt \
       | xargs apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

COPY requirements.txt /usr/local/lib/outlet-task-image/
RUN python3 -m pip install --upgrade pip setuptools wheel \
    && python3 -m pip install -r /usr/local/lib/outlet-task-image/requirements.txt

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY npm-global.txt /usr/local/lib/outlet-task-image/
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && if [ -e /usr/local/lib/node_modules/corepack/dist/corepack.js ]; then \
         ln -sf ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack; \
       fi \
    && sed -e 's/#.*//' /usr/local/lib/outlet-task-image/npm-global.txt \
       | xargs npm install --global --no-fund --no-audit \
    && npm cache clean --force

# Playwright's own headless Chromium shell; its system libraries come from the apt layer.
RUN if python3 -m playwright install --help | grep -q -- '--only-shell'; then \
         python3 -m playwright install --only-shell chromium; \
       else \
         python3 -m playwright install chromium-headless-shell; \
       fi \
    && rm -rf /root/.cache/ms-playwright* /tmp/*

COPY apt-tools.txt /usr/local/lib/outlet-task-image/
RUN apt-get update \
    && sed -e 's/#.*//' /usr/local/lib/outlet-task-image/apt-tools.txt \
       | xargs apt-get install -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb

COPY chromium-container.sh /etc/chromium.d/90-container
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && git config --system safe.directory '*' \
    && git config --system init.defaultBranch main \
    && git lfs install --system --skip-repo \
    && mkdir -p /workspace /usr/local/share/outlet-task-image

COPY manifest.sh smoke-test.sh /usr/local/lib/outlet-task-image/
RUN chmod 0755 /usr/local/lib/outlet-task-image/manifest.sh /usr/local/lib/outlet-task-image/smoke-test.sh \
    && /usr/local/lib/outlet-task-image/manifest.sh > /usr/local/share/outlet-task-image/manifest.txt \
    && /usr/local/lib/outlet-task-image/smoke-test.sh

WORKDIR /workspace
# The runner replaces the entrypoint/command with its own idle process.
CMD ["sleep", "infinity"]

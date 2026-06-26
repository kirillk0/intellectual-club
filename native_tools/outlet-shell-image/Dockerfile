FROM rust:1-bookworm AS rust-builder

WORKDIR /src
COPY native_tools /src/native_tools
ENV CARGO_NET_RETRY=10
ENV CARGO_HTTP_TIMEOUT=600
ENV CARGO_HTTP_LOW_SPEED_LIMIT=1
RUN cargo build --manifest-path /src/native_tools/Cargo.toml --release -p outlet-shell-daemon --locked

FROM python:3.12-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    dnsutils \
    fd-find \
    file \
    git \
    iproute2 \
    iputils-ping \
    jq \
    less \
    lsof \
    nano \
    netcat-openbsd \
    openssh-client \
    procps \
    ripgrep \
    rsync \
    sudo \
    tree \
    unzip \
    vim \
    wget \
    zip \
    build-essential \
    pandoc \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

ARG OUTLET_USER=agent
ARG OUTLET_UID=1000
ARG OUTLET_GID=1000

ENV OUTLET_USER="${OUTLET_USER}"
ENV HOME="/home/${OUTLET_USER}"

COPY native_tools/outlet-shell-image/requirements.txt /tmp/shell-requirements.txt
COPY native_tools/outlet-shell-image/requirements.additional.txt /tmp/shell-requirements-additional.txt

RUN groupadd --gid "${OUTLET_GID}" "${OUTLET_USER}" \
    && useradd --uid "${OUTLET_UID}" --gid "${OUTLET_GID}" --create-home --shell /bin/bash "${OUTLET_USER}" \
    && echo "${OUTLET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${OUTLET_USER}" \
    && chmod 0440 "/etc/sudoers.d/${OUTLET_USER}" \
    && mkdir -p /mnt/share \
    && chmod 0777 /mnt/share

RUN python -m venv "/home/${OUTLET_USER}/.venv" \
    && "/home/${OUTLET_USER}/.venv/bin/python" -m pip install --upgrade pip setuptools wheel \
    && "/home/${OUTLET_USER}/.venv/bin/pip" install -r /tmp/shell-requirements.txt \
    && "/home/${OUTLET_USER}/.venv/bin/pip" install -r /tmp/shell-requirements-additional.txt \
    && chown -R "${OUTLET_UID}:${OUTLET_GID}" "/home/${OUTLET_USER}/.venv"

ENV PATH="/home/${OUTLET_USER}/.venv/bin:${PATH}"
ENV VIRTUAL_ENV="/home/${OUTLET_USER}/.venv"

RUN printf '%s\n' \
    "export VIRTUAL_ENV=\"${VIRTUAL_ENV}\"" \
    'export PATH="$VIRTUAL_ENV/bin:$PATH"' \
    > /etc/profile.d/outlet-venv.sh

ENV PYTHONUNBUFFERED=1

COPY --from=rust-builder /src/native_tools/target/release/outlet-shell-daemon /usr/local/bin/outlet-shell-daemon

COPY native_tools/outlet-shell-image/entrypoint.sh /usr/local/bin/outlet-entrypoint
RUN chmod 0755 /usr/local/bin/outlet-entrypoint

WORKDIR /app

ENTRYPOINT ["/usr/local/bin/outlet-entrypoint"]
CMD ["outlet-shell-daemon"]

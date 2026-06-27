ARG NODE_VERSION=24.16.0

FROM node:${NODE_VERSION}-slim AS node

FROM elixir:1.20-slim AS build

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ca-certificates \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/server

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY server/mix.exs server/mix.lock ./
COPY server/config ./config
COPY frontend/package.json frontend/package-lock.json ../frontend/

RUN mix deps.get --only prod
RUN mix deps.compile
RUN npm --prefix ../frontend ci

COPY server/priv ./priv
COPY server/lib ./lib
COPY server/assets ./assets
COPY frontend ../frontend

RUN mix compile
RUN mix assets.deploy
RUN mix release

FROM debian:trixie-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    libssl3 \
    libncurses6 \
    libsqlite3-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN useradd --create-home --shell /bin/bash app

COPY --from=build /app/server/_build/prod/rel/intellectual_club /app

RUN mkdir -p /app/data/files && chown -R app:app /app
USER app

ENV PHX_SERVER=true
ENV DATA_DIR=/app/data
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

EXPOSE 4000
CMD ["bin/intellectual_club", "start"]

# syntax=docker/dockerfile:1
ARG NODE_VERSION=24.16.0
ARG STATIC_ASSETS=local

FROM scratch AS web-static

FROM node:${NODE_VERSION}-slim AS node

FROM node AS frontend-dependencies
WORKDIR /app/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci

FROM elixir:1.20-slim AS build

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/server

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY server/mix.exs server/mix.lock ./
COPY server/config ./config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY server/priv ./priv
COPY server/lib ./lib
COPY server/assets ./assets

RUN mix compile

FROM build AS assets-local
COPY --from=frontend-dependencies /app/frontend ../frontend
COPY frontend ../frontend
RUN mix assets.deploy

FROM build AS assets-prebuilt
COPY bin/static-assets.mjs ../bin/static-assets.mjs
COPY --from=web-static / /app/prebuilt-static/
ARG BUILD_COMMIT_SHA
RUN node ../bin/static-assets.mjs install /app/prebuilt-static "${BUILD_COMMIT_SHA}"

FROM assets-${STATIC_ASSETS} AS release
COPY server/rel ./rel
RUN mix release

FROM debian:trixie-slim AS app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    libssl3 \
    libncurses6 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN useradd --create-home --shell /bin/bash app

COPY --from=release /app/server/_build/prod/rel/intellectual_club /app

RUN mkdir -p /app/data/files && chown -R app:app /app
USER app

ENV PHX_SERVER=true
ENV DATA_DIR=/app/data
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

EXPOSE 4000
CMD ["bin/intellectual_club", "start"]

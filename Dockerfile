# Production image: a Mix release on Debian. Build with `docker compose build`.
# Toolchain matches development (Elixir 1.20.4 / OTP 29.1.2); bump both tags together.
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1.2-debian-trixie-20261027-slim
ARG RUNNER_IMAGE=debian:trixie-20261027-slim

FROM ${ELIXIR_IMAGE} AS build
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile
RUN mix assets.setup && mix assets.deploy

COPY config/runtime.exs config/
RUN mix release

FROM ${RUNNER_IMAGE}
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8
WORKDIR /app
RUN useradd --create-home --uid 1000 archive \
  && install -d -o archive -g archive /data /data/raw /data/models /data/tokens
COPY --from=build --chown=archive:archive /app/_build/prod/rel/context_archive ./
USER archive

# The commit the image was built from, reported by /health; the build context has no .git.
ARG CONTEXT_ARCHIVE_REVISION=""
ENV CONTEXT_ARCHIVE_REVISION=${CONTEXT_ARCHIVE_REVISION}

# Raw archive and the embedding model cache live on the /data volume.
ENV PHX_SERVER=true \
    CONTEXT_ARCHIVE_RAW_ROOT=/data/raw \
    BUMBLEBEE_CACHE_DIR=/data/models
EXPOSE 4000
CMD ["/bin/sh", "-c", "bin/context_archive eval 'ContextArchive.Release.migrate()' && exec bin/context_archive start"]

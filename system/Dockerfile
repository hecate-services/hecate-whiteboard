# hecate-whiteboard -- real-time multi-user whiteboard over mesh: a host
# runs this on their own node, collaborators dial in over macula, no
# central server. See plans/PLAN_HECATE_WHITEBOARD_ROOT.md.
#
# THE RUNTIME IS PINNED IN TWO PLACES AND THEY MUST AGREE: both stages
# below. Confirmed directly against Docker Hub at write time (2026-08-25)
# -- hexpm/elixir no longer publishes bookworm tags for this Elixir/OTP
# combination, current is trixie; matched the plain debian runtime image
# to the same trixie date so build- and runtime-stage glibc agree (the
# NIFs below are compiled against the build stage's libc).
FROM hexpm/elixir:1.18.4-erlang-28.1-debian-trixie-20260610-slim AS build

RUN apt-get update -y && \
    apt-get install -y build-essential git curl cmake && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# macula compiles DID/MRI/CBOR NIFs from Rust source during deps.compile.
# Without a toolchain here the build either fails outright or silently
# skips the NIF and the release crash-loops at runtime on_load -- same
# reasoning as macula-realm's own Dockerfile, confirmed locally: this
# repo's own `mix compile` genuinely triggers a from-source Rust build
# for macula_did_nif/macula_mri_nif/macula_cbor_nif every time.
ENV PATH="/root/.cargo/bin:${PATH}"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal && \
    rustc --version

ENV MIX_ENV=prod

# No mix.lock, deliberately -- this workspace never commits lock files
# (the manifest is the single source of truth, a tracked lock becomes a
# silent version ceiling deps.get never advances past on its own). Every
# build resolves fresh against the live registry. Dependencies resolve
# from mix.exs alone, so this layer survives every change to config/ and
# apps/*/lib.
COPY mix.exs ./
COPY apps/hecate_whiteboard/mix.exs ./apps/hecate_whiteboard/
COPY apps/guide_board_lifecycle/mix.exs ./apps/guide_board_lifecycle/
COPY apps/project_boards/mix.exs ./apps/project_boards/
COPY apps/query_boards/mix.exs ./apps/query_boards/
COPY apps/track_presence/mix.exs ./apps/track_presence/
COPY apps/hecate_whiteboard_web/mix.exs ./apps/hecate_whiteboard_web/
RUN mix deps.get --only prod
RUN mix deps.compile

# Cache-busts /assets/app.js and app.css across a redeploy -- see
# HecateWhiteboardWeb.BuildInfo's own header for why this exists.
# Declared here, not earlier, so a commit that only touches lib/ (i.e.
# every commit) doesn't also bust the deps.get/deps.compile layers
# above, which already only rebuild when mix.exs actually changes.
ARG GIT_SHA=dev
ENV GIT_SHA=${GIT_SHA}

COPY config ./config
COPY apps ./apps
RUN mix compile

# Bundles app.js (phoenix + phoenix_live_view resolved via NODE_PATH
# against deps/, see config/config.exs) and app.css into
# apps/hecate_whiteboard_web/priv/static/assets/, which the release then
# ships as static files -- source isn't committed (see that app's
# .gitignore), same reasoning as not committing mix.lock.
RUN mix esbuild.install --if-missing
RUN mix esbuild hecate_whiteboard_web
RUN mix esbuild hecate_whiteboard_web_css

# mix release assembles [:erts, :app, ...] via parallel Tasks, and the
# [:erts] copy (cp_r + rewrite bin/erl + chmod) races on the build
# filesystem -- reproduced locally: "could not change mode for
# .../bin/erl: no such file or directory" on the very first attempt,
# gone after forcing a single scheduler. Same fix macula-realm's
# Dockerfile already carries for the identical race.
RUN ELIXIR_ERL_OPTIONS="+S 1" mix release

FROM debian:trixie-20260610-slim AS runtime
# LINKS THE PACKAGE TO THE REPOSITORY. On ghcr, a package without this
# label is an orphan: it does not appear on the repository page and does
# not inherit its visibility -- see hecate-tube's Containerfile for the
# failure mode this avoids (a private-by-accident package that 401s on
# first pull).
LABEL org.opencontainers.image.source="https://github.com/hecate-services/hecate-whiteboard"

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl ca-certificates curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Root, deliberately, matching hecate-tube's own Containerfile -- this
# volume is a straight bind mount to /bulk0/<service> on the beam host
# (see infrastructure/scripts/docker-compose.hecate-whiteboard.yml in
# macula-demo), and a non-root user here would need its UID to line up
# with whatever owns that host directory. Tested locally: a non-root
# `app` user hit exactly that -- {error, enoent} from filelib:ensure_path
# on an unwritable bind-mounted /data. Not worth the friction for a
# service with no untrusted input to sandbox against.
COPY --from=build /app/_build/prod/rel/hecate_whiteboard ./
ENV HECATE_HEALTH_PORT=8490
ENV HECATE_HTTP_PORT=4000

EXPOSE 8490 4000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${HECATE_HEALTH_PORT}/health" || exit 1

CMD ["bin/hecate_whiteboard", "start"]

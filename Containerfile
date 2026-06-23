# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Joshua Jewell (JoshuaJewell) <paint-type@pm.me>
#
# Containerfile for paint-type
# Build: podman build -t {{project}}:latest -f Containerfile .
# Run:   podman run --rm -it {{project}}:latest
# Seal:  selur seal {{project}}:latest
#
# NOTE: This is the PRODUCTION build container (multi-stage).
#       For development environment, see .devcontainer/Containerfile.
#       Both use the same base image version for consistency.

# --- Build stage ---
# Pinned by digest (Chainguard rolls :latest frequently — refresh deliberately):
#   docker pull cgr.dev/chainguard/wolfi-base:latest && \
#     docker inspect --format='{{index .RepoDigests 0}}' cgr.dev/chainguard/wolfi-base:latest
# NOTE: the build steps below are still template TODOs — complete them before use.
FROM cgr.dev/chainguard/wolfi-base:latest@sha256:34977aa13765da89f60fee8fe5230e2bb1c55192df08e383c58221ee0d1277fb AS build

# TODO: Install build dependencies for your stack
# Examples:
#   RUN apk add --no-cache rust cargo       # Rust
#   RUN apk add --no-cache elixir erlang    # Elixir
#   RUN apk add --no-cache zig              # Zig

WORKDIR /build
COPY . .

# TODO: Replace with your build command
# Examples:
#   RUN cargo build --release
#   RUN mix deps.get && MIX_ENV=prod mix release
#   RUN zig build -Doptimize=ReleaseSafe

# --- Runtime stage ---
# Pinned by digest; refresh as above with cgr.dev/chainguard/static:latest.
FROM cgr.dev/chainguard/static:latest@sha256:77d8b8925dc27970ec2f48243f44c7a260d52c49cd778288e4ee97566e0cb75b

# Copy built artifact from build stage
# TODO: Replace with your binary/artifact path
# Examples:
#   COPY --from=build /build/target/release/{{project}} /usr/local/bin/
#   COPY --from=build /build/_build/prod/rel/{{project}} /app/
#   COPY --from=build /build/zig-out/bin/{{project}} /usr/local/bin/

# Non-root user (chainguard images default to nonroot)
USER nonroot

# TODO: Replace with your entrypoint
# ENTRYPOINT ["/usr/local/bin/{{project}}"]

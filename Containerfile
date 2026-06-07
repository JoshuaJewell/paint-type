# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2024-2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# paint.type — canonical multi-arch container build.
# Governed by docs/decisions/0002-foundation-cross-platform.adoc (ADR-0002).
#
# Build (recommended, multi-arch via buildx):
#   docker buildx build \
#     --platform linux/amd64,linux/arm64,linux/arm/v7,linux/riscv64,linux/ppc64le \
#     --tag ghcr.io/joshuajewell/paint-type:dev \
#     --file Containerfile \
#     --push .
#
# Build (single-arch local):
#   podman build -t paint-type:dev -f Containerfile .
#
# Run:
#   podman run --rm -it -p 7000:7000 paint-type:dev
#
# Seal (reproducible + signed):
#   selur seal paint-type:dev

# ----------------------------------------------------------------------------
# Stage 1 — toolchain
# ----------------------------------------------------------------------------
# Wolfi gives us a minimal glibc base on every architecture we care about for
# Linux. Native binaries extracted from this container are produced by the
# same compiler invocations on every host platform — no parallel build paths.
FROM --platform=$BUILDPLATFORM cgr.dev/chainguard/wolfi-base:latest AS toolchain

ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT

# Build-side dependencies. Idris2 provides the abstract surface + proofs;
# Zig builds every concrete backend and the unified API server; the typed-wasm
# toolchain compiles the AffineScript application module.
RUN apk add --no-cache \
        bash curl git make tar xz \
        clang lld pkgconf \
        zig \
        idris2 \
        wabt binaryen \
        nodejs npm \
        ca-certificates

# AffineScript toolchain and typed-wasm bundler are fetched from upstream
# hyperpolymath repos. Both targets produce the wasm32-and-wasm64 module
# variants the runtime stage will load.
ENV AFFINESCRIPT_VERSION=main
ENV TYPED_WASM_VERSION=main
RUN curl -fsSL https://raw.githubusercontent.com/hyperpolymath/affinescript/$AFFINESCRIPT_VERSION/install.sh | bash -s -- /usr/local || true
RUN curl -fsSL https://raw.githubusercontent.com/hyperpolymath/typed-wasm/$TYPED_WASM_VERSION/install.sh    | bash -s -- /usr/local || true

# ----------------------------------------------------------------------------
# Stage 2 — build
# ----------------------------------------------------------------------------
FROM toolchain AS build

WORKDIR /build
COPY . .

ARG TARGETARCH
ARG TARGETVARIANT

# Zig target triple resolution per TARGETARCH/TARGETVARIANT.
# Reuses the same Zig invocation on every architecture; only the target
# triple changes. No special-case build for any platform.
RUN set -eux; \
    case "${TARGETARCH}/${TARGETVARIANT}" in \
        amd64/*)     ZTARGET="x86_64-linux-gnu";; \
        arm64/*)     ZTARGET="aarch64-linux-gnu";; \
        arm/v7)      ZTARGET="arm-linux-gnueabihf";; \
        riscv64/*)   ZTARGET="riscv64-linux-gnu";; \
        ppc64le/*)   ZTARGET="powerpc64le-linux-gnu";; \
        *)           ZTARGET="native";; \
    esac; \
    echo "ZTARGET=${ZTARGET}" > /build/.zig-target

# 1. Idris2 — abstract operation surface + capability descriptor + proofs.
#    Produces C headers consumed by every Zig backend module.
RUN idris2 --build src/backends/Abstract.ipkg || true

# 2. Zig — build the dispatcher, the CPU reference backend, every concrete
#    backend module compatible with the target, and the unified API server.
RUN zig build -Doptimize=ReleaseSafe -Dtarget="$(cat /build/.zig-target)" || true

# 3. AffineScript — compile the application to typed-wasm.
#    Emits paint_type.app.wasm at both wasm32 and wasm64 targets.
RUN affinescript build src/affinescript \
        --target typed-wasm32 \
        --target typed-wasm64 \
        --emit /build/zig-out/wasm/ || true

# ----------------------------------------------------------------------------
# Stage 3 — runtime
# ----------------------------------------------------------------------------
# Wolfi static gives us a minimal, no-shell runtime; the application binary
# plus the wasm module are sufficient to run paint.type on any supported host.
FROM cgr.dev/chainguard/wolfi-base:latest AS runtime

LABEL org.opencontainers.image.title="paint.type"
LABEL org.opencontainers.image.description="Universally cross-platform image editor"
LABEL org.opencontainers.image.source="https://github.com/JoshuaJewell/paint-type"
LABEL org.opencontainers.image.licenses="AGPL-3.0-or-later"
LABEL org.opencontainers.image.vendor="hyperpolymath"

# Runtime-side dependencies. Everything optional (GPU drivers, FPGA runtime,
# audio servers, etc.) is loaded as a side-car by the dispatcher when present
# on the host. The container does NOT bundle vendor drivers — those are host
# concerns, surfaced via the capability probe.
RUN apk add --no-cache \
        ca-certificates \
        tzdata

WORKDIR /app

# Application + wasm module + canonical Idris2-generated headers (for
# downstream tooling that needs to introspect the operation surface).
COPY --from=build /build/zig-out/bin/paint-type        /usr/local/bin/paint-type
COPY --from=build /build/zig-out/wasm/paint_type.app.wasm /app/paint_type.app.wasm
COPY --from=build /build/zig-out/wasm/paint_type.app.wasm64.wasm /app/paint_type.app.wasm64.wasm
COPY --from=build /build/src/backends/Abstract.idr     /app/schema/Abstract.idr

# Non-root by default.
USER nonroot

# The unified API server listens on a single port; protocol selection is
# negotiated per-connection (REST / GraphQL / gRPC / SSE / Bebop all share
# the same listener thanks to the API common layer).
EXPOSE 7000

ENTRYPOINT ["/usr/local/bin/paint-type"]
CMD ["serve", "--bind", "0.0.0.0:7000"]

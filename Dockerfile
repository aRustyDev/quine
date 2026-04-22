# Stage 1: Build Roc app → libapp.a (static library)
FROM ubuntu:24.04 AS roc-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates binutils \
    && rm -rf /var/lib/apt/lists/*

# Install Roc nightly — architecture-aware.
# TARGETARCH is set by Docker BuildKit (amd64 or arm64).
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) ROC_ARCH="linux_x86_64" ;; \
      arm64) ROC_ARCH="linux_arm64" ;; \
      *) echo "unsupported arch: $TARGETARCH" && exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/roc-lang/roc/releases/download/nightly/roc_nightly-${ROC_ARCH}-latest.tar.gz" \
       | tar xz -C /tmp \
    && mv /tmp/roc_nightly-*/roc /usr/local/bin/roc \
    && rm -rf /tmp/roc_nightly-*

WORKDIR /build

# Copy Roc source: platform interface files, app, and packages
COPY platform/main.roc platform/Effect.roc platform/Host.roc platform/
COPY packages/ packages/
COPY app/graph-app.roc app/

# Build Roc app to an object file, then create a static library.
# roc build --no-link produces graph-app.o alongside the source file.
# Roc exits 2 on warnings (not errors), so we verify the .o was produced.
RUN roc build --no-link app/graph-app.roc; \
    test -f app/graph-app.o || { echo "Roc build failed: no .o produced"; exit 1; }; \
    ar rcs platform/libapp.a app/graph-app.o

# Stage 2: Build Rust platform binary (statically links libapp.a)
FROM rust:slim-bookworm AS rust-builder

WORKDIR /build/platform

# Copy Cargo manifests first for layer caching
COPY platform/Cargo.toml platform/Cargo.lock ./

# Copy the Roc-compiled static library from stage 1
COPY --from=roc-builder /build/platform/libapp.a ./

# Copy Rust source and build script
COPY platform/build.rs ./
COPY platform/src/ src/

RUN cargo build --release

# Stage 3: Minimal runtime
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=rust-builder /build/platform/target/release/quine-graph-platform /usr/local/bin/quine-roc

RUN mkdir -p /data
VOLUME /data

EXPOSE 8080

ENV QUINE_DATA_DIR=/data

ENTRYPOINT ["quine-roc"]
CMD ["--shards", "4", "--port", "8080"]

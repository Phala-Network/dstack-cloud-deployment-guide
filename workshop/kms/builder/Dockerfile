# dstack-kms + helios combined image
#
# Reproducible build: all source revisions and base images are pinned.
#
# Usage:
#   ./build-image.sh cr.kvin.wang/dstack-kms:latest
#
# To override source revisions:
#   DSTACK_REV=<commit> HELIOS_REV=<commit> ./build-image.sh cr.kvin.wang/dstack-kms:latest

# --- Stage 1: build dstack-kms (static musl binary) ---
FROM rust:1.92.0@sha256:48851a839d6a67370c9dbe0e709bedc138e3e404b161c5233aedcf2b717366e4 AS kms-builder
ARG DSTACK_REV
ARG DSTACK_SRC_URL=https://github.com/Phala-Network/dstack-cloud.git
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential musl-tools libssl-dev \
        protobuf-compiler libprotobuf-dev clang libclang-dev && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 50 ${DSTACK_SRC_URL} /build/dstack && \
    cd /build/dstack && \
    git fetch --depth 1 origin ${DSTACK_REV} && \
    git checkout ${DSTACK_REV}
RUN rustup target add x86_64-unknown-linux-musl
RUN cd /build/dstack && cargo build --release -p dstack-kms --target x86_64-unknown-linux-musl

# --- Stage 2: build helios (static musl binary) ---
FROM rust:1.92.0@sha256:48851a839d6a67370c9dbe0e709bedc138e3e404b161c5233aedcf2b717366e4 AS helios-builder
ARG HELIOS_REV
ARG HELIOS_SRC_URL=https://github.com/a16z/helios.git
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git build-essential musl-tools libssl-dev \
        clang libclang-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 50 ${HELIOS_SRC_URL} /build/helios && \
    cd /build/helios && \
    git fetch --depth 1 origin ${HELIOS_REV} && \
    git checkout ${HELIOS_REV}
RUN rustup target add x86_64-unknown-linux-musl
RUN cd /build/helios && cargo build --release --bin helios --target x86_64-unknown-linux-musl

# --- Final stage: minimal runtime image ---
FROM debian:bookworm-slim@sha256:0d8498a0e9e6a60011df39aab78534cfe940785e7c59d19dfae1eb53ea59babe
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl jq && \
    rm -rf /var/lib/apt/lists/*
COPY --from=kms-builder  /build/dstack/target/x86_64-unknown-linux-musl/release/dstack-kms /usr/local/bin/dstack-kms
COPY --from=helios-builder /build/helios/target/x86_64-unknown-linux-musl/release/helios /usr/local/bin/helios
CMD ["dstack-kms"]

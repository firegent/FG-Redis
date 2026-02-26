# --- Stage 1: Builder ---
# We use the full Ubuntu image here to have access to all build tools
FROM ubuntu:24.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG REDIS_VERSION=8.0.0

# Install ALL build dependencies
# We don't care about cleanup here because this layer will be discarded
RUN apt-get update && apt-get install -y \
  ca-certificates wget curl dpkg-dev gcc g++ libc6-dev libssl-dev make \
  git cmake python3 python3-pip python3-venv python3-dev unzip rsync \
  clang automake autoconf libtool

WORKDIR /usr/src

# Download and Extract
RUN wget -qO redis.tar.gz https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz && \
  tar -xzf redis.tar.gz && \
  mv redis-${REDIS_VERSION} redis

WORKDIR /usr/src/redis

# Build
# Redis 8 requires Rust. We let the makefile handle the rust toolchain installation
# via INSTALL_RUST_TOOLCHAIN=yes
RUN export BUILD_TLS=yes \
  BUILD_WITH_MODULES=yes \
  INSTALL_RUST_TOOLCHAIN=yes \
  DISABLE_WERRORS=yes && \
  make -j "$(nproc)" all

# Pre-modify the config file in the builder stage so it's ready to copy
RUN sed -i 's/^bind 127.0.0.1 -::1/bind 0.0.0.0/' redis.conf && \
  sed -i 's/^protected-mode yes/protected-mode no/' redis.conf

# --- Stage 2: Runtime ---
# We switch to a slim version of Ubuntu for the final image
FROM ubuntu:24.04-slim

# Create a non-root user for security
RUN groupadd -r redis && useradd -r -g redis redis

# Install ONLY runtime dependencies
# Redis needs libssl (for TLS) and standard libs.
# We remove the apt cache lists afterwards to keep the layer small.
RUN apt-get update && apt-get install -y --no-install-recommends \
  libssl3 \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Set up directories and permissions
WORKDIR /data
RUN mkdir -p /usr/local/etc/redis && chown redis:redis /usr/local/etc/redis

# COPY artifacts from the "builder" stage
# 1. The compiled binary
COPY --from=builder /usr/src/redis/src/redis-server /usr/local/bin/
# 2. The configuration file
COPY --from=builder /usr/src/redis/redis.conf /usr/local/etc/redis/redis.conf

# Switch to non-root user
USER redis

# Expose the standard Redis port
EXPOSE 6379

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]
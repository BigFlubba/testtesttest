# syntax=docker/dockerfile:1
# The workflow overrides UBUNTU_VERSION with the newest Ubuntu release it finds.
ARG UBUNTU_VERSION=26.04
# Pre-built HandBrake artifact image (built by docker/handbrake.Dockerfile in its own CI job)
ARG HANDBRAKE_IMAGE=scratch

# ---------- base: minimal runtime image ----------
FROM ubuntu:${UBUNTU_VERSION} AS base
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends ca-certificates curl tzdata \
 && rm -rf /var/lib/apt/lists/*
# The official Ubuntu image ships a non-root "ubuntu" user (UID 1000)
USER ubuntu
WORKDIR /home/ubuntu

# ---------- builder: toolchain for compiling apps ----------
FROM base AS builder
ARG DEBIAN_FRONTEND=noninteractive
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build pkg-config git \
      python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*
USER ubuntu
WORKDIR /src

# ---------- ffmpeg: latest static build (BtbN) with NVENC/QSV/VAAPI/AMF/Vulkan ----------
FROM ubuntu:${UBUNTU_VERSION} AS ffmpeg
ARG TARGETARCH
# master-latest tracks ffmpeg git master; a release branch also works,
# e.g. ffmpeg-n7.1-latest (see github.com/BtbN/FFmpeg-Builds/releases)
ARG FFMPEG_ASSET=ffmpeg-master-latest
# Changes whenever BtbN republishes the asset, which forces a fresh download
ARG FFMPEG_STAMP=0
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in amd64) A=linux64;; arm64) A=linuxarm64;; *) exit 1;; esac; \
    echo "ffmpeg stamp: ${FFMPEG_STAMP}"; \
    mkdir -p /opt/ffmpeg; \
    curl -fsSL "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/${FFMPEG_ASSET}-${A}-gpl.tar.xz" \
      | tar -xJ --strip-components=1 -C /opt/ffmpeg; \
    /opt/ffmpeg/bin/ffmpeg -version | head -1

# ---------- tdarr: node only ----------
FROM ubuntu:${UBUNTU_VERSION} AS tdarr
ARG TARGETARCH
ARG TDARR_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; test -n "${TDARR_VERSION}"; \
    case "${TARGETARCH:-amd64}" in amd64) P=linux_x64;; arm64) P=linux_arm64;; *) exit 1;; esac; \
    mkdir -p /opt/tdarr && cd /opt/tdarr; \
    curl -fsSL -o node.zip "https://storage.tdarr.io/versions/${TDARR_VERSION}/${P}/Tdarr_Node.zip"; \
    unzip -q node.zip && rm node.zip; \
    BIN="$(find /opt/tdarr -type f -name Tdarr_Node | head -1)"; \
    chmod +x "$BIN"; ln -s "$(dirname "$BIN")" /opt/tdarr/node; \
    echo "$TDARR_VERSION" > /opt/tdarr/VERSION

# ---------- handbrake-bin: finished HandBrakeCLI from its own CI job ----------
FROM ${HANDBRAKE_IMAGE} AS handbrake-bin

# ---------- media: final image ----------
FROM base AS media
ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_VERSION
ARG TDARR_VERSION
ARG HANDBRAKE_VERSION
ARG FFMPEG_STAMP
ARG UBUNTU_DIGEST
USER root

COPY --from=handbrake-bin /opt/handbrake/runtime-pkgs.txt /tmp/runtime-pkgs.txt
COPY docker/install-gpu.sh /tmp/install-gpu.sh
# Tools + HandBrake's shared-lib packages + GPU userspace (Intel/AMD/NVIDIA-ready)
RUN apt-get update \
 && apt-get install -y --no-install-recommends mkvtoolnix mediainfo jq unzip $(cat /tmp/runtime-pkgs.txt) \
 && bash /tmp/install-gpu.sh \
 && rm -rf /var/lib/apt/lists/* /tmp/*

COPY --from=ffmpeg /opt/ffmpeg/bin/ /usr/local/bin/
COPY --from=handbrake-bin /opt/handbrake/bin/ /usr/local/bin/
COPY --from=handbrake-bin /opt/handbrake/share/ /usr/local/share/
COPY --from=tdarr /opt/tdarr /opt/tdarr
COPY docker/tdarr-node-entrypoint.sh /usr/local/bin/tdarr-node-entrypoint
RUN chmod +x /usr/local/bin/tdarr-node-entrypoint \
 && mkdir -p /data/tdarr /media /temp \
 && chown -R ubuntu:ubuntu /opt/tdarr /data /media /temp

# NVIDIA: the host's NVIDIA Container Toolkit injects the driver libs at run time;
# these variables tell it to expose the encode/decode (video) and CUDA (compute) parts.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility \
    rootDataPath=/data/tdarr \
    inContainer=true \
    nodeName=ubuntu-node
LABEL dev.media.ubuntu="${UBUNTU_VERSION}" \
      dev.media.tdarr="${TDARR_VERSION}" \
      dev.media.handbrake="${HANDBRAKE_VERSION}" \
      dev.media.ffmpeg-stamp="${FFMPEG_STAMP}" \
      dev.media.ubuntu-digest="${UBUNTU_DIGEST}"
VOLUME ["/data/tdarr", "/temp"]
USER ubuntu
WORKDIR /data/tdarr
ENTRYPOINT ["/usr/local/bin/tdarr-node-entrypoint"]

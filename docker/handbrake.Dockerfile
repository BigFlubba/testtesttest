# syntax=docker/dockerfile:1
# Builds HandBrakeCLI and exports ONLY the finished files (scratch image).
# Compilers, contribs and sources never reach the final media image.
ARG UBUNTU_VERSION=26.04

FROM ubuntu:${UBUNTU_VERSION} AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG HANDBRAKE_VERSION

RUN echo "[$(date -u +%T)] === 1/5 installing build dependencies ===" \
 && apt-get update && apt-get install -y --no-install-recommends \
      autoconf automake autopoint appstream build-essential cmake git curl wget xz-utils bzip2 ca-certificates \
      libass-dev libbz2-dev libfontconfig-dev libfreetype-dev libfribidi-dev libharfbuzz-dev \
      libjansson-dev liblzma-dev libmp3lame-dev libnuma-dev libogg-dev libopus-dev \
      libsamplerate0-dev libspeex-dev libtheora-dev libtool libtool-bin libturbojpeg0-dev \
      libvorbis-dev libx264-dev libxml2-dev libvpx-dev libva-dev libdrm-dev libvpl-dev \
      m4 make meson nasm ninja-build patch pkg-config python3 tar zlib1g-dev cargo cargo-c \
 && rm -rf /var/lib/apt/lists/*
COPY docker/run-logged.sh /usr/local/bin/run-logged

WORKDIR /tmp/handbrake
COPY patches/handbrake/ /patches/
RUN echo "[$(date -u +%T)] === 2/5 downloading HandBrake ${HANDBRAKE_VERSION} + applying patches ===" \
 && test -n "${HANDBRAKE_VERSION}" \
 && wget -nv -O handbrake.tar.bz2 \
      "https://github.com/HandBrake/HandBrake/releases/download/${HANDBRAKE_VERSION}/HandBrake-${HANDBRAKE_VERSION}-source.tar.bz2" \
 && tar -xf handbrake.tar.bz2 --strip-components=1 \
 && for p in /patches/*.patch; do if [ -e "$p" ]; then echo "applying $p"; patch -p1 < "$p"; fi; done

# Same flags as your original script. --launch is split into explicit configure and
# compile steps so each phase is timed, visible, and cached separately.
RUN echo "[$(date -u +%T)] === 3/5 configure ===" \
 && run-logged configure ./configure \
      --prefix=/opt/handbrake \
      --enable-qsv \
      --enable-vce \
      --enable-nvenc \
      --enable-nvdec \
      --enable-libdovi \
      --enable-x265 \
      --disable-gtk

RUN echo "[$(date -u +%T)] === 4/5 compile (longest step, contribs build first) ===" \
 && run-logged compile make --directory=build -j"$(nproc)"

RUN echo "[$(date -u +%T)] === 5/5 install ===" \
 && (make --directory=build install \
     || (echo "make install failed, copying binary directly" \
         && mkdir -p /opt/handbrake/bin && cp build/HandBrakeCLI /opt/handbrake/bin/ && chmod +x /opt/handbrake/bin/HandBrakeCLI)) \
 && /opt/handbrake/bin/HandBrakeCLI --version 2>&1 | head -3 \
 && echo "HandBrake installation completed"

# Record which apt packages provide the shared libs HandBrakeCLI links against,
# so the media image installs exactly those (robust to package renames between releases).
RUN ldd /opt/handbrake/bin/HandBrakeCLI | awk '/=> \//{print $3}' \
  | xargs -r realpath | xargs -r dpkg -S 2>/dev/null | cut -d: -f1 | sort -u \
  > /opt/handbrake/runtime-pkgs.txt; echo "runtime packages:"; cat /opt/handbrake/runtime-pkgs.txt

FROM scratch AS artifact
COPY --from=build /opt/handbrake /opt/handbrake

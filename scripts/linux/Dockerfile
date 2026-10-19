# Linux build and run check: Debian trixie (packaged SDL3) and Zig 0.17.0.
# Also the Windows cross build (scripts/dist-windows.sh): mingw-w64 for FFmpeg, zip.
# Image build and run: scripts/linux/check.sh.
FROM debian:trixie-slim
ARG ZIG=0.17.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils pkg-config make gcc libc6-dev nasm libsdl3-dev \
      libavformat-dev libavcodec-dev libswscale-dev libswresample-dev libavutil-dev \
      gcc-mingw-w64-x86-64 zip && \
    rm -rf /var/lib/apt/lists/*
RUN arch=$(uname -m) && \
    curl -sSLf --retry 5 --retry-all-errors https://ziglang.org/download/${ZIG}/zig-${arch}-linux-${ZIG}.tar.xz | tar -xJ -C /opt && \
    ln -s /opt/zig-${arch}-linux-${ZIG}/zig /usr/local/bin/zig
WORKDIR /src

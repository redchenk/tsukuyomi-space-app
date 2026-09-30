#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update
# LLVM's bundled libunwind headers conflict with GStreamer's distro headers.
mapfile -t unwind_packages < <(dpkg-query -W -f='${binary:Package}\n' 'libunwind-*-dev' 2>/dev/null || true)
if ((${#unwind_packages[@]})); then
  sudo apt-get remove -y "${unwind_packages[@]}"
fi
sudo apt-get install -y clang cmake ninja-build pkg-config dpkg-dev libunwind-dev libgtk-3-dev \
  libsecret-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-libav libmpv-dev libepoxy-dev

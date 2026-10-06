#!/usr/bin/env bash
# GPU userspace for ffmpeg / HandBrake / Tdarr.
#  - Intel: VAAPI + QSV (iHD driver, oneVPL runtime, OpenCL for tone-mapping)
#  - AMD:   VAAPI (Mesa) + Vulkan.  AMF needs AMD's proprietary lib, see README.
#  - NVIDIA: nothing to install; the host NVIDIA Container Toolkit injects the driver libs.
# Required packages must install. Optional ones are non-fatal so a package rename
# in a new Ubuntu release warns instead of breaking the whole build.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

required=(libva2 libva-drm2 vainfo mesa-va-drivers libvulkan1 mesa-vulkan-drivers ocl-icd-libopencl1 clinfo)
optional=(intel-media-va-driver-non-free libvpl2 libmfx-gen1.2 intel-opencl-icd libigdgmm12)

apt-get install -y --no-install-recommends "${required[@]}"
for p in "${optional[@]}"; do
  apt-get install -y --no-install-recommends "$p" || echo "::warning::optional GPU package $p not installable on this release"
done
echo "--- GPU userspace installed ---"
dpkg -l "${required[@]}" "${optional[@]}" 2>/dev/null | awk '/^ii/{print $2, $3}'

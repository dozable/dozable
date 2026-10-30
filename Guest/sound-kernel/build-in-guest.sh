#!/bin/bash
# The sound kernel's build (667; first built by 604). Runs as root INSIDE an ubuntu:22.04 arm64 VM with network — the
# toolchain kata's own kernel names in its embedded config (gcc 11.4.0, binutils 2.38, no pahole).
#
# Inputs in /out:  base.config — the PINNED kernel's embedded config (KernelArtifact.recommended, vmlinux-6.18.15-186:
#                  the exact result of kata 3.28.0's fragments; `extract-config.py` takes it out of the image);
#                  sound.conf — this folder's fragment.
# Outputs in /out: vmlinux-6.18.15-186-sound (arch/arm64/boot/Image), sound.config (the full config), build.log.
#
# Reproducible: the build's timestamp, user, host and number are fixed, and it is built TWICE from two extractions in
# the SAME directory, /root/b/linux-6.18.15; the run fails unless both images are byte-identical. The directory is part
# of the recipe: the vDSO is built with debug information, whose build directory reaches its GNU build-id (measured
# 2026-10-27: the same build in /root/b1 and /root/b2 differs only in the vDSO's build-id note).
set -euo pipefail
LINUX_VERSION=6.18.15   # its tarball is checked against kernel.org's sha256sums.asc below
KATA_TAG=3.28.0
KATA_PATCH=0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch   # tools/packaging/kernel/patches/6.18.x at the tag
JOBS=${JOBS:-$(nproc)}
OUT=/out
export KBUILD_BUILD_TIMESTAMP="2026-10-27 00:00:00 UTC" KBUILD_BUILD_USER=dozable KBUILD_BUILD_HOST=dozable KBUILD_BUILD_VERSION=1
exec > >(tee "$OUT/build.log") 2>&1
echo "start $(date -u +%FT%TZ) on $(uname -m), $(nproc) cpus"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential flex bison bc libelf-dev libssl-dev git curl \
  xz-utils ca-certificates python3 cpio kmod gnupg >/dev/null
gcc --version | head -1; ld --version | head -1
cd /root
curl -fsSLO "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz"
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/sha256sums.asc" -o sha256sums.asc
grep " linux-${LINUX_VERSION}.tar.xz\$" sha256sums.asc | sha256sum -c -
curl -fsSL "https://raw.githubusercontent.com/kata-containers/kata-containers/${KATA_TAG}/tools/packaging/kernel/patches/6.18.x/$KATA_PATCH" -o "/root/$KATA_PATCH"
# The pins (2026-10-27) — the patch is also kept in patches/ beside this script (the source offer).
echo "7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170  linux-${LINUX_VERSION}.tar.xz" | sha256sum -c -
echo "92dd4a192ea58fa9a59e3bc6d6995e2a156cf862c36a3c10eb212fabdecdaf03  /root/$KATA_PATCH" | sha256sum -c -

B=/root/b
build() {   # build → /root/Image.$1, always in $B
  rm -rf "$B" && mkdir -p "$B" && tar xf "/root/linux-${LINUX_VERSION}.tar.xz" -C "$B"
  cd "$B/linux-${LINUX_VERSION}"
  patch -p1 < "/root/$KATA_PATCH"
  cp "$OUT/base.config" .config
  ARCH=arm64 scripts/kconfig/merge_config.sh -m .config "$OUT/sound.conf"
  make -s ARCH=arm64 olddefconfig
  time make -s -j"$JOBS" ARCH=arm64 Image
  cp arch/arm64/boot/Image "/root/Image.$1"
  cd /root
}
build 1
cp "$B/linux-${LINUX_VERSION}/.config" "$OUT/sound.config"
diff <(grep -v '^#\s*$' "$OUT/base.config") <(grep -v '^#\s*$' "$OUT/sound.config") | grep '^[<>]' > "$OUT/config.delta" || true
echo "config delta: $(wc -l < "$OUT/config.delta") lines"
build 2
sha256sum /root/Image.1 /root/Image.2
if cmp /root/Image.1 /root/Image.2; then echo "reproducible: the two builds are byte-identical"; else echo "NOT reproducible"; exit 1; fi
cp /root/Image.1 "$OUT/vmlinux-${LINUX_VERSION}-186-sound"
ls -l "$OUT/vmlinux-${LINUX_VERSION}-186-sound"; sha256sum "$OUT/vmlinux-${LINUX_VERSION}-186-sound"
echo "done $(date -u +%FT%TZ)"

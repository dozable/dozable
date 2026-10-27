#!/bin/bash
# 667: build the sound kernel FROM SOURCE with Guest/sound-kernel/'s recipe, and check it is the pinned one.
#
#   Scripts/sound-kernel.sh            build → $SOUND_KERNEL_OUT/vmlinux-…-sound2 (+ sound.config, config.delta,
#                                      build.log, SHA256SUMS); exit 1 unless its sha256 is SoundKernel.sha256
#                                      (Sources/DozableKit/Audio.swift) and its config is Guest/sound-kernel/sound.config
#
# `make sound-kernel` runs it (after `vmtest-host`: the entitled doz-vmtest that boots the build VM). CI:
# .github/workflows/sound-kernel.yml, on the Dozable Mac (doz-ci). How it works: the pinned kernel (KernelProvider —
# fetched once into the kernel cache, sha256-checked) gives the base config (extract-config.py); a throwaway
# ubuntu:22.04 sandbox (NAT, `doz-vmtest spike-build`) runs build-in-guest.sh as root with this run's output folder
# shared at /out — which downloads Linux and kata's patch (both sha256-pinned), builds TWICE in one fixed directory and
# fails unless the two images are byte-identical. Network: Docker Hub (ubuntu), Ubuntu's apt mirrors, cdn.kernel.org,
# raw.githubusercontent.com.
#
# Environment (all optional): SOUND_KERNEL_OUT (default .build/sound-kernel — emptied first), SOUND_KERNEL_STORE (the
# build VM's SCRATCH store, default $TMPDIR/doz-sound-kernel-store; the ubuntu image is kept there between runs, the
# sandbox never is), DOZ_KERNEL_CACHE (the pinned kernel's cache; default under the store), SOUND_KERNEL_CPUS
# (default: the Mac's performance cores, at most 8), DOZ_SUBNET (default 192.168.236.0/24).
set -euo pipefail
cd "$(dirname "$0")/.."
VMTEST=.build/debug/doz-vmtest
OUT=${SOUND_KERNEL_OUT:-.build/sound-kernel}
STORE=${SOUND_KERNEL_STORE:-${TMPDIR:-/tmp/}doz-sound-kernel-store}
STORE=${STORE%/}
CPUS=${SOUND_KERNEL_CPUS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 6)}
[ "$CPUS" -gt 8 ] && CPUS=8
export DOZ_SUBNET=${DOZ_SUBNET:-192.168.236.0/24}
PIN_FILE=Sources/DozableKit/Audio.swift
NAME=$(sed -n 's/.*static let fileName = "\(vmlinux-[^"]*\)".*/\1/p' "$PIN_FILE")
PIN=$(sed -n 's/.*static let sha256 = "\([0-9a-f]\{64\}\)".*/\1/p' "$PIN_FILE")
[ -n "$NAME" ] && [ -n "$PIN" ] || { echo "x could not read SoundKernel.fileName / .sha256 from $PIN_FILE" >&2; exit 1; }
[ -x "$VMTEST" ] || { echo "x $VMTEST missing — make vmtest-host (make sound-kernel does it)" >&2; exit 1; }

T0=$(date +%s)
mkdir -p "$STORE"
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
find "$OUT" -mindepth 1 -delete
echo "== the sound kernel from source: $NAME, pinned sha256 $PIN"
echo "   out $OUT · store $STORE · $CPUS CPUs · $(sw_vers -productVersion 2>/dev/null) $(uname -m)"

# 1. The pinned kernel (verified) → its embedded config is the build's base.
perl -e 'alarm shift; exec @ARGV' 900 "$VMTEST" kernel --store "$STORE" | tail -3
KC=${DOZ_KERNEL_CACHE:-$STORE/kernels}
BASE_KERNEL="$KC/vmlinux-6.18.15-186"
[ -f "$BASE_KERNEL" ] || { echo "x the pinned kernel is not at $BASE_KERNEL" >&2; exit 1; }
python3 Guest/sound-kernel/extract-config.py "$BASE_KERNEL" "$OUT/base.config"
cp Guest/sound-kernel/sound.conf "$OUT/sound.conf"

# 2. The build, in a throwaway VM (the recipe builds twice and compares).
T1=$(date +%s)
perl -e 'alarm shift; exec @ARGV' 5400 "$VMTEST" spike-build --store "$STORE" --image docker.io/library/ubuntu:22.04 \
  --script Guest/sound-kernel/build-in-guest.sh --share "$OUT" --cpus "$CPUS" --mem 8192 --disk 16384 --timeout 5000 \
  | grep -vE '^\s*$' | tail -40
T2=$(date +%s)
[ -f "$OUT/vmlinux-6.18.15-186-sound" ] || { echo "x the build left no image (see $OUT/build.log)" >&2; exit 1; }
mv "$OUT/vmlinux-6.18.15-186-sound" "$OUT/$NAME"
rm -f "$OUT/base.config" "$OUT/sound.conf"

# 3. Is it the pinned kernel, built from the committed config?
GOT=$(shasum -a 256 "$OUT/$NAME" | cut -d' ' -f1)
(cd "$OUT" && shasum -a 256 "$NAME" > SHA256SUMS)
rc=0
if [ "$GOT" = "$PIN" ]; then echo "ok sha256 $GOT = SoundKernel.sha256 ($NAME, $(stat -f %z "$OUT/$NAME") bytes)"
else echo "x sha256 $GOT is NOT SoundKernel.sha256 $PIN" >&2; rc=1; fi
if cmp -s "$OUT/sound.config" Guest/sound-kernel/sound.config; then echo "ok its .config is Guest/sound-kernel/sound.config"
else echo "x its .config differs from Guest/sound-kernel/sound.config:" >&2; diff Guest/sound-kernel/sound.config "$OUT/sound.config" | head -20 >&2; rc=1; fi
echo "time: $((T2 - T1)) s in the build VM (two builds), $(( $(date +%s) - T0 )) s in all"
exit $rc

# The sound kernel — provenance and source offer

A sandbox with sound (`sandbox.audio`, `doz create --sound`) boots this Linux kernel instead of the pinned one
(`KernelArtifact.recommended`, kata-containers' unmodified `vmlinux-6.18.15-186`, which has no sound support). It is
**not** in git (16 MB): a release that carries it puts it at `libexec/doz/kernels/vmlinux-6.18.15-186-sound2`, and
this folder at `libexec/doz/licences/sound-kernel/`. Nothing downloads it; the host checks its sha256 before every use.

| | |
|---|---|
| file | `vmlinux-6.18.15-186-sound2` (an uncompressed arm64 `Image`) |
| sha256 | `8d71cc61a0e55103d942c1a4961a3e72cc1159b8f442e882a2b7a6c6455a8b93` (`SoundKernel.sha256` in `Sources/DozableKit/Audio.swift`) |
| size | 16,284,160 bytes |
| licence | **GPL-2.0-only** (with the Linux syscall note) — Linux; Dozable built it and distributes it |
| Linux | 6.18.15 — `linux-6.18.15.tar.xz` from cdn.kernel.org, sha256 `7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170` (checked against kernel.org's `sha256sums.asc`) |
| kata-containers | 3.28.0 — its one 6.18.x patch, [`patches/0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch`](patches/) (sha256 `92dd4a192ea58fa9a59e3bc6d6995e2a156cf862c36a3c10eb212fabdecdaf03`), and its kernel config: the pinned kernel's own embedded config (`extract-config.py`), which is exactly the result of kata 3.28.0's fragments (`kata_config_version` 186) |
| the change | [`sound.conf`](sound.conf): four options — ALSA and virtio-snd. `olddefconfig` resolves what they select; **no option outside sound differs** (the delta: 14 options set, all `SOUND`/`SND*`) |
| the complete config | [`sound.config`](sound.config) — the `.config` this image was built with |
| toolchain | `gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0`, GNU ld 2.38 — the compiler kata's own kernel names in its config; in an `ubuntu:22.04` arm64 VM |
| the recipe | [`build-in-guest.sh`](build-in-guest.sh) (in the VM, as root; inputs in `/out`: `base.config` + `sound.conf`). `make sound-kernel` ([`Scripts/sound-kernel.sh`](../../Scripts/sound-kernel.sh)) runs all of it on a Mac: the pinned kernel's config, the build in a throwaway `ubuntu:22.04` sandbox (`doz-vmtest spike-build`), then the check that the result IS this file (its sha256 and its config); any arm64 Ubuntu 22.04 runs the recipe itself |
| reproducible | yes — 2026-10-27: two builds from two extractions in the same directory (`/root/b/linux-6.18.15`), byte-identical. The build's timestamp, user, host and number are fixed (`KBUILD_BUILD_*`); the DIRECTORY is part of the recipe — the vDSO's GNU build-id hashes its debug information, which names it (the same build in `/root/b1` and `/root/b2` differed in that note only). Rebuilt since by `make sound-kernel` on this Mac and in CI: the same sha256 |
| CI | [`.github/workflows/sound-kernel.yml`](../../.github/workflows/sound-kernel.yml) builds it from source on Dozable's own Mac runner (`doz-ci`) — on demand, and when this folder, the pin or the script changes — checks it against the pin and publishes it as the run's artefact `sound-kernel-8d71cc61a0e5` (the kernel, `SHA256SUMS`, its config, the config delta, the build log; kept 90 days) |

### Fetching the CI-built kernel

From the newest green run of the **Sound kernel** workflow (`gh` signed in to the repository):

```sh
RUN=$(gh run list --repo dozable/dozable --workflow sound-kernel.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
gh run download "$RUN" --repo dozable/dozable --name sound-kernel-8d71cc61a0e5 --dir sound-kernel
(cd sound-kernel && shasum -a 256 -c SHA256SUMS)     # vmlinux-6.18.15-186-sound2: OK
```

Then `make release … SOUND_KERNEL=sound-kernel/vmlinux-6.18.15-186-sound2` carries it, or `DOZ_TEST_SOUND_KERNEL` points a
development build at it. Nothing in doz downloads it: the host takes only a file whose sha256 is the pin. No CI run
handy? `make sound-kernel` builds the same bytes on any Apple-silicon Mac.
| tested | `AudioTests` (the pin, the device), the workspace probe `probes/667-*/remeasure.sh` (a real sandbox: a playback and a capture stream held open across pause, sleep, hibernate and a new host process) |

## Source offer

The complete corresponding source of this binary is: the Linux 6.18.15 tarball above (kernel.org), kata-containers
3.28.0's patch and this folder (`sound.conf`, `sound.config`, `build-in-guest.sh`, `extract-config.py`). A release of
doz that carries the kernel carries this folder beside it. On request, for three years from the release that carried
it, Dozable provides that source — the Linux tarball included — on a medium customarily used for software interchange,
for no more than the cost of providing it: ask through the project's issue tracker (github.com/dozable/dozable).

The 604 kernel (`vmlinux-6.18.15-186-sound`, sha256 `33d27069…`, private 0.26 builds only) had the same four
options; it was not built reproducibly (its file is lost) and is replaced by this one. A sandbox that slept under it still finds
it for its restore while the store's kernel cache has it.

# The pinned kernel — provenance and source offer

Every sandbox boots this Linux kernel (`KernelArtifact.recommended` in `Sources/DozableKit/KernelProvider.swift`) unless
it was made with sound or a kernel of its own. Both release tarballs (the command-line release and the helper build an
app carries) **carry it**, unmodified, at `libexec/doz/kernels/vmlinux-6.18.15-186`, and this folder at
`libexec/doz/licences/kernel/`. It is not in git (16 MB). The first start copies it into the store's kernel cache after
checking its sha256; nothing is downloaded. A build without it (`make cli`, a source build) gets the same file from
kata-containers' release archive the first time, checked against the same pin.

| | |
|---|---|
| file | `vmlinux-6.18.15-186` (an uncompressed arm64 `Image`) |
| sha256 | `2fe4a58d2885d623bcb4d705900ac8c1d4f02371152da8126b3b00c8c47fc3a1` (`KernelArtifact.recommended.kernelSHA256`) |
| size | 16,151,040 bytes |
| licence | **GPL-2.0-only** (with the Linux syscall note) — Linux; built by the kata-containers project, redistributed by Dozable unmodified |
| where it comes from | kata-containers 3.28.0's static release for arm64, `kata-static-3.28.0-arm64.tar.zst` (sha256 `f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91`), member `opt/kata/share/kata-containers/vmlinux-6.18.15-186` — the kernel Apple's `container` tool installs as its recommended one |
| Linux | 6.18.15 — `linux-6.18.15.tar.xz` from cdn.kernel.org, sha256 `7c716216c3c4134ed0de69195701e677577bbcdd3979f331c182acd06bf2f170` |
| kata-containers | 3.28.0 — its kernel recipe (`tools/packaging/kernel` at the tag `3.28.0`, github.com/kata-containers/kata-containers), with its one 6.18.x patch, [`../sound-kernel/patches/0001-fs-dax-check-zero-or-empty-entry-before-converting-xarray.patch`](../sound-kernel/patches/) (sha256 `92dd4a192ea58fa9a59e3bc6d6995e2a156cf862c36a3c10eb212fabdecdaf03`) |
| the complete config | [`kernel.config`](kernel.config) — the kernel's own embedded config (`CONFIG_IKCONFIG`), extracted by [`../sound-kernel/extract-config.py`](../sound-kernel/extract-config.py) (sha256 `ff5267fc331832a0d337af8ca05ff88d86869970920711c9bc3341922599214f`; kata's config fragments, `kata_config_version` 186) |
| toolchain | `gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0` — what the config names |
| checked | the pin, on every start (`KernelProvider`), and by `make release` before a tarball carries it |

## Source offer

The complete corresponding source of this binary is: the Linux 6.18.15 tarball above (kernel.org), kata-containers
3.28.0's kernel recipe and patch, and this folder (`kernel.config`). A release of doz that carries the kernel carries this
folder beside it (`libexec/doz/licences/kernel/`: this file, `kernel.config`, kata's patch and the extraction script).
On request, for three years from the release that carried it, Dozable provides that source — the Linux tarball and
kata-containers' recipe included — on a medium customarily used for software interchange, for no more than the cost of
providing it: ask through the project's issue tracker (github.com/dozable/dozable).

The sound kernel (`vmlinux-6.18.15-186-sound2`, private builds only) is a different file, built by Dozable from the same
sources with sound turned on: its own provenance and offer are in [`../sound-kernel/PROVENANCE.md`](../sound-kernel/PROVENANCE.md).

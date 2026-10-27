#!/usr/bin/env python3
# Write the EMBEDDED config (CONFIG_IKCONFIG) of an uncompressed arm64 Linux kernel image to a file, and print its
# sha256 and first line. The sound kernel's build starts from the pinned kernel's own config (KernelArtifact.recommended,
# vmlinux-6.18.15-186, sha256 2fe4a58d2885d623… — a store's kernels/ folder has it once a sandbox has started).
# Usage: python3 extract-config.py KERNEL_IMAGE OUT_CONFIG
import hashlib
import sys
import zlib

data = open(sys.argv[1], "rb").read()
print("sha256", hashlib.sha256(data).hexdigest())
i = data.find(b"IKCFG_ST")
if i < 0:
    sys.exit("no embedded config (CONFIG_IKCONFIG is not set)")
config = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(data[i + 8:]).decode()
open(sys.argv[2], "w").write(config)
print(config.splitlines()[2])

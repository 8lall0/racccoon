#!/usr/bin/env python3
# Prepends fiptool's 32-byte LOADER_2ND ("BL33") header to a raw kernel
# binary, matching boards/duo/kernel.ld's __loader2nd_runaddr reservation
# and duo-buildroot-sdk's fsbl/plat/cv180x/fiptool.py::add_loader_2nd,
# which requires this exact layout already present in the input file:
#   JUMP0(4) MAGIC(4)="BL33" CKSUM(4) SIZE(4) RUNADDR(8) RESERVED1(4) RESERVED2(4)
# CKSUM/SIZE get recomputed by fiptool.py itself (_update_ldr_2nd_hdr) —
# only MAGIC and RUNADDR need to be correct going in. See docs/devlog.md
# for how this was traced through the real FSBL/fiptool source.
import struct
import sys

RUNADDR = 0x80200000


def main() -> None:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <raw-kernel-bin> <out-loader2nd-bin>", file=sys.stderr)
        sys.exit(1)

    raw_path, out_path = sys.argv[1], sys.argv[2]
    with open(raw_path, "rb") as f:
        body = f.read()

    header = struct.pack(
        "<IIIIQII",
        0x01A005,  # JUMP0 — not read by FSBL's load path (entry is always
                   # runaddr+32), reusing the vendor u-boot header's value
        0,          # MAGIC placeholder, overwritten with literal ASCII "BL33" below
        0,          # CKSUM (recomputed by fiptool)
        0,          # SIZE (recomputed by fiptool)
        RUNADDR,
        0,          # RESERVED1
        0,          # RESERVED2
    )
    header = header[:4] + b"BL33" + header[8:]
    assert len(header) == 32

    with open(out_path, "wb") as f:
        f.write(header + body)

    print(f"wrote {out_path}: {len(header) + len(body)} bytes (header=32, body={len(body)})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Deterministic GPT image generator for the P3 eMMC layout.

Replaces the hand-maintained binary templates firmware/gpt.img and
firmware/04_backup_gpt.img with a reproducible build step.

Disk layout (defaults, 512-byte sectors):

    LBA 0        protective MBR
    LBA 1        primary GPT header
    LBA 2..33    primary partition table (128 entries x 128 bytes)
    LBA 34..63   zero padding, up to the U-Boot area at LBA 64
    LBA 32768    boot partition start  (hard floor: LBA<32768 is U-Boot)
    LBA 819200   rootfs partition start
    LBA N-34     rootfs partition end  (N = disk sectors)
    LBA N-33..N-2 backup partition table
    LBA N-1      backup GPT header

Guides / invariants:
  * p1.start >= 32768.  Everything below LBA32768 belongs to U-Boot and
    must never be described as a partition, or a careless writer could
    overwrite the bootloader / auth block.
  * The last 33 sectors are reserved for the backup GPT.
  * GUIDs are pinned to the historical values so that the generated
    images are byte-identical to the checked-in binaries.  Changing a
    GUID is an explicit act (edit the constants below), never a side
    effect of running the generator twice.

Usage:
    python3 tools/mkgpt.py --out-dir build/gpt
    python3 tools/mkgpt.py --out-dir build/gpt --verify firmware
"""

import argparse
import os
import struct
import sys
import zlib

SECTOR = 512
GPT_ENTRIES = 128
GPT_ENTRY_SIZE = 128
GPT_TABLE_SECTORS = (GPT_ENTRIES * GPT_ENTRY_SIZE) // SECTOR  # 32

# P3 eMMC geometry (14.56 GiB)
DEFAULT_DISK_SECTORS = 30535680
DEFAULT_BOOT_START = 32768
DEFAULT_BOOT_END = 819199
DEFAULT_ROOTFS_START = 819200
BOOTAREA_FLOOR = 32768

# Historical GUIDs as raw on-disk bytes (GPT uses mixed-endian, so storing
# the bytes directly avoids every endianness trap).  Pinned so that two runs
# of this generator always produce identical images.
LINUX_FS_TYPE = bytes.fromhex("af3dc60f838472478e793d69d8477de4")
DISK_GUID = bytes.fromhex("62f28d3a69d8375ca7b541fecc0a971a")
BOOT_GUID = bytes.fromhex("3d9f0888676cfa5c848323a6bd7f36d2")
ROOTFS_GUID = bytes.fromhex("fda4045d9051495f8ea8916c23a2d8ca")

# Protective MBR CHS fields are legacy and unused by GPT, but retained so
# the generated MBR matches the historical binary exactly.
PMBR_START_CHS = bytes.fromhex("000200")
PMBR_END_CHS = bytes.fromhex("ffffff")


def make_pmbr(disk_sectors):
    b = bytearray(SECTOR)
    # single protective entry describing the whole disk
    entry = bytearray(16)
    entry[0] = 0x00               # not bootable
    entry[1:4] = PMBR_START_CHS
    entry[4] = 0xEE               # GPT protective type
    entry[5:8] = PMBR_END_CHS
    struct.pack_into("<I", entry, 8, 1)                 # start LBA
    struct.pack_into("<I", entry, 12, disk_sectors - 1)  # sector count
    b[446:462] = entry
    b[510:512] = b"\x55\xaa"
    return bytes(b)


def make_entry(guid, first, last, name):
    e = bytearray(GPT_ENTRY_SIZE)
    e[0:16] = LINUX_FS_TYPE
    e[16:32] = guid
    struct.pack_into("<QQQ", e, 32, first, last, 0)  # first, last, attrs
    encoded = name.encode("utf-16-le")[:72]
    e[56:56 + len(encoded)] = encoded
    return bytes(e)


def make_table(boot_start, boot_end, rootfs_start, rootfs_end):
    table = bytearray(GPT_TABLE_SECTORS * SECTOR)
    table[0:GPT_ENTRY_SIZE] = make_entry(BOOT_GUID, boot_start, boot_end, "boot")
    table[GPT_ENTRY_SIZE:2 * GPT_ENTRY_SIZE] = make_entry(
        ROOTFS_GUID, rootfs_start, rootfs_end, "rootfs")
    return bytes(table)


def make_header(current, backup, entry_lba, table_crc,
                first_usable, last_usable):
    h = bytearray(SECTOR)
    h[0:8] = b"EFI PART"
    struct.pack_into("<I", h, 8, 0x00010000)   # revision 1.0
    struct.pack_into("<I", h, 12, 92)          # header size
    struct.pack_into("<Q", h, 24, current)
    struct.pack_into("<Q", h, 32, backup)
    struct.pack_into("<Q", h, 40, first_usable)
    struct.pack_into("<Q", h, 48, last_usable)
    h[56:72] = DISK_GUID
    struct.pack_into("<Q", h, 72, entry_lba)
    struct.pack_into("<I", h, 80, GPT_ENTRIES)
    struct.pack_into("<I", h, 84, GPT_ENTRY_SIZE)
    struct.pack_into("<I", h, 88, table_crc)
    struct.pack_into("<I", h, 16, zlib.crc32(h[:92]) & 0xFFFFFFFF)
    return bytes(h)


def build(args):
    n = args.disk_sectors
    last_usable = n - 34
    rootfs_end = last_usable
    boot_start = args.boot_start
    boot_end = args.boot_end
    rootfs_start = args.rootfs_start

    # Hard safety checks: never describe the U-Boot area as a partition.
    if boot_start < BOOTAREA_FLOOR:
        raise ValueError(f"p1 start {boot_start} below LBA{BOOTAREA_FLOOR} floor")
    if not (BOOTAREA_FLOOR <= boot_start <= boot_end < rootfs_start <= rootfs_end):
        raise ValueError("partition ranges are not strictly increasing")
    if rootfs_end > last_usable:
        raise ValueError("rootfs overruns the backup GPT area")
    if n <= rootfs_start + GPT_TABLE_SECTORS + 1:
        raise ValueError(f"disk too small for the requested layout: {n} sectors")

    table = make_table(boot_start, boot_end, rootfs_start, rootfs_end)
    table_crc = zlib.crc32(table) & 0xFFFFFFFF
    first_usable = 2 + GPT_TABLE_SECTORS   # 34: right after the table

    primary = bytearray(64 * SECTOR)
    primary[0:SECTOR] = make_pmbr(n)
    primary[SECTOR:2 * SECTOR] = make_header(
        1, n - 1, 2, table_crc, first_usable, last_usable)
    primary[2 * SECTOR:2 * SECTOR + len(table)] = table

    backup = bytearray((GPT_TABLE_SECTORS + 1) * SECTOR)
    backup[0:len(table)] = table
    backup[-SECTOR:] = make_header(
        n - 1, 1, n - 33, table_crc, first_usable, last_usable)

    return bytes(primary), bytes(backup)


def verify(generated, reference, label):
    if not os.path.exists(reference):
        print(f"  {label}: reference missing, skipped")
        return True
    with open(reference, "rb") as f:
        old = f.read()
    if old == generated:
        print(f"  {label}: byte-identical ({len(old)} bytes)")
        return True
    diff = next((i for i, (a, b) in enumerate(zip(old, generated)) if a != b),
                min(len(old), len(generated)))
    print(f"  {label}: MISMATCH at byte {diff} "
          f"(old {len(old)} bytes, new {len(generated)} bytes)", file=sys.stderr)
    return False


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--print-sector", action="store_true",
                   help="print only the disk sector count (for CI to consume)")
    p.add_argument("--disk-sectors", type=int, default=DEFAULT_DISK_SECTORS)
    p.add_argument("--boot-start", type=int, default=DEFAULT_BOOT_START)
    p.add_argument("--boot-end", type=int, default=DEFAULT_BOOT_END)
    p.add_argument("--rootfs-start", type=int, default=DEFAULT_ROOTFS_START)
    p.add_argument("--out-dir", help="write gpt.img and 04_backup_gpt.img here")
    p.add_argument("--verify", metavar="DIR",
                   help="compare generated images against DIR/gpt.img and "
                        "DIR/04_backup_gpt.img; implies no write unless "
                        "--out-dir is also given")
    args = p.parse_args()

    if args.print_sector:
        print(args.disk_sectors)
        return 0

    primary, backup = build(args)

    print(f"disk sectors : {args.disk_sectors}")
    print(f"p1 boot      : {args.boot_start} - {args.boot_end}")
    print(f"p2 rootfs    : {args.rootfs_start} - {args.disk_sectors - 34}")
    print(f"backup GPT   : LBA {args.disk_sectors - 33} - {args.disk_sectors - 1}")
    print(f"gpt.img      : {len(primary)} bytes, "
          f"sha256={__import__('hashlib').sha256(primary).hexdigest()}")
    print(f"04_backup    : {len(backup)} bytes, "
          f"sha256={__import__('hashlib').sha256(backup).hexdigest()}")

    ok = True
    if args.verify:
        print("verification:")
        ok &= verify(primary, os.path.join(args.verify, "gpt.img"), "gpt.img")
        ok &= verify(backup, os.path.join(args.verify, "04_backup_gpt.img"),
                     "04_backup_gpt.img")

    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)
        for name, data in (("gpt.img", primary),
                           ("04_backup_gpt.img", backup)):
            path = os.path.join(args.out_dir, name)
            with open(path, "wb") as f:
                f.write(data)
            print(f"wrote {path}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

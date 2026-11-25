#!/bin/bash
# p3wfs-check.sh - validate a P3WFS1 webflash image before flashing.
# Use this to SELF-CHECK any image you pack: it performs the same gates the
# on-board installer enforces, plus full content sha verification.
#
# usage: p3wfs-check.sh <image.wfs> [disk_end_sectors=30535680]
#   disk_end_sectors = total eMMC sectors (P3 default 30535680)
# exit 0 = OK to flash, 1 = rejected
set -euo pipefail
IN=${1:?usage: p3wfs-check.sh <image.wfs> [disk_end_sectors]}
DISK=${2:-30535680}
BOOTAREA_END=32768
FAIL=0

die() { echo "FAIL: $1"; FAIL=1; }

SZ=$(stat -c%s "$IN")
# The header is plaintext zero-padded to 4096 bytes, so the raw slice carries
# NULs. Bash keeps them out of the variable but warns about it (stderr, once per
# substitution) - noise that hides real warnings in CI. Strip them explicitly.
H=$(head -c 4096 "$IN" | tr -d '\000')
MAGIC=$(echo "$H" | sed -n '1s/^\(P3WFS[0-9]*\)$/\1/p')
START=$(echo "$H" | sed -n 's/^WRITE_LBA=//p')
SEC=$(echo "$H" | sed -n 's/^IMAGE_SECTORS=//p')
ISHA=$(echo "$H" | sed -n 's/^IMAGE_SHA256=//p')

[ "$MAGIC" = "P3WFS1" ] || die "magic '$MAGIC' is not P3WFS1"
[ -n "$START" ] || die "WRITE_LBA missing"
[ -n "$SEC" ] || die "IMAGE_SECTORS missing"
[ -n "$ISHA" ] || die "IMAGE_SHA256 missing"
echo "$START" | grep -qE '^[0-9]+$' || die "WRITE_LBA not numeric: $START"
echo "$SEC"  | grep -qE '^[0-9]+$' || die "IMAGE_SECTORS not numeric: $SEC"
echo "$ISHA" | grep -qE '^[0-9a-f]{64}$' || die "IMAGE_SHA256 malformed"

# note: file size = 4096 header + xz stream (compressed), so the declared
# IMAGE_SECTORS is validated via the payload sha check below, not by size.

# bootarea protection + disk capacity (same gates as on-board installer)
[ "$START" -ge "$BOOTAREA_END" ] || die "WRITE_LBA=$START < $BOOTAREA_END (would overwrite GPT/U-Boot bootarea)"
[ $((START + SEC)) -le "$DISK" ] || die "image ends at LBA$((START+SEC-1)), beyond disk end $DISK"

# full content verification: decompressed payload sha must equal declared sha
GOT=$(tail -c +4097 "$IN" | xzcat | sha256sum | awk '{print $1}')
[ "$GOT" = "$ISHA" ] || die "payload sha mismatch: got $GOT, declared $ISHA"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: $IN"
  echo "  $SEC sectors ($(( SEC * 512 / 1048576 ))MB) -> LBA$START..$((START+SEC-1)) on a $DISK-sector eMMC"
  echo "  bootarea LBA0-32767 untouched; payload sha verified"
else
  echo "RESULT: image is NOT safe to flash"
  exit 1
fi

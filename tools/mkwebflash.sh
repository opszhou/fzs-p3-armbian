#!/bin/bash
# mkwebflash.sh - pack a raw partition-area image into a P3WFS1 webflash image.
#
# Format: P3WFS1 = [4096-byte plaintext header][xz-compressed payload]
#   header (first line magic, then KEY=VALUE lines, zero-padded to 4096):
#     P3WFS1
#     IMAGE_SECTORS=<sectors of the payload image>
#     WRITE_LBA=<first LBA on eMMC, must be >= 32768>
#     IMAGE_SHA256=<sha256 of the UNcompressed payload image>
#     CREATED=<UTC timestamp>
#
# The payload image is "content starting at WRITE_LBA" - typically boot+rootfs
# partition content for the P3 layout (WRITE_LBA=32768). GPT/U-Boot bootarea is
# NEVER included and NEVER written.
#
# usage: mkwebflash.sh <system.img> [out.wfs] [write_lba]
set -euo pipefail
IN=${1:?usage: mkwebflash.sh <system.img> [out.wfs] [write_lba=32768]}
OUT=${2:-${IN%.*}.wfs}
LBA=${3:-32768}

SZ=$(stat -c%s "$IN")
[ $((SZ % 512)) -eq 0 ] || { echo "ERROR: image size not 512-byte aligned: $SZ"; exit 1; }
SEC=$((SZ / 512))
SHA=$(sha256sum "$IN" | awk '{print $1}')

{
  printf 'P3WFS1\nIMAGE_SECTORS=%s\nWRITE_LBA=%s\nIMAGE_SHA256=%s\nCREATED=%s\n' \
    "$SEC" "$LBA" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  head -c 4000 /dev/zero
} > "$OUT.tmp"
xz -T0 -9 -c "$IN" >> "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo "built $OUT"
echo "  payload: $SEC sectors ($SZ bytes) @ LBA$LBA"
echo "  payload sha256: $SHA"
echo "next: p3wfs-check.sh $OUT, then mkfit.sh $OUT <Image> <dtb> <busybox> <out.fit>"

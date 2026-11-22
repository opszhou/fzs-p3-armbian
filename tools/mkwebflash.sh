#!/bin/bash
# mkwebflash.sh - pack a raw image into a P3WFS1 webflash image.
#
# Format: P3WFS1 = [4096-byte plaintext header][xz-compressed payload]
#   header (first line magic, then KEY=VALUE lines, zero-padded to exactly 4096):
#     P3WFS1
#     IMAGE_SECTORS=<sectors of the payload image>
#     WRITE_LBA=<first LBA on eMMC, must be >= 32768>
#     IMAGE_SHA256=<sha256 of the UNcompressed payload image>
#     CREATED=<UTC timestamp>
#
# Input handling - two accepted forms:
#   1) FULL-DISK image (GPT detected at LBA1): the bootarea (LBA0-32767,
#      GPT + U-Boot) and the disk-end backup GPT (last 33 sectors) are
#      AUTOMATICALLY STRIPPED. Payload = partitions only, WRITE_LBA=32768.
#   2) PARTITION-AREA image (no GPT): used as-is; payload = whole file,
#      WRITE_LBA = $3 (default 32768). First payload byte maps to WRITE_LBA.
#
# usage: mkwebflash.sh <system.img> [out.wfs] [write_lba=32768]
set -euo pipefail
IN=${1:?usage: mkwebflash.sh <system.img> [out.wfs] [write_lba=32768]}
OUT=${2:-${IN%.*}.wfs}
LBA=${3:-32768}

SZ=$(stat -c%s "$IN")
[ $((SZ % 512)) -eq 0 ] || { echo "ERROR: image size not 512-byte aligned: $SZ"; exit 1; }
SEC=$((SZ / 512))

# --- detect full-disk image and strip bootarea + disk-end GPT ---
if [ "$SEC" -gt $((32768 + 33)) ] && dd if="$IN" bs=512 skip=1 count=1 2>/dev/null | grep -q 'EFI PART'; then
  FULLDISK=yes
  PS=32768
  PSEC=$((SEC - 32768 - 33))
  echo "full-disk image detected (GPT @LBA1): stripping bootarea LBA0-32767 and disk-end backup GPT"
else
  FULLDISK=no
  PS=0
  PSEC=$SEC
  [ "$LBA" -ge 32768 ] || { echo "ERROR: WRITE_LBA $LBA < 32768 would overwrite the bootarea"; exit 1; }
fi

echo "payload: skip=$PS sectors, $PSEC sectors ($(( PSEC * 512 / 1048576 ))MB) -> eMMC LBA$((PS==0 ? LBA : 32768)).."
echo "streaming payload sha (pass 1/2)..."
SHA=$(dd if="$IN" bs=512 skip="$PS" count="$PSEC" 2>/dev/null | sha256sum | awk '{print $1}')

# --- header: text then zero-padded to EXACTLY 4096 bytes (xz stream at offset 4096) ---
printf 'P3WFS1\nIMAGE_SECTORS=%s\nWRITE_LBA=%s\nIMAGE_SHA256=%s\nCREATED=%s\n' \
  "$PSEC" "$((PS==0 ? LBA : 32768))" "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT.tmp"
truncate -s 4096 "$OUT.tmp"
echo "streaming payload -> xz (pass 2/2)..."
dd if="$IN" bs=512 skip="$PS" count="$PSEC" 2>/dev/null | xz -T0 -9 -c >> "$OUT.tmp"

mv "$OUT.tmp" "$OUT"
NEWSZ=$(stat -c%s "$OUT")
[ "$NEWSZ" -eq $((4096 + PSEC * 512)) ] || { echo "INTERNAL ERROR: wfs size $NEWSZ != 4096+$PSEC*512"; exit 1; }

echo "built $OUT ($(( NEWSZ / 1048576 ))MB compressed)"
echo "  payload: $PSEC sectors -> WRITE_LBA$((PS==0 ? LBA : 32768))"
[ "$FULLDISK" = yes ] && echo "  stripped: LBA0-32767 (GPT+U-Boot) + disk-end backup GPT (33 sectors)"
echo "  payload sha256: $SHA"
echo "next: p3wfs-check.sh $OUT, then mkfit.sh $OUT <Image> <dtb> <busybox> <out.fit>"

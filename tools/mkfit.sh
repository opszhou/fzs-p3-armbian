#!/bin/bash
# mkfit.sh - wrap a P3WFS1 webflash image into a FIT suitable for the board's
# webflash HTTP uploader (multipart POST /upload, GET /result -> bootm).
#
# usage: mkfit.sh <image> <Image> <board.dtb> <busybox> <out.fit> [disk_end_sectors] [gptparse]
#   image = P3WFS1 .wfs OR whole-disk image (xz/gzip/raw GPT) - init auto-detects
#   disk_end_sectors defaults to 30535680 (P3 eMMC); baked into the initramfs so
#   the installer can refuse images that would run past the end of the disk.
#   gptparse (optional, aarch64 static binary) enables whole-disk GPT parsing.
set -euo pipefail
IN=${1:?usage: mkfit.sh <image> <Image> <dtb> <busybox> <out.fit> [disk_end] [gptparse]}
KERNEL=${2:?missing kernel Image}
DTB=${3:?missing board dtb}
BUSYBOX=${4:?missing busybox}
OUT=${5:?missing output .fit path}
DISK=${6:-30535680}
GPTPARSE=${7:-}

HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/init.tmpl" ] || { echo "ERROR: init.tmpl not found next to mkfit.sh"; exit 1; }
[ -x "$BUSYBOX" ] || chmod 755 "$BUSYBOX"
[ -f "$KERNEL" ] && [ -f "$DTB" ] || { echo "ERROR: kernel/dtb missing"; exit 1; }

IMG_SHA=$(sha256sum "$IN" | awk '{print $1}')
echo "packing $IN (sha=$IMG_SHA) into FIT, DISK_END=$DISK"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
I="$W/inst"; mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/sys" "$I/tmp"
cp "$BUSYBOX" "$I/bin/busybox"; chmod 755 "$I/bin/busybox"
ln -sf busybox "$I/bin/sh"
cp "$IN" "$I/system.img"
if [ -n "$GPTPARSE" ] && [ -f "$GPTPARSE" ]; then
  cp "$GPTPARSE" "$I/bin/gptparse"; chmod 755 "$I/bin/gptparse"
  echo "gptparse packed in: whole-disk GPT images supported"
fi
sed -e "s/__WFS_SHA__/$IMG_SHA/" -e "s/__DISK_END__/$DISK/" "$HERE/init.tmpl" > "$I/init"
chmod 755 "$I/init"
# hard gate: /init and busybox must be executable (EACCES -13 otherwise)
[ -x "$I/init" ] && [ -x "$I/bin/busybox" ] || { echo "initramfs perms BAD"; exit 1; }
# force inode owner root:root (runner uid would differ on the board's init run)
(cd "$I" && find . -print0 | cpio --null --owner=0:0 -o -H newc | gzip -9 > "$W/initrd.gz")

# signing hooks are configured below (P3_FIT_KEYS, optional); the .its
# heredoc references $P3_SIG_NODE, so initialize before writing it -
# with set -u an unset variable aborts the script mid-heredoc
P3_SIG_NODE=""; P3_MKIMG_ARGS=""
KERNEL_ABS=$(readlink -f "$KERNEL"); DTB_ABS=$(readlink -f "$DTB"); RD_ABS="$W/initrd.gz"
cat > "$W/i.its" <<ITS
/dts-v1/;
/ { description="P3 webflash installer (universal)"; #address-cells=<1>;
  images {
    k { description="kernel"; data = /incbin/("$KERNEL_ABS"); type="kernel"; arch="arm64"; os="linux"; compression="none"; load=<0x20000000>; entry=<0x20000000>; hash-1 { algo="sha256"; }; };
    r { description="initramfs"; data = /incbin/("$RD_ABS"); type="ramdisk"; arch="arm64"; os="linux"; compression="none"; load=<0x24000000>; hash-1 { algo="sha256"; }; };
    f { description="dtb"; data = /incbin/("$DTB_ABS"); type="flat_dt"; arch="arm64"; compression="none"; load=<0x40000000>; hash-1 { algo="sha256"; }; };
  };
  configurations { default="c"; c { kernel="k"; ramdisk="r"; fdt="f"; $P3_SIG_NODE }; };
};
ITS
OUTDIR=$(mkdir -p "$(dirname "$OUT")" && cd "$(dirname "$OUT")" && pwd)
# 方案A 可选 FIT 签名（M1/M2）：设 P3_FIT_KEYS=<密钥目录，含 p3.key（+p3.crt）> 启用。
# P3_FIT_DTB=<接收公钥的 u-boot.dtb>（验方 = U-Boot，公钥必须编进它的 DTB）；-r = required。
# 未设置时行为与旧版完全一致（仅 sha256 哈希，无签名）。
if [ -n "${P3_FIT_KEYS:-}" ]; then
  [ -f "$P3_FIT_KEYS/p3.key" ] || { echo "ERROR: $P3_FIT_KEYS/p3.key 不存在"; exit 1; }
  [ -f "$P3_FIT_KEYS/p3.crt" ] || openssl req -x509 -key "$P3_FIT_KEYS/p3.key" -out "$P3_FIT_KEYS/p3.crt" -subj "/CN=p3-secureboot" -days 3650 >/dev/null 2>&1
  P3_SIG_NODE=$'    signature-1 { algo = "sha256,rsa2048"; key-name-hint = "p3"; sign-images = "kernel", "ramdisk", "fdt"; };'
  P3_MKIMG_ARGS="-k "$P3_FIT_KEYS" -r"
  [ -n "${P3_FIT_DTB:-}" ] && P3_MKIMG_ARGS="$P3_MKIMG_ARGS -K "$P3_FIT_DTB""
  echo "FIT signing: enabled (keys=$P3_FIT_KEYS dtb=${P3_FIT_DTB:-none})"
fi
mkimage -f "$W/i.its" $P3_MKIMG_ARGS "$OUTDIR/$(basename "$OUT")" >/dev/null
[ -n "${P3_FIT_KEYS:-}" ] && echo "FIT signed: $(basename "$OUT") (rsa2048, required)"
FSHA=$(sha256sum "$OUTDIR/$(basename "$OUT")" | awk '{print $1}')
echo "FIT built: $OUT sha=$FSHA"

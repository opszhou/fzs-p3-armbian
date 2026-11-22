#!/bin/sh
#
# Bake the first-boot one-shot into an ext4 rootfs image, offline.
#
#   tools/p3-firstboot-inject.sh <rootfs.img>          install + enable
#   tools/p3-firstboot-inject.sh --seed-only <fs.img>  only set the feature
#
# Uses debugfs instead of a loop mount: the build hosts, the CI runner and a
# laptop all behave the same, and nothing has to be mounted read-write.
#
# What lands in the image:
#   /usr/lib/p3/p3-firstboot.sh                     0755, the runtime script
#   /etc/systemd/system/p3-firstboot.service        0644, oneshot wrapper
#   /etc/systemd/system/multi-user.target.wants/     symlink, so it is enabled
#   metadata_csum_seed on the filesystem              lets tune2fs -U run on a
#                                                     mounted fs at first boot
#
# The rootfs is edited in place; the caller is expected to have a copy.
# Every step is verified by reading the result back, so a silent no-op cannot
# ship an image that never performs the first-boot work.
set -eu

seed_only=0
if [ "${1:-}" = "--seed-only" ]; then
	seed_only=1
	shift
fi
img=${1:?usage: $0 [--seed-only] <ext4 image>}
here=$(cd "$(dirname "$0")" && pwd)

# $img is normally a file, but a block device is accepted too (board tests)
[ -e "$img" ] || { echo "FATAL: no such image: $img" >&2; exit 1; }

typ=$(blkid -p -s TYPE -o value "$img" 2>/dev/null || true)
case "$typ" in
	ext2|ext3|ext4) ;;
	*) echo "FATAL: $img is ${typ:-not a filesystem}, expected ext2/3/4" >&2; exit 1 ;;

esac

# --seed-only: the boot partition carries no files, it only needs the feature
# so that its UUID can be changed while mounted.
seed_feature() {
	tune2fs -O metadata_csum_seed "$1" >/dev/null 2>&1 || true
	dumpe2fs -h "$1" 2>/dev/null | grep -q metadata_csum_seed || {
		echo "FATAL: metadata_csum_seed missing on $1 (tune2fs cannot change a mounted UUID without it)" >&2
		exit 1
	}
}

if [ "$seed_only" = 1 ]; then
	seed_feature "$img"
	e2fsck -fy "$img" >/dev/null 2>&1 || true
	echo "seeded: $img"
	exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir_quiet() { debugfs -w -R "mkdir $1" "$img" >/dev/null 2>&1 || true; }
rm_quiet()    { debugfs -w -R "rm $1"    "$img" >/dev/null 2>&1 || true; }

# debugfs mkdir has no -p: create every prefix, ignore "already exists"
mkdir_p() {
	p=""
	for seg in $(printf '%s' "$1" | tr '/' ' '); do
		p="$p/$seg"
		mkdir_quiet "$p"
	done
}

for d in /usr/lib/p3 /etc/systemd/system/multi-user.target.wants; do
	mkdir_p "$d"
done

put_file() {   # $1 src dir, $2 src name, $3 dest path, $4 mode
	rm_quiet "$3"
	debugfs -w -R "write $1/$2 $3" "$img" >/dev/null 2>&1 || {
		echo "FATAL: could not write $3 into $img" >&2; exit 1
	}
	ino=$(debugfs -R "stat $3" "$img" 2>/dev/null | sed -n 's/^Inode: *\([0-9]*\).*/\1/p')
	[ -n "$ino" ] || { echo "FATAL: $3 missing after write" >&2; exit 1; }
	debugfs -w -R "sif <$ino> mode 0$4" "$img" >/dev/null 2>&1 || true
}

put_file "$here" p3-firstboot.sh /usr/lib/p3/p3-firstboot.sh 100755
put_file "$here" p3-firstboot.service /etc/systemd/system/p3-firstboot.service 100644

link=/etc/systemd/system/multi-user.target.wants/p3-firstboot.service
rm_quiet "$link"
debugfs -w -R "symlink $link /etc/systemd/system/p3-firstboot.service" "$img" >/dev/null 2>&1 || {
	echo "FATAL: could not enable p3-firstboot.service in $img" >&2; exit 1
}

# --- verify by reading back; a debugfs write that did nothing must not pass ---
debugfs -R "cat /usr/lib/p3/p3-firstboot.sh" "$img" 2>/dev/null | cmp -s - "$here/p3-firstboot.sh" || {
	echo "FATAL: p3-firstboot.sh readback does not match the source" >&2; exit 1
}
debugfs -R "cat /etc/systemd/system/p3-firstboot.service" "$img" 2>/dev/null | cmp -s - "$here/p3-firstboot.service" || {
	echo "FATAL: p3-firstboot.service readback does not match the source" >&2; exit 1
}
debugfs -R "stat $link" "$img" 2>/dev/null | grep -q 'Type: symlink' || {
	echo "FATAL: $link is not a symlink" >&2; exit 1
}
mode=$(debugfs -R "stat /usr/lib/p3/p3-firstboot.sh" "$img" 2>/dev/null | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p')
case "$mode" in 0755|0100755) ;; *) echo "FATAL: script mode is ${mode:-?}, expected 0755" >&2; exit 1 ;; esac

seed_feature "$img"
e2fsck -fy "$img" >/dev/null 2>&1 || true
echo "injected: $img"

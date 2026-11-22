#!/bin/bash
#
# P3 first-boot one-shot.
#
# Installed by tools/p3-firstboot-inject.sh into /usr/lib/p3/ and started
# once per freshly flashed system by p3-firstboot.service (WantedBy=
# multi-user.target, gated on /etc/p3-firstboot.done not existing).
#
# Two independent jobs:
#   1. make the box usable with no console interaction:
#      root password -> password, root shell -> bash, and disarm the Armbian
#      first-login wizard (it triggers on /root/.not_logged_in_yet).
#   2. give this installation a unique rootfs/boot UUID, rewrite every
#      reference (extlinux.conf, /etc/fstab), then reboot once.
#
# Why job 2: a CI image is a byte copy of a whole disk. dd'ing it onto a USB
# stick yields a stick whose rootfs UUID is identical to the eMMC it came from,
# and the kernel resolves root=UUID= to whichever device it probes first (the
# eMMC), so "boot from USB" silently boots the eMMC. Unique UUIDs per
# installation remove that collision for good.
#
# Requires the metadata_csum_seed feature on the ext4 filesystems;
# p3-firstboot-inject.sh sets it with tune2fs -O while the image is unmounted.
# That feature is what makes tune2fs -U legal on a mounted filesystem. Without
# it this script rolls back and skips, leaving the system bootable.
#
# Idempotent: /etc/p3-firstboot.done short-circuits every later boot, including
# the failure path, so a bad run cannot loop the box through reboots.

set -u

# Overridable for sandbox testing only; production relies on the defaults.
MARK=${P3_MARK:-/etc/p3-firstboot.done}
LOG=${P3_LOG:-/root/p3-firstboot.log}
DEFAULT_PASS=${P3_PASS:-password}
DEFAULT_SHELL=${P3_SHELL:-/usr/bin/bash}

# A log on a read-only or foreign root must not stop the run: every redirect
# below would fail and take the whole script with it.
mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true
: >>"${LOG}" 2>/dev/null || LOG=/dev/null

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"${LOG}"; }

[ -e "${MARK}" ] && exit 0

log "=== first boot: begin ==="

###############################################################################
# 1. console-free login
###############################################################################
if printf 'root:%s\n' "${DEFAULT_PASS}" | chpasswd 2>>"${LOG}"; then
    log "root password -> default"
else
    log "ERROR: chpasswd failed"
fi

# drop any forced password change / expiry inherited from the image
chage -I -1 -m 0 -M 99999 -E -1 root >/dev/null 2>&1 || true

if usermod -s "${DEFAULT_SHELL}" root 2>>"${LOG}"; then
    log "root shell -> ${DEFAULT_SHELL}"
else
    log "WARNING: usermod -s failed, shell left as is"
fi

if [ -e /root/.not_logged_in_yet ]; then
    rm -f /root/.not_logged_in_yet
    log "first-login wizard disarmed"
fi

###############################################################################
# 2. unique filesystem UUIDs
###############################################################################
dev_of() { findmnt -no SOURCE -T "$1" 2>/dev/null | head -n1; }

if [ -n "${P3_ROOT_DEV:-}" ]; then
    ROOT_DEV="${P3_ROOT_DEV}"
else
    ROOT_DEV=$(dev_of /)
    case "${ROOT_DEV}" in
        ""|/dev/root|rootfs) ROOT_DEV=$(awk '$2=="/" {print $1; exit}' /proc/mounts) ;;
    esac
fi
EXT=${P3_EXT:-/boot/extlinux/extlinux.conf}
FSTAB=${P3_FSTAB:-/etc/fstab}
env=${P3_ENVFILE:-/boot/armbianEnv.txt}
BOOT_DEV=${P3_BOOT_DEV-$(dev_of /boot 2>/dev/null)}

# Sandbox guard: when the test hooks are in use, refuse to touch anything that
# is not a loop device. A stray test run must never reach a real / or /boot.
if [ -n "${P3_MARK:-}" ]; then
    for _d in "${ROOT_DEV}" "${BOOT_DEV}"; do
        case "${_d}" in
            ""|/dev/loop*) ;;
            *) log "SANDBOX: refusing to touch ${_d}"; exit 1 ;;
        esac
    done
fi

check_ext() {   # $1 dev, $2 tag
    local dev="$1" tag="$2" t
    [ -b "${dev}" ] || { log "${tag}: ${dev:-none} not a block device, skip"; return 1; }
    t=$(blkid -s TYPE -o value "${dev}" 2>/dev/null)
    case "${t}" in
        ext2|ext3|ext4) ;;
        *) log "${tag}: fstype=${t:-unknown} is not ext, skip"; return 1 ;;
    esac
    dumpe2fs -h "${dev}" 2>/dev/null | grep -q metadata_csum_seed ||
        { log "${tag}: metadata_csum_seed absent, skip"; return 1; }
    return 0
}

if ! check_ext "${ROOT_DEV}" root; then
    log "no uuid change possible, marking done (system stays bootable)"
    : >"${MARK}"
    exit 0
fi

OLD_ROOT_UUID=$(blkid -s UUID -o value "${ROOT_DEV}")
if [ -z "${OLD_ROOT_UUID}" ]; then
    log "root uuid unreadable, nothing to do"
    : >"${MARK}"
    exit 0
fi

# Find the file that tells the kernel which rootfs to mount.  Usually /boot is
# a mount of its own; some layouts keep extlinux on a partition that is never
# mounted.  Renaming the rootfs UUID without rewriting that file produces a
# machine that cannot boot, so locate it first and skip everything if it is
# not there: not renaming is always safer than booting into a stale cmdline.
PROBE_MNT=/run/p3-firstboot-probe
if { [ -z "${P3_MARK:-}" ] || [ "${P3_ALLOW_PROBE:-0}" = 1 ]; } &&
   [ ! -f "${EXT}" ] && [ -z "${P3_BOOT_DEV:-}" ]; then
    for _d in $(lsblk -rno NAME,TYPE 2>/dev/null | awk '$2=="part"{print "/dev/"$1}'); do
        [ "${_d}" = "${ROOT_DEV}" ] && continue
        case "${_d}" in
            /dev/loop*) ;;
            *) [ -n "${P3_MARK:-}" ] && { log "SANDBOX: refusing probe of ${_d}"; continue; } ;;
        esac
        mkdir -p "${PROBE_MNT}"
        mount -o ro "${_d}" "${PROBE_MNT}" 2>/dev/null || continue
        if [ -f "${PROBE_MNT}/extlinux/extlinux.conf" ] &&
           grep -q "root=UUID=${OLD_ROOT_UUID}" "${PROBE_MNT}/extlinux/extlinux.conf"; then
            EXT="${PROBE_MNT}/extlinux/extlinux.conf"
            env="${PROBE_MNT}/armbianEnv.txt"
            BOOT_DEV="${_d}"
            mount -o remount,rw "${PROBE_MNT}" 2>/dev/null || true
            log "boot config found on ${_d} (that partition is not mounted at /boot)"
            break
        fi
        umount "${PROBE_MNT}" 2>/dev/null || true
    done
fi

if [ ! -f "${EXT}" ]; then
    log "no rewriteable boot config at '${EXT}'; uuid change skipped, system stays bootable"
    : >"${MARK}"
    exit 0
fi

WANT_BOOT=0
if [ "${BOOT_DEV}" != "${ROOT_DEV}" ]; then
    if ! check_ext "${BOOT_DEV}" boot; then
        log "boot fs cannot be renamed; a new root uuid with the old cmdline would not boot, skipped"
        : >"${MARK}"
        exit 0
    fi
    WANT_BOOT=1
fi

NEW_ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
OLD_BOOT_UUID=""
NEW_BOOT_UUID=""
if [ "${WANT_BOOT}" = 1 ]; then
    OLD_BOOT_UUID=$(blkid -s UUID -o value "${BOOT_DEV}")
    NEW_BOOT_UUID=$(cat /proc/sys/kernel/random/uuid)
fi

log "old root=${OLD_ROOT_UUID} boot=${OLD_BOOT_UUID:-none}"
log "new root=${NEW_ROOT_UUID} boot=${NEW_BOOT_UUID:-none}"

cp -a "${FSTAB}" "${FSTAB}.p3bak" 2>/dev/null || true
[ -f "${EXT}" ] && cp -a "${EXT}" "${EXT}.p3bak" 2>/dev/null || true

rollback() {
    log "ROLLBACK: $1"
    [ -f "${FSTAB}.p3bak" ] && cp -a "${FSTAB}.p3bak" "${FSTAB}"
    [ -f "${EXT}.p3bak" ] && cp -a "${EXT}.p3bak" "${EXT}"
    sync
}

# rewrite the references first, the block devices second
fstab_had_root=0
grep -q "UUID=${OLD_ROOT_UUID}" "${FSTAB}" 2>/dev/null && fstab_had_root=1
sed -i "s|UUID=${OLD_ROOT_UUID}|UUID=${NEW_ROOT_UUID}|g" "${FSTAB}" 2>/dev/null
[ -f "${EXT}" ] && sed -i "s|root=UUID=${OLD_ROOT_UUID}|root=UUID=${NEW_ROOT_UUID}|g" "${EXT}"
[ -f "${env}" ] && sed -i "s|UUID=${OLD_ROOT_UUID}|UUID=${NEW_ROOT_UUID}|g" "${env}"
if [ "${WANT_BOOT}" = 1 ]; then
    sed -i "s|UUID=${OLD_BOOT_UUID}|UUID=${NEW_BOOT_UUID}|g" "${FSTAB}"
fi
sync

# Verify the text edits before the block devices move.  A sed that silently
# matched nothing (wrong file, unexpected formatting) followed by a UUID rename
# is an unbootable machine, so treat "not rewritten" as "do not rename".
grep -q "root=UUID=${NEW_ROOT_UUID}" "${EXT}" || {
    rollback "boot cmdline still points at the old uuid"
    : >"${MARK}"
    exit 0
}
if [ "${fstab_had_root}" = 1 ] && ! grep -q "UUID=${NEW_ROOT_UUID}" "${FSTAB}"; then
    rollback "fstab still points at the old root uuid"
    : >"${MARK}"
    exit 0
fi

if [ "${WANT_BOOT}" = 1 ]; then
    if ! tune2fs -U "${NEW_BOOT_UUID}" "${BOOT_DEV}" 2>>"${LOG}"; then
        rollback "boot tune2fs failed"
        : >"${MARK}"
        exit 0
    fi
    log "boot uuid changed"
fi

if ! tune2fs -U "${NEW_ROOT_UUID}" "${ROOT_DEV}" 2>>"${LOG}"; then
    [ "${WANT_BOOT}" = 1 ] && tune2fs -U "${OLD_BOOT_UUID}" "${BOOT_DEV}" 2>>"${LOG}"
    rollback "root tune2fs failed"
    : >"${MARK}"
    exit 0
fi
log "root uuid changed"

sync
case "${EXT}" in "${PROBE_MNT}"/*) umount "${PROBE_MNT}" 2>/dev/null || true ;; esac
: >"${MARK}"
log "=== first boot: done, rebooting once ==="
sync
if [ "${P3_NO_REBOOT:-0}" = 1 ]; then
    log "P3_NO_REBOOT=1, reboot skipped (sandbox mode)"
else
    wall "P3 first-boot setup finished, rebooting once." 2>/dev/null || true
    systemctl reboot 2>/dev/null || /sbin/reboot
fi

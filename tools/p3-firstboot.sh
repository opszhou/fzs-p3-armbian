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

WANT_BOOT=0
if [ -n "${BOOT_DEV}" ] && [ "${BOOT_DEV}" != "${ROOT_DEV}" ] && check_ext "${BOOT_DEV}" boot; then
    WANT_BOOT=1
fi

OLD_ROOT_UUID=$(blkid -s UUID -o value "${ROOT_DEV}")
NEW_ROOT_UUID=$(cat /proc/sys/kernel/random/uuid)
OLD_BOOT_UUID=""
NEW_BOOT_UUID=""
if [ "${WANT_BOOT}" = 1 ]; then
    OLD_BOOT_UUID=$(blkid -s UUID -o value "${BOOT_DEV}")
    NEW_BOOT_UUID=$(cat /proc/sys/kernel/random/uuid)
fi

log "old root=${OLD_ROOT_UUID} boot=${OLD_BOOT_UUID:-none}"
log "new root=${NEW_ROOT_UUID} boot=${NEW_BOOT_UUID:-none}"

EXT=${P3_EXT:-/boot/extlinux/extlinux.conf}
FSTAB=${P3_FSTAB:-/etc/fstab}
env=${P3_ENVFILE:-/boot/armbianEnv.txt}

cp -a "${FSTAB}" "${FSTAB}.p3bak" 2>/dev/null || true
[ -f "${EXT}" ] && cp -a "${EXT}" "${EXT}.p3bak" 2>/dev/null || true

rollback() {
    log "ROLLBACK: $1"
    [ -f "${FSTAB}.p3bak" ] && cp -a "${FSTAB}.p3bak" "${FSTAB}"
    [ -f "${EXT}.p3bak" ] && cp -a "${EXT}.p3bak" "${EXT}"
    sync
}

# rewrite the references first, the block devices second
sed -i "s|UUID=${OLD_ROOT_UUID}|UUID=${NEW_ROOT_UUID}|g" "${FSTAB}" 2>/dev/null
[ -f "${EXT}" ] && sed -i "s|root=UUID=${OLD_ROOT_UUID}|root=UUID=${NEW_ROOT_UUID}|g" "${EXT}"
[ -f "${env}" ] && sed -i "s|UUID=${OLD_ROOT_UUID}|UUID=${NEW_ROOT_UUID}|g" "${env}"
if [ "${WANT_BOOT}" = 1 ]; then
    sed -i "s|UUID=${OLD_BOOT_UUID}|UUID=${NEW_BOOT_UUID}|g" "${FSTAB}"
fi
sync

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
: >"${MARK}"
log "=== first boot: done, rebooting once ==="
sync
if [ "${P3_NO_REBOOT:-0}" = 1 ]; then
    log "P3_NO_REBOOT=1, reboot skipped (sandbox mode)"
else
    wall "P3 first-boot setup finished, rebooting once." 2>/dev/null || true
    systemctl reboot 2>/dev/null || /sbin/reboot
fi

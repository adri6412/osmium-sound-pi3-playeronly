#!/bin/sh
# Osmium Sound (Raspberry Pi 3B) — RAUC bundle hook (travels inside the signed
# bundle).
#
#   install-check      reject the bundle if it is not for this hardware or if
#                      the device does not have the A/B layout (data partition).
#   slot-post-install  after the slot is written: lift the slot's kernel,
#                      initramfs and DTB onto the FAT boot partition, so U-Boot
#                      can load the slot (it cannot read the squashfs itself).
set -eu

case "${1:-}" in
install-check)
    if [ "${RAUC_MF_COMPATIBLE:-}" != "${RAUC_SYSTEM_COMPATIBLE:-}" ]; then
        echo "Image for '${RAUC_MF_COMPATIBLE:-?}', device '${RAUC_SYSTEM_COMPATIBLE:-?}'" >&2
        exit 10
    fi
    # The A/B layout needs the data partition (p4). On this fork the table is
    # MBR (the Pi3 GPU bootrom reads only MBR), so there are no GPT PARTLABELs to
    # test for: resolve the root disk and check it has a 4th partition. Done
    # inline (no sourcing hifi-ab-lib.sh) to stay self-contained in RAUC's
    # minimal install-check environment.
    root=$(findmnt -no SOURCE / 2>/dev/null || true)
    case "$root" in
    /dev/*)
        rn=${root#/dev/}
        disk=$(basename "$(readlink -f "/sys/class/block/$rn/.." 2>/dev/null)" 2>/dev/null || true)
        ;;
    *) disk= ;;
    esac
    have_data=
    if [ -n "$disk" ]; then
        for s in /sys/class/block/"$disk"*; do
            [ -f "$s/partition" ] || continue
            if [ "$(cat "$s/partition" 2>/dev/null)" = 4 ]; then
                have_data=1
                break
            fi
        done
    fi
    if [ -z "$have_data" ]; then
        echo "Data partition (p4) missing: device is not on the A/B layout" >&2
        exit 11
    fi
    ;;
slot-post-install)
    case "${RAUC_SLOT_CLASS:-}" in
    rootfs)
        dev="${RAUC_SLOT_DEVICE:?}"
        bootname="${RAUC_SLOT_BOOTNAME:?}"
        type=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
        if [ "$type" = squashfs ]; then
            # The boot partition is this fork's "ESP": Debian mounts it at
            # /boot/firmware. Make sure it is mounted before copying onto it.
            fw=/boot/firmware
            mountpoint -q "$fw" || mount "$fw" 2>/dev/null || true
            mountpoint -q "$fw" || { echo "post-install: $fw is not mounted" >&2; exit 1; }
            mnt=$(mktemp -d)
            mount -t squashfs -o ro "$dev" "$mnt" \
                || { rmdir "$mnt"; echo "post-install: cannot mount new slot $dev" >&2; exit 1; }
            # The slot ships exactly one kernel (build-image.sh keeps the newest).
            kver=$(ls -1 "$mnt"/boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)
            rc=0
            if [ -n "$kver" ] && [ -f "$mnt/boot/initrd.img-$kver" ]; then
                install -m 0644 "$mnt/boot/vmlinuz-$kver"    "$fw/vmlinuz-$bootname"   || rc=1
                install -m 0644 "$mnt/boot/initrd.img-$kver" "$fw/initramfs-$bootname" || rc=1
                # Shared DTB (same hardware for both slots); refresh it to the
                # slot being installed. The Pi3 board DTB is stable across
                # kernels, so a rollback to the other slot still boots with it.
                _dtb="$mnt/usr/lib/linux-image-$kver/broadcom/bcm2837-rpi-3-b.dtb"
                [ -f "$_dtb" ] && install -m 0644 "$_dtb" "$fw/bcm2837-rpi-3-b.dtb"
            else
                echo "post-install: no kernel/initrd in the new slot" >&2
                rc=1
            fi
            sync
            umount "$mnt" 2>/dev/null || true
            rmdir "$mnt" 2>/dev/null || true
            [ "$rc" = 0 ] || exit 1
        elif [ "$type" = ext4 ]; then
            # Defensive: an ext4 slot (not expected here) gets a fresh UUID.
            e2fsck -fy "$dev" >/dev/null 2>&1 || true
            tune2fs -U random "$dev" >/dev/null 2>&1 || echo "warning: tune2fs -U on $dev failed (non-fatal)" >&2
        fi
        ;;
    esac
    ;;
*)
    exit 1
    ;;
esac
exit 0

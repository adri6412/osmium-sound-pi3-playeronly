#!/usr/bin/env bash
#
# build-image-pi3.sh — a flashable SD-card image for the Raspberry Pi 3B from a
# rootfs.squashfs produced by build-pi3.sh. Same A/B layout idea as the x86
# build-usb-image.sh, but with the Pi boot chain instead of GRUB:
#
#   sudo ./build-image-pi3.sh --rootfs osmium-pi3-2.6.0-pi.1.rootfs.squashfs \
#                             --out osmium-pi3-2.6.0-pi.1.img
#
# What comes out (write it with dd / Raspberry Pi Imager / Etcher):
#   p1  FAT32  (boot)   Pi GPU firmware + u-boot.bin + config.txt + boot.scr +
#                       uboot.env + vmlinuz-A/initramfs-A + the board DTB.
#                       Debian mounts it at /boot/firmware.
#   p2  raw    (root-a) slot A: the rootfs.squashfs, block for block.
#   p3  raw    (root-b) slot B: empty, filled by the first RAUC update.
#   p4  ext4*  (data)   16 MiB seed; the initramfs grows it to fill the card and
#                       formats it as ext4 "hifi-data".
#
# The GPU firmware reads config.txt and loads u-boot.bin as the "kernel"; U-Boot
# runs boot.scr (compiled from distro/uboot/boot.cmd), reads BOOT_ORDER /
# BOOT_<slot>_LEFT from uboot.env and boots the chosen slot with rauc.slot=<A|B>
# (see boot.cmd). On a good boot `rauc status mark-good` resets the counter.
#
# 🚨 MBR (msdos), not GPT: the Pi1/2/3 GPU bootrom reads only an MBR partition
# table. On a GPT disk it sees just the protective-MBR 0xEE entry, finds no FAT
# and never boots (red LED, no ACT); it is also why Windows hides a GPT ESP-type
# p1 from Explorer. So p1 is a primary FAT32-LBA (type 0x0c, bootable) and the
# partitions carry no GPT names — the runtime resolves them by their fixed
# number on the root disk (hifi-ab-lib.sh: boot=p1, root-a=p2, root-b=p3,
# data=p4). GPT would only be safe on a Pi4 (recent EEPROM) or Pi5.
#
# Needs root; host tools: sfdisk, losetup (partscan), mkfs.vfat (dosfstools),
# mkimage + mkenvimage (u-boot-tools), unsquashfs or mount for squashfs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/config/includes.chroot/usr/local/sbin/hifi-ab-lib.sh"
UBOOT_DIR="$SCRIPT_DIR/uboot"
ROOTFS=""
OUT=""
DATA_SEED_MIB=16
BOOT_MIB=512
# The whole Pi3 DTB family ships on the FAT (3-b, 3-b-plus, 3-a-plus): the board
# model is not known at build time and the 3B+ needs its own DTB (USB/LAN hub,
# power GPIO expander, different Wi-Fi/BT) — the plain 3B DTB hangs it. Each is
# also copied under the downstream name the GPU firmware / U-Boot auto-load by
# board revision (bcm2837-rpi-3-* → bcm2710-rpi-3-*), the same alias the Debian
# raspi-firmware package creates. Mainline kernel DTB glob and the alias prefix:
DTB_GLOB="bcm2837-rpi-3-*.dtb"
DTB_ALIAS_FROM="bcm2837-rpi-3-"
DTB_ALIAS_TO="bcm2710-rpi-3-"

log() { printf '\033[1;36m[hifi-pi3-image]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[hifi-pi3-image ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --uboot-dir) UBOOT_DIR="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ "$(id -u)" -eq 0 ] || die "needs root"
[ -f "$ROOTFS" ] || die "--rootfs: no such file: $ROOTFS"
[ -n "$OUT" ] || die "--out missing"
[ -f "$UBOOT_DIR/config.txt" ] || die "missing $UBOOT_DIR/config.txt"
[ -f "$UBOOT_DIR/boot.cmd" ]   || die "missing $UBOOT_DIR/boot.cmd"
# shellcheck source=distro/config/includes.chroot/usr/local/sbin/hifi-ab-lib.sh
# shellcheck disable=SC1091
. "$LIB"
for t in losetup sfdisk mount umount truncate mkfs.vfat mkimage mkenvimage; do
    command -v "$t" >/dev/null || die "$t missing on the build host"
done

img_bytes=$(stat -c %s "$ROOTFS")
[ "$img_bytes" -le $(( AB_SLOT_B_MIB * 1048576 )) ] \
    || die "the system image ($(( img_bytes / 1048576 )) MiB) does not fit a ${AB_SLOT_B_MIB} MiB slot"

WORK="$(mktemp -d "${IMAGE_WORK:-/var/tmp}/hifi-pi3-image.XXXXXX")"
MNT_SQ="$WORK/slotA"; MNT_BOOT="$WORK/boot"
mkdir -p "$MNT_SQ" "$MNT_BOOT"
LOOP=""
cleanup() {
    set +e
    for m in "$MNT_BOOT" "$MNT_SQ"; do mountpoint -q "$m" && umount -R "$m" 2>/dev/null; done
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── 1. the empty disk and its MBR ────────────────────────────────────────
# 1 MiB alignment in front, 1 MiB slack behind. hifi-data (p4) is a 16 MiB seed
# grown to fill the card on first boot. An MBR (msdos) table, NOT GPT: the Pi3
# GPU bootrom reads only MBR (see the header). p1 is a bootable FAT32-LBA
# (type 0x0c) primary so the firmware finds it and Windows mounts it; p2/p3/p4
# are Linux (type 0x83). A fixed disk id keeps PARTUUIDs stable across builds.
total_mib=$(( 1 + BOOT_MIB + AB_SLOT_B_MIB * 2 + DATA_SEED_MIB + 1 ))
log "disk image: ${total_mib} MiB (boot ${BOOT_MIB}, slots ${AB_SLOT_B_MIB} each, system image $(( img_bytes / 1048576 )) MiB)"
rm -f "$OUT"
truncate -s "${total_mib}M" "$OUT"
printf 'label: dos\nlabel-id: 0x0a5e0501\nsize=%sMiB, type=0c, bootable\nsize=%sMiB, type=83\nsize=%sMiB, type=83\nsize=%sMiB, type=83\n' \
    "$BOOT_MIB" "$AB_SLOT_B_MIB" "$AB_SLOT_B_MIB" "$DATA_SEED_MIB" \
    | sfdisk --quiet "$OUT" || die "sfdisk failed"

# ── 2. attach as a loop device, partitions included ──────────────────────
mknod_missing() {
    _n=$(basename "$1"); [ -b "/dev/$_n" ] && return 0
    _mm=$(cat "$1/dev"); mknod "/dev/$_n" b "${_mm%%:*}" "${_mm##*:}"
}
if ! LOOP=$(losetup --find --show --partscan "$OUT" 2>/dev/null); then
    for i in $(seq 0 63); do [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i"; done
    LOOP=$(losetup --find --show --partscan "$OUT") || die "no free loop device"
fi
ln=$(basename "$LOOP")
for i in $(seq 1 20); do
    [ -d "/sys/block/$ln/${ln}p4" ] && break
    partx -a "$LOOP" 2>/dev/null || true; sleep 0.5
done
[ -d "/sys/block/$ln/${ln}p4" ] || die "the kernel did not pick up the partitions of $LOOP"
for p in /sys/block/"$ln"/"$ln"p*; do mknod_missing "$p"; done
log "attached as $LOOP"

# ── 3. slot A: the system image, block for block ─────────────────────────
log "writing the system image into slot A (p2)"
dd if="$ROOTFS" of="${LOOP}p2" bs=4M conv=fsync status=none || die "writing slot A failed"

# ── 4. lift the Pi boot files OUT of slot A (U-Boot cannot read squashfs) ─
mount -t squashfs -o ro "${LOOP}p2" "$MNT_SQ" || die "slot A does not mount as squashfs"
img_ver=$(head -n 1 "$MNT_SQ/usr/lib/osmium/IMAGE_VERSION" 2>/dev/null || true)
[ -n "$img_ver" ] || die "$ROOTFS is not an Osmium system image (no IMAGE_VERSION)"
kver=$(ls -1 "$MNT_SQ"/boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n 1)
[ -n "$kver" ] || die "no kernel in slot A"
UBOOT_BIN="$MNT_SQ/usr/lib/u-boot/rpi_arm64/u-boot.bin"
[ -f "$UBOOT_BIN" ] || UBOOT_BIN="$MNT_SQ/usr/lib/u-boot/rpi_3/u-boot.bin"
[ -f "$UBOOT_BIN" ] || die "u-boot.bin not found in slot A (u-boot-rpi not installed?)"
FW_DIR="$MNT_SQ/usr/lib/raspi-firmware"
[ -d "$FW_DIR" ] || die "Pi GPU firmware (raspi-firmware) not found in slot A"
DTB_DIR="$MNT_SQ/usr/lib/linux-image-$kver/broadcom"
[ -d "$DTB_DIR" ] || DTB_DIR="$MNT_SQ/boot"
# shellcheck disable=SC2086
set -- "$DTB_DIR"/$DTB_GLOB
[ -f "$1" ] || die "no Pi3 DTB ($DTB_GLOB) found in slot A under $DTB_DIR"
log "image $img_ver, kernel $kver"

# ── 5. the FAT boot partition ────────────────────────────────────────────
log "formatting and filling the FAT boot partition (p1 = hifi-boot)"
mkfs.vfat -F32 -n HIFIBOOT "${LOOP}p1" >/dev/null || die "mkfs.vfat failed"
mount -t vfat "${LOOP}p1" "$MNT_BOOT" || die "the boot partition does not mount"

# Pi GPU firmware (bootcode.bin / start*.elf / fixup*.dat) and U-Boot as kernel.
cp "$FW_DIR"/*.bin "$FW_DIR"/*.elf "$FW_DIR"/*.dat "$MNT_BOOT/" 2>/dev/null || true
install -m 0644 "$UBOOT_BIN" "$MNT_BOOT/u-boot.bin"
install -m 0644 "$UBOOT_DIR/config.txt" "$MNT_BOOT/config.txt"

# boot.scr: the compiled A/B selector (boot.cmd).
mkimage -A arm64 -O linux -T script -C none -n "Osmium A/B" \
    -d "$UBOOT_DIR/boot.cmd" "$MNT_BOOT/boot.scr" >/dev/null || die "mkimage (boot.scr) failed"

# Per-slot kernel/initramfs for slot A; the shared board DTB. Slot B's copies
# are written by the RAUC post-install hook when the first update lands there.
install -m 0644 "$MNT_SQ/boot/vmlinuz-$kver"    "$MNT_BOOT/vmlinuz-A"
install -m 0644 "$MNT_SQ/boot/initrd.img-$kver" "$MNT_BOOT/initramfs-A"
# Every Pi3 DTB, under its own name and under the downstream alias the firmware
# auto-loads by board revision. start.elf then builds the FDT for the real board
# (3B / 3B+ / 3A+) and hands it to U-Boot, which boots with it (see boot.cmd).
# shellcheck disable=SC2086
for dtb in "$DTB_DIR"/$DTB_GLOB; do
    base=$(basename "$dtb")
    install -m 0644 "$dtb" "$MNT_BOOT/$base"
    alias_name="${base/#$DTB_ALIAS_FROM/$DTB_ALIAS_TO}"
    [ "$alias_name" = "$base" ] || install -m 0644 "$dtb" "$MNT_BOOT/$alias_name"
    log "DTB $base (+ alias $alias_name)"
done

# The initial U-Boot environment. 🚨 This must be a COMPLETE env, not just the
# RAUC counters: rpi_arm64 u-boot is CONFIG_ENV_IS_IN_FAT and reads this file,
# and a saved env REPLACES u-boot's built-in default env wholesale. With only
# BOOT_* in it, u-boot would have no `bootcmd` (autoboot runs nothing — the GPU
# rainbow splash never clears) and none of the load addresses boot.cmd needs
# (fatload/booti would get empty ${kernel_addr_r} etc.). So we seed bootcmd
# (which sources boot.scr, the A/B selector), the standard Pi load addresses,
# and the counters. fw_setenv / RAUC rewrite BOOT_ORDER / BOOT_<slot>_LEFT at
# runtime; boot.cmd's `saveenv` preserves the rest.
# 🚨 The 0x4000 size must match fw_env.config and the U-Boot CONFIG_ENV_SIZE.
cat > "$WORK/uboot.env.txt" <<'ENV'
bootdelay=0
scriptaddr=0x02400000
kernel_addr_r=0x00080000
ramdisk_addr_r=0x02700000
fdt_addr_r=0x02600000
fdt_high=0xffffffffffffffff
initrd_high=0xffffffffffffffff
bootcmd=fatload mmc 0:1 ${scriptaddr} boot.scr && source ${scriptaddr}
BOOT_ORDER=A B
BOOT_A_LEFT=3
BOOT_B_LEFT=3
ENV
mkenvimage -s 0x4000 -o "$MNT_BOOT/uboot.env" "$WORK/uboot.env.txt" || die "mkenvimage failed"

sync
log "boot partition contents:"
ls -1 "$MNT_BOOT" | sed 's/^/  /'
umount "$MNT_BOOT"
umount "$MNT_SQ"
losetup -d "$LOOP"; LOOP=""

# ── 6. sanity: the MBR partition types, in order ─────────────────────────
# MBR has no partition names; check the four partitions are there in order with
# the right types: p1 FAT32-LBA (c), p2/p3/p4 Linux (83). sfdisk -d lists them
# in on-disk order, one "... : ... type=<hex> ..." line each.
types=$(sfdisk -d "$OUT" | sed -n 's/.*: .*type=\([0-9A-Fa-f]\{1,2\}\).*/\1/p' | tr 'A-F' 'a-f' | tr '\n' ',')
[ "$types" = "c,83,83,83," ] \
    || die "unexpected MBR partition table: $types (want c,83,83,83,)"
log "DONE ✓  $OUT ($img_ver, ${total_mib} MiB)"

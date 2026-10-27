#!/usr/bin/env bash
#
# build-pi3.sh — build the Osmium Sound (Raspberry Pi 3B, arm64, player-only)
# system image: an arm64 Debian trixie rootfs with the appliance payload, turned
# into the read-only rootfs.squashfs that goes into a RAUC A/B slot, plus the
# signed RAUC bundle (.raucb) used to update a running device.
#
# This is the arm64 counterpart of build-distro.sh + build-image.sh combined.
# Unlike the x86 flow it does NOT use live-build (there is no live ISO here) and
# it has NO GRUB: the Pi boots through its GPU firmware -> U-Boot -> boot.scr
# (see distro/uboot/ and boot.cmd). The disk .img is assembled separately by
# build-image-pi3.sh from the rootfs.squashfs this script produces.
#
#   sudo ./build-pi3.sh --version 2.6.0-pi.1 \
#        --cert ../rauc-keys/cert.pem --key ../rauc-keys/key.pem
#
# Run it on an arm64 Debian host (native, no emulation) or on an x86 host with
# qemu-user-static + binfmt registered for aarch64 (slower). The CI workflow
# (.github/workflows/build-pi3-image.yml) runs it on a native arm64 runner.
#
# Needs root. Host tools: debootstrap, mksquashfs, rauc, mkfs.vfat is NOT needed
# here (that is build-image-pi3.sh). The Qt payload (/opt/hifi-qt/hifi-qt) must
# already be present under config/includes.chroot, cross-built for arm64 by
# ci/build-payload.sh — this script refuses to build an image without it, just
# as hook 0300 does, because an image with no interface is a black screen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$SCRIPT_DIR/config"
VERSION="${IMAGE_VERSION:-}"
OUT="${IMAGE_OUT:-$REPO_ROOT}"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
ARCH=arm64
CERT="${RAUC_CERT:-}"
KEY="${RAUC_KEY:-}"
KEYRING="${RAUC_KEYRING:-$SCRIPT_DIR/rauc-keys/keyring.pem}"
NO_BUNDLE=0
KEEP_ROOTFS=0
CHROOT_KEEP=""
SLOT_MIB="${AB_SLOT_B_MIB:-1280}"   # smallest slot; the squashfs must fit with margin
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || date +%s)}"

log() { printf '\033[1;36m[hifi-pi3]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[hifi-pi3 ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --suite) SUITE="$2"; shift 2 ;;
        --mirror) MIRROR="$2"; shift 2 ;;
        --cert) CERT="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --keyring) KEYRING="$2"; shift 2 ;;
        --no-bundle) NO_BUNDLE=1; KEEP_ROOTFS=1; shift ;;
        --keep-rootfs) KEEP_ROOTFS=1; shift ;;
        --keep-chroot) CHROOT_KEEP="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "needs root"
[ -n "$VERSION" ] || die "--version missing"
[ "$SUITE" = trixie ] || log "WARNING: suite=$SUITE (trixie is the tested base: labwc/Qt6 need Debian 13)"
command -v debootstrap >/dev/null || die "debootstrap missing on the build host"
command -v mksquashfs  >/dev/null || die "mksquashfs (squashfs-tools) missing on the build host"
[ "$NO_BUNDLE" = 1 ] || command -v rauc >/dev/null || die "rauc missing on the build host (or pass --no-bundle)"
[ -f "$KEYRING" ] || die "RAUC keyring missing: $KEYRING"
[ -x "$CONFIG/includes.chroot/opt/hifi-qt/hifi-qt" ] \
    || die "config/includes.chroot/opt/hifi-qt/hifi-qt missing or not executable: cross-build the arm64 payload with ci/build-payload.sh first"
# A quick sanity check that the payload really is arm64 and not an x86 build
# left over from a desktop test: an aarch64 ELF has 0xB7 at byte 18 (e_machine).
if command -v od >/dev/null; then
    _mach=$(od -An -tu1 -j18 -N1 "$CONFIG/includes.chroot/opt/hifi-qt/hifi-qt" | tr -d ' ')
    [ "$_mach" = 183 ] || die "config/includes.chroot/opt/hifi-qt/hifi-qt is not an aarch64 ELF (e_machine=$_mach, want 183): wrong-arch payload"
fi
mkdir -p "$OUT"

PKGLIST="$CONFIG/package-lists/hifi-pi3.list.chroot"
[ -f "$PKGLIST" ] || die "missing $PKGLIST"
SHARE_SRC="$CONFIG/includes.chroot/usr/local/sbin/hifi-ab-lib.sh"
lib_slot=$(sed -n 's/^AB_SLOT_B_MIB="\${AB_SLOT_B_MIB:-\([0-9]*\)}"/\1/p' "$SHARE_SRC" 2>/dev/null | head -n 1)
[ -z "$lib_slot" ] || [ "$lib_slot" = "$SLOT_MIB" ] \
    || die "slot size mismatch: build-pi3=$SLOT_MIB, hifi-ab-lib.sh=$lib_slot"

WORK="$(mktemp -d "${IMAGE_WORK:-/var/tmp}/hifi-pi3.XXXXXX")"
CH="$WORK/chroot"
cleanup() {
    set +e
    for m in "$CH/run" "$CH/dev/pts" "$CH/dev" "$CH/sys" "$CH/proc"; do
        mountpoint -q "$m" && umount -R "$m" 2>/dev/null
    done
    [ -n "$CHROOT_KEEP" ] && [ -d "$CH" ] && { rm -rf "$CHROOT_KEEP"; cp -a "$CH" "$CHROOT_KEEP"; }
    rm -rf "$WORK"
}
trap cleanup EXIT

in_chroot() {
    chroot "$CH" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C.UTF-8 LANG=C.UTF-8 HOME=/root DEBIAN_FRONTEND=noninteractive "$@"
}

# ── 1. base system (debootstrap, arm64) ──────────────────────────────────
log "debootstrap $SUITE/$ARCH into the build chroot"
# --foreign is only needed when there is no aarch64 binfmt handler; on a native
# arm64 host (the CI runner) a plain debootstrap works and is much faster. We
# pick the path from whether we can execute an arm64 binary.
if [ "$(uname -m)" = "aarch64" ]; then
    debootstrap --arch="$ARCH" --variant=minbase \
        --components=main,contrib,non-free,non-free-firmware \
        "$SUITE" "$CH" "$MIRROR" 2>&1 | tail -n 5 || die "debootstrap failed"
else
    command -v qemu-aarch64-static >/dev/null \
        || die "cross build needs qemu-aarch64-static + binfmt (install qemu-user-static)"
    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        --components=main,contrib,non-free,non-free-firmware \
        "$SUITE" "$CH" "$MIRROR" 2>&1 | tail -n 5 || die "debootstrap (stage 1) failed"
    cp "$(command -v qemu-aarch64-static)" "$CH/usr/bin/"
    in_chroot /debootstrap/debootstrap --second-stage 2>&1 | tail -n 5 || die "debootstrap (stage 2) failed"
fi

# apt sources with the same areas live-build gives the x86 image.
cat > "$CH/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

mount -t proc proc "$CH/proc"
mount -t sysfs sys "$CH/sys"
mount --bind /dev "$CH/dev"
mount -t devpts devpts "$CH/dev/pts" 2>/dev/null || true
mount -t tmpfs tmpfs "$CH/run"
# Keep services from being started by their postinst inside the chroot.
printf '#!/bin/sh\nexit 101\n' > "$CH/usr/sbin/policy-rc.d"; chmod +x "$CH/usr/sbin/policy-rc.d"
cp -a "$CH/etc/resolv.conf" "$WORK/resolv.conf.orig" 2>/dev/null || true
cp -L /etc/resolv.conf "$CH/etc/resolv.conf" 2>/dev/null || true

in_chroot apt-get -q update 2>&1 | tail -n 3 || die "apt update failed"
in_chroot apt-get -y -q install eatmydata >/dev/null 2>&1 || true

# ── 2. the appliance package set (arm64 list) + essentials ────────────────
log "installing the Pi3 package set"
# One package per line, comments and blank lines dropped (same contract as the
# live-build list header).
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$PKGLIST")
in_chroot apt-get -y -q --no-install-recommends install \
    locales ca-certificates "${PKGS[@]}" 2>&1 | tail -n 15 \
    || die "installing the package set failed"
in_chroot dpkg -s busybox >/dev/null 2>&1 \
    || die "busybox missing in the chroot: the initrd would have no grep/sed/cp"
in_chroot dpkg -s raspi-firmware >/dev/null 2>&1 \
    || die "raspi-firmware missing: the Pi GPU firmware would not be on the boot partition"
in_chroot dpkg -s linux-image-arm64 >/dev/null 2>&1 \
    || die "linux-image-arm64 missing: no kernel"

# ── 3. the appliance payload (config/includes.chroot overlaid onto /) ─────
log "overlaying config/includes.chroot"
# tar preserves modes/symlinks; the repo has core.filemode=false so the exec
# bits are reasserted below (same as hook 0300 / build-image.sh §6).
tar -C "$CONFIG/includes.chroot" -cf - . | tar -C "$CH" -xf -

# The Python daemons live at the repo root (single source of truth, where the
# player-only edits are made) and are injected into /usr/local/bin here, exactly
# as the x86 build-distro.sh does into includes.chroot. Without this the units
# (hifi-api/hifi-webui/hifi-sources/hifi-vumeter) point at /usr/local/bin/*.py
# files that never got shipped, so every service fails on boot: no setup wizard,
# "the APIs don't respond". Bare `import hifi_*` means every shared module must
# sit beside them in the same dir.
log "injecting python daemons → /usr/local/bin"
BIN_DEST="$CH/usr/local/bin"
mkdir -p "$BIN_DEST"
for py in api_server.py vu_meter_daemon.py sources_server.py webui_server.py \
          hifi_logging.py hifi_backup.py hifi_i18n.py hifi_metadata.py \
          hifi_tags.py hifi_squeezelite.py hifi_cdrip.py hifi_signal_path.py \
          hifi_diskguard.py; do
    [ -f "$REPO_ROOT/$py" ] || die "python daemon missing from repo root: $py"
    cp -f "$REPO_ROOT/$py" "$BIN_DEST/$py"
    sed -i 's/\r$//' "$BIN_DEST/$py"
done
# Explicit 0755, not `chmod +x`: under the build umask (0077) `+x` only sets the
# owner bit, leaving the file -rwx------ root. hifi-vumeter runs vu_meter_daemon.py
# as User=hifi, and the bare `import hifi_*` modules beside it must be readable by
# that user too, so every injected .py must be world-readable (the chmod of all
# /usr/local/bin/*.py below enforces this for the imported modules as well).
chmod 0755 "$BIN_DEST/api_server.py" "$BIN_DEST/vu_meter_daemon.py" \
         "$BIN_DEST/sources_server.py" "$BIN_DEST/webui_server.py"

# ── 4. chroot hooks — a Pi-safe ALLOWLIST ─────────────────────────────────
# Only the arch-neutral, player-relevant hooks run. Deliberately skipped:
#   0200-hidden-boot        GRUB/x86 boot finalisation (no GRUB on the Pi)
#   0420-broadcom-wl        builds the BCM4360 wl DKMS driver (an x86 card)
#   0440-surface-ipts       Microsoft Surface touch (x86 tablet)
#   0450-purge-raspi-firmware  removes raspi-firmware — FATAL here, we need it
#   0410-tailscale          optional VPN; left out of the base image
#   0430-sox-ng             builds sox-ng from source (DSP); deferred on the Pi
#   0500-brand-boot.*.binary  live-build ISO stage hook (no ISO here)
log "running the Pi-safe chroot hooks"
for h in 0100-system-setup 0300-app-install 0400-enable-services; do
    f="$CONFIG/hooks/normal/$h.hook.chroot"
    [ -f "$f" ] || die "expected hook missing: $f"
    log "  hook $h"
    cp "$f" "$CH/tmp/hook.sh"; chmod +x "$CH/tmp/hook.sh"
    in_chroot /tmp/hook.sh 2>&1 | tail -n 8 || die "hook $h failed"
    rm -f "$CH/tmp/hook.sh"
done

# ── 5. image post-processing (adapted from build-image.sh, no GRUB) ───────
log "image post-processing: strip live markers, enable A/B units"
rm -f "$CH/etc/kernel/postinst.d/zzz-hifi-fix-efi-boot" \
      "$CH/etc/apt/apt.conf.d/99-hifi-fix-efi-boot"
rm -f "$CH/etc/systemd/system/hifi-firstboot.service" "$CH"/etc/systemd/system/*.wants/hifi-firstboot.service
rm -f "$CH/etc/hifi-player/OS_VERSION" "$CH/etc/hifi-player/SYSTEM_VERSION" \
      "$CH/etc/hifi-player/UI_VERSION" "$CH/etc/hifi-player/provisioning-pending"
rm -f "$CH/etc/rauc/system.conf"   # regenerated per-boot by hifi-rauc-config

# Player-only: no bundled Lyrion to symlink/enable; just the A/B boot units.
mkdir -p "$CH/data"
in_chroot systemctl enable hifi-rauc-config.service hifi-boot-health.service \
    hifi-boot-watchdog.timer hifi-ab-firstboot.service >/dev/null 2>&1 || true
in_chroot systemctl disable hifi-ab-finish.service >/dev/null 2>&1 || true

# Fixed-UID users and the state directories (same as build-image.sh §4).
in_chroot systemd-sysusers >/dev/null 2>&1 || die "systemd-sysusers failed"
in_chroot id squeezeboxserver >/dev/null || die "squeezeboxserver user not created"
for d in var/lib/squeezeboxserver var/lib/squeezeboxserver/prefs var/lib/squeezeboxserver/cache \
         var/lib/squeezeboxserver/playlists var/log/squeezeboxserver; do
    mkdir -p "$CH/$d"; in_chroot chown squeezeboxserver:nogroup "/$d"
done
in_chroot chown hifimusic:hifishare /var/lib/squeezeboxserver/playlists
in_chroot chmod 2775 /var/lib/squeezeboxserver/playlists
mkdir -p "$CH/var/lib/hifi-player" "$CH/var/log/hifi" "$CH/mnt" "$CH/media"

# RAUC keyring + version markers outside /etc (so an /etc overlay cannot hide
# them). NBD module for `rauc install https://…` streaming.
mkdir -p "$CH/etc/rauc" "$CH/usr/lib/osmium" "$CH/etc/modules-load.d"
install -m 0644 "$KEYRING" "$CH/etc/rauc/keyring.pem"
printf '# Osmium Sound: RAUC bundle streaming (rauc install https://...)\nnbd\n' \
    > "$CH/etc/modules-load.d/hifi-rauc.conf"
printf '%s\n' "$VERSION" > "$CH/usr/lib/osmium/IMAGE_VERSION"
KVER=$(find "$CH/boot" -maxdepth 1 -name 'vmlinuz-*' | sed 's|.*/vmlinuz-||' | sort -V | tail -n 1)
[ -n "$KVER" ] || die "no kernel in $CH/boot"
{
    echo "version=$VERSION"
    echo "built=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
    echo "git=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$KVER"
    echo "arch=$ARCH"
    echo "board=raspberry-pi-3b"
} > "$CH/usr/lib/osmium/BUILD_INFO"
# shellcheck disable=SC2016
in_chroot dpkg-query -W -f='${Package}\t${Version}\n' | sort > "$CH/usr/lib/osmium/packages.txt"
cp "$CH/var/lib/dpkg/status" "$CH/usr/lib/osmium/dpkg-status"

# SYSEXT_LEVEL pins an add-on to this exact image: hifi-ext.sh writes it into an
# add-on's extension-release, and systemd-sysext merges the extension only when
# the host os-release declares the SAME SYSEXT_LEVEL. Debian's own os-release has
# no SYSEXT_LEVEL, only VERSION_ID=13; without this line systemd falls back to
# matching VERSION_ID, which the extension lacks, and REFUSES the merge
# ("does not contain VERSION_ID ... requested to match '13'") — the add-on is
# built and reported active but /usr is never layered, so its binary is missing.
if grep -q '^SYSEXT_LEVEL=' "$CH/usr/lib/os-release" 2>/dev/null; then
    sed -i "s|^SYSEXT_LEVEL=.*|SYSEXT_LEVEL=$VERSION|" "$CH/usr/lib/os-release"
else
    printf 'SYSEXT_LEVEL=%s\n' "$VERSION" >> "$CH/usr/lib/os-release"
fi

# The interface must be present and must be Qt (no Electron on this fork).
mkdir -p "$CH/etc/hifi-player"
printf 'qt\n' > "$CH/etc/hifi-player/ui-engine"
[ -x "$CH/opt/hifi-qt/hifi-qt" ] || die "missing /opt/hifi-qt/hifi-qt in the chroot"

# ── 6. initrd (arm64): overlay/vfat/squashfs, zstd, plymouth ──────────────
log "building the image initrd (MODULES=most, zstd, plymouth)"
# Exec bits the repo does not keep (core.filemode=false), as hook 0300 does.
chmod +x "$CH/etc/initramfs-tools/hooks/hifi-state" \
    "$CH/etc/initramfs-tools/scripts/local-bottom/hifi-state" \
    "$CH/etc/initramfs-tools/scripts/local-premount/hifi-data-grow" \
    "$CH/usr/local/share/hifi-ab/initramfs/hooks/hifi-ab" \
    "$CH/usr/local/share/hifi-ab/initramfs/scripts/local-premount/hifi-ab-convert" 2>/dev/null || true
# 0755 (world-readable), not `chmod +x`: see the injection block above — `+x`
# under umask 0077 yields -rwx------ root, which User=hifi services cannot read.
chmod 0755 "$CH"/usr/local/sbin/hifi-*.sh "$CH"/usr/local/sbin/hifi-*.py "$CH"/usr/local/bin/*.py 2>/dev/null || true
chmod +x "$CH/usr/local/bin/apt" 2>/dev/null || true
mkdir -p "$CH/etc/initramfs-tools/conf.d"
cat > "$CH/etc/initramfs-tools/conf.d/hifi-image.conf" <<'CONF'
# Osmium Sound (Pi3) — factory-built slot initrd: must boot any unit of the
# fleet (MODULES=most), with overlayfs for /etc, vfat for the FAT boot part and
# squashfs for the root, and plymouth (FRAMEBUFFER=y: no `splash` on the kernel
# cmdline inside the chroot, so the hook would otherwise skip it).
MODULES=most
COMPRESS=zstd
FRAMEBUFFER=y
CONF
for m in overlay squashfs vfat nls_cp437 nls_ascii nls_utf8 ext4 vc4 v3d; do
    grep -qx "$m" "$CH/etc/initramfs-tools/modules" 2>/dev/null || echo "$m" >> "$CH/etc/initramfs-tools/modules"
done
rm -f "$CH/boot/initrd.img-$KVER"
# Select the branded Plymouth theme BEFORE building the initrd, so update-initramfs
# embeds the "hifi" script theme (and its script.so plugin) into the image. On x86
# this is done by hook 0200 / the disk installer, both skipped on the Pi, so without
# this line the splash falls back to the generic default and never shows our frames.
in_chroot plymouth-set-default-theme hifi 2>&1 | tail -n 3 || true
in_chroot update-initramfs -c -k "$KVER" 2>&1 | tail -n 20 || true
[ -s "$CH/boot/initrd.img-$KVER" ] || die "initrd not produced"
# List it from the host (lsinitramfs inside the chroot has failed on zstd in CI)
# and insist the appliance pieces are really in it.
if command -v lsinitramfs >/dev/null 2>&1; then LSINIT="lsinitramfs $CH/boot/initrd.img-$KVER"; else LSINIT="in_chroot lsinitramfs /boot/initrd.img-$KVER"; fi
$LSINIT > "$WORK/initrd.list" 2>"$WORK/initrd.err" || { cat "$WORK/initrd.err" >&2; die "cannot list the initrd"; }
log "initrd: $(wc -l < "$WORK/initrd.list") entries, $(du -h "$CH/boot/initrd.img-$KVER" | cut -f1)"
for must in "scripts/local-bottom/hifi-state" "overlay.ko" "bin/busybox\$" "sbin/e2fsck\$" "bin/plymouth\$"; do
    grep -qE "$must" "$WORK/initrd.list" \
        || { grep -E "hifi|busybox|e2fsck|overlay|plymouth" "$WORK/initrd.list" | head -n 20 >&2; die "the initrd is missing $must"; }
done

# ── 7. fstab, machine-id (no slot grub.cfg: U-Boot handles the Pi) ────────
# The root (squashfs), /data, the /etc overlay, the /var and /home binds and the
# FAT boot partition on /boot/firmware are all mounted by the initramfs
# (scripts/local-bottom/hifi-state) before systemd; only the tmpfs mounts stay.
cat > "$CH/etc/fstab" <<'FSTAB'
# /etc/fstab — Osmium Sound image (Pi3, A/B slot, read-only squashfs root).
tmpfs  /mnt    tmpfs  mode=0755,nosuid,nodev  0  0
tmpfs  /media  tmpfs  mode=0755,nosuid,nodev  0  0
FSTAB
: > "$CH/etc/machine-id"
rm -f "$CH/var/lib/dbus/machine-id"

# ── 8. cleanup (same as build-image.sh §8) ───────────────────────────────
log "cleanup (apt, doc/man/info, locale, log)"
[ -f "$SCRIPT_DIR/gen-credits.py" ] && { python3 "$SCRIPT_DIR/gen-credits.py" "$CH" "$CH/usr/lib/osmium/credits.json" || log "WARNING: gen-credits.py failed (non-fatal)"; }
in_chroot apt-get clean >/dev/null 2>&1 || true
rm -rf "$CH"/var/lib/apt/lists/* "$CH"/var/cache/apt/*.bin "$CH"/var/cache/debconf/*-old "$CH"/var/lib/dpkg/*-old
find "$CH/usr/share/doc" -mindepth 2 -type f ! -name copyright -delete 2>/dev/null || true
find "$CH/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
rm -rf "$CH"/usr/share/man/* "$CH"/usr/share/info/* "$CH"/usr/share/lintian
find "$CH/usr/share/locale" -mindepth 1 -maxdepth 1 -type d ! -name 'en*' ! -name 'it*' -exec rm -rf {} + 2>/dev/null || true
find "$CH/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf "$CH"/tmp/* "$CH"/var/tmp/* "$CH"/root/.cache "$CH"/root/.bash_history
rm -f "$CH/usr/sbin/policy-rc.d" "$CH/usr/bin/qemu-aarch64-static"
if [ -f "$WORK/resolv.conf.orig" ]; then cp -a "$WORK/resolv.conf.orig" "$CH/etc/resolv.conf"; else rm -f "$CH/etc/resolv.conf"; ln -s /run/NetworkManager/resolv.conf "$CH/etc/resolv.conf"; fi
for m in "$CH/run" "$CH/dev/pts" "$CH/dev" "$CH/sys" "$CH/proc"; do mountpoint -q "$m" && umount -R "$m"; done

used_mib=$(du -sxm "$CH" | cut -f1)
log "image content: ${used_mib} MiB"

# ── 9. rootfs.squashfs (read-only, gzip) ──────────────────────────────────
# gzip -9: the kernel's squashfs driver reads any codec, but the Pi3 CPU is
# weak and gzip costs the least to decompress at runtime (same reasoning as the
# x86 image; there is no GRUB squash4 constraint here). U-Boot never reads the
# squashfs — it loads vmlinuz/initramfs from the FAT boot partition.
log "mksquashfs (gzip -9, 256K blocks)"
SQ="$WORK/rootfs.squashfs"; rm -f "$SQ"
# gzip, NOT zstd. A zstd-compressed rootfs squashfs is unreadable by the factory
# initramfs at boot: the squashfs-zstd decompressor is not pulled into the initrd,
# so the root never mounts and the kernel panics with no /sbin/init. Observed on
# 2.6.0-pi.13 both via OTA and on a fresh flash of the .img (the running kernel in
# the RAUC post-install hook CAN read zstd, which masked it during install). Only
# revisit zstd with the decompressor forced into the initramfs AND a hardware boot
# test first.
SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mksquashfs "$CH" "$SQ" -comp gzip -Xcompression-level 9 -b 256K \
    -noappend -no-progress -xattrs -no-recovery >/dev/null || die "mksquashfs failed"
sq_mib=$(du -m "$SQ" | cut -f1)
budget=$(( SLOT_MIB * 90 / 100 ))
log "rootfs.squashfs: ${sq_mib} MiB (slot ${SLOT_MIB} MiB, cap ${budget})"
if [ "$sq_mib" -gt "$budget" ]; then
    du -xm --max-depth=2 "$CH" | sort -n | tail -n 15 >&2
    die "image over the cap: ${sq_mib} > ${budget} MiB"
fi

# ── 10. RAUC bundle (or just the rootfs) ──────────────────────────────────
if [ "$NO_BUNDLE" = 1 ]; then
    SQ_OUT="$OUT/osmium-pi3-${VERSION}.rootfs.squashfs"
    mv "$SQ" "$SQ_OUT"
    ( cd "$OUT" && sha256sum "$(basename "$SQ_OUT")" > "$(basename "$SQ_OUT").sha256" )
    cp "$CH/usr/lib/osmium/BUILD_INFO" "$OUT/osmium-pi3-${VERSION}.build-info.txt"
    log "DONE ✓  $SQ_OUT (no bundle)"
    exit 0
fi

[ -n "$CERT" ] && [ -n "$KEY" ] || die "--cert and --key are required to sign the bundle (or pass --no-bundle)"
log "rauc bundle (verity)"
B="$WORK/bundle"; mkdir -p "$B"
sed -e "s|@VERSION@|$VERSION|g" "$SCRIPT_DIR/rauc/manifest.raucm.tmpl" > "$B/manifest.raucm"
install -m 0755 "$SCRIPT_DIR/rauc/hook.sh" "$B/hook.sh"
mv "$SQ" "$B/rootfs.squashfs"
RAUCB="$OUT/osmium-pi3-${VERSION}.raucb"; rm -f "$RAUCB"
rauc bundle --cert "$CERT" --key "$KEY" --signing-keyring "$KEYRING" "$B" "$RAUCB" || die "rauc bundle failed"
rauc info --keyring "$KEYRING" "$RAUCB" > "$OUT/osmium-pi3-${VERSION}.info.txt" \
    || die "the bundle does not verify against the keyring $KEYRING"
( cd "$OUT" && sha256sum "$(basename "$RAUCB")" > "$(basename "$RAUCB").sha256" )
if [ "$KEEP_ROOTFS" = 1 ]; then cp "$B/rootfs.squashfs" "$OUT/osmium-pi3-${VERSION}.rootfs.squashfs"; fi
cp "$CH/usr/lib/osmium/BUILD_INFO" "$OUT/osmium-pi3-${VERSION}.build-info.txt"
log "DONE ✓  $RAUCB"
ls -lh "$OUT"/osmium-pi3-"${VERSION}".*

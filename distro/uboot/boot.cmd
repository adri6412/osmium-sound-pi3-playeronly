# Osmium Sound — RAUC A/B redundant boot for the Raspberry Pi 3B (U-Boot).
#
# Compiled to boot.scr at image-build time (build-image-pi3.sh) with:
#   mkimage -A arm64 -O linux -T script -C none -n "Osmium A/B" -d boot.cmd boot.scr
#
# This is the Pi counterpart of the x86 GRUB selector (grub-selector.cfg.tmpl):
# U-Boot reads BOOT_ORDER plus BOOT_<slot>_LEFT from its environment (uboot.env
# on the FAT boot partition, written by fw_setenv from Linux and by `saveenv`
# here), tries each slot in BOOT_ORDER while it still has attempts left, and
# DECREMENTS the counter before handing over. A slot that boots and reaches
# `rauc status mark-good` has its counter reset to 3 (RAUC's u-boot backend);
# one that never gets there is abandoned after BOOT_<slot>_LEFT tries and the
# next slot in the order is taken. This is RAUC's documented u-boot scheme.
#
# The rootfs is a squashfs written raw to the slot partition (p2 = A, p3 = B),
# exactly as on x86. U-Boot on the Pi cannot be relied on to read squashfs, so
# the kernel + initramfs + DTB of each slot are copied onto the FAT boot
# partition as vmlinuz-<slot> / initramfs-<slot> (at build time for A, by the
# RAUC post-install hook for the slot it writes). The cmdline mirrors the x86
# slot script: root points at the slot partition, rootfstype=squashfs.

# Defaults on a fresh image; real values live in uboot.env after the first write.
test -n "${BOOT_ORDER}"  || setenv BOOT_ORDER  "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 3

# Common cmdline: quiet boot handed over to Plymouth, no console cursor. Kept in
# step with @CMDLINE@ in build-image.sh / slot-grub.cfg.tmpl.
# cma=256M: the vc4-kms-v3d full-KMS driver allocates every GPU buffer object
# (scanout framebuffers, textures, FBOs, V3D binner/render) from the CMA pool.
# The arm64 kernel default is 64 MB, too small for the 1080p Qt/QML kiosk: it
# exhausts CMA on screen changes ("Failed to allocate from GEM DMA helper" ->
# SIGSEGV, crash-loop). The vc4-kms-v3d,cma-256 overlay param is NOT honoured on
# this firmware-FDT + U-Boot boot path (CmaTotal stayed 64 MB), so the pool is
# sized here on the kernel cmdline, which always wins.
setenv cmdline_common "ro rootfstype=squashfs rootwait panic=10 quiet splash loglevel=0 systemd.show_status=0 rd.systemd.show_status=0 vt.global_cursor_default=0 cma=256M"

setenv load_slot
for bootslot in ${BOOT_ORDER}; do
  if test "x${bootslot}" = "xA"; then
    if test ${BOOT_A_LEFT} -gt 0; then
      setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
      setenv load_slot A
      setenv rootpart 2
    fi
  fi
  if test "x${bootslot}" = "xB"; then
    if test ${BOOT_B_LEFT} -gt 0; then
      setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
      setenv load_slot B
      setenv rootpart 3
    fi
  fi
  if test -n "${load_slot}"; then
    saveenv
    setenv bootargs "${cmdline_common} root=/dev/mmcblk0p${rootpart} rauc.slot=${load_slot}"
    if fatload mmc 0:1 ${kernel_addr_r} vmlinuz-${load_slot}; then
      if fatload mmc 0:1 ${ramdisk_addr_r} initramfs-${load_slot}; then
        setenv ramdisk_size ${filesize}
        # Prefer the FDT the GPU firmware already built for THIS board (3B /
        # 3B+ / 3A+): it carries the firmware's runtime fixups (USB/LAN hub
        # power on the 3B+, memory size, serials) that a hand-loaded DTB would
        # lose. ${fdt_addr} is set by rpi_arm64 U-Boot from the firmware
        # hand-off. booti does not return on success, so each block below is a
        # fallback: the firmware FDT, then the board DTB by its firmware name
        # (${fdtfile}), then the plain 3B DTB as a last resort.
        if test -n "${fdt_addr}"; then
          booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr}
        fi
        if fatload mmc 0:1 ${fdt_addr_r} ${fdtfile}; then
          booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
        fi
        if fatload mmc 0:1 ${fdt_addr_r} bcm2837-rpi-3-b.dtb; then
          booti ${kernel_addr_r} ${ramdisk_addr_r}:${ramdisk_size} ${fdt_addr_r}
        fi
      fi
    fi
    # Reached only when this slot failed to load/boot: fall through to the next.
    setenv load_slot
  fi
done

# No slot could be started. Reset so the firmware tries again from the top
# (BOOT_ORDER may have been reordered by RAUC towards the other slot).
echo "Osmium: no bootable A/B slot left, resetting"
reset

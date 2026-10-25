# Osmium Sound — Raspberry Pi 3B, player-only fork

This repository is a **curated fork** of the x86-64 Osmium Sound appliance
(`hifi-media-player`), targeting the **Raspberry Pi 3B** (BCM2837, aarch64) as a
**player-only** device.

## Provenance

- Upstream repo: `hifi-media-player`
- Forked from commit: `9fd4087de98ebef5e8b998e71ec56307e7d10ad2` (branch `alpha`)
- Fork created: 2026-10-25

This is **not** a full git mirror: only the subset needed for a Pi3B player was
copied (backend, web admin, Qt kiosk, distro build, tests, branding). To pull
later fixes from upstream, diff against the recorded commit above.

## How this differs from the x86 appliance

- **No bundled Lyrion server.** The device connects only to an **external**
  Lyrion Music Server. The internal-Lyrion path and the web-admin wizard's
  "internal Lyrion" choice are removed; the setup flow asks for the external
  host and nothing else.
- **arm64 base** (Debian trixie) with the same **A/B RAUC** update scheme as
  x86, but using **U-Boot** as the RAUC bootloader backend instead of GRUB
  (`compatible=osmium-rpi3`). See `distro/` and the plan.
- Audio out: **USB DAC** and **I2S HAT** (device-tree overlays in `config.txt`).

## Left intact on purpose (first-phase experiment)

The **Qt kiosk UI is kept complete**, and **PCM→DSD / resampling / DSP code is
left in place** for now, to try everything on real hardware first. On a Pi3B the
heavy DSP/PCM→DSD conversions are not expected to hold up; what to trim or
disable is decided after testing on the device, not up front.

## Status

Work in progress. The build for Pi3B (`distro/build-pi3.sh`,
`distro/build-image-pi3.sh`, U-Boot + RAUC) is not finished yet.

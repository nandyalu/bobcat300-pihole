# eMMC flashing investigation

Status: **not achieved.** SD-boot Trixie (see main [README](../README.md)) is the working,
supported setup. This document exists so anyone with better tools — specifically, a working
serial console on their unit — can pick up where this stopped.

## Goal

Flash the proven SD-boot Trixie image directly onto the Bobcat's internal eMMC, removing the
SD-card dependency entirely. This trades away the project's normal "always reversible, pull the
card to go back to stock" safety property — only worth attempting once you've decided the unit
is never going back to Helium mining.

## Background: Maskrom mode

Rockchip's RK3566 boot ROM has a hardware-level recovery mode (Maskrom) that responds to a USB
connection regardless of what's on eMMC — even a fully wiped chip. This is what makes attempting
eMMC flashing reasonable: worst case, Maskrom mode should still be reachable afterward.

Entry: power off, hold the internal Recovery button (inside the case, distinct from the
external BT-pairing pinhole), plug in power, release Recovery after about a second.

**Known caveat for this exact board**, per Crankk's community documentation: some G285 units
don't reliably accept the bootloader-download command during flashing and get stuck. This
matches what we hit — see below.

## Tooling

- **`rkdeveloptool`** (Rockchip's official open-source Linux CLI) on a native Linux box, not
  Windows RKDevTool (GUI). Windows detection was unreliable across multiple tool versions, USB
  ports, cables, and even a `usbipd-win`/WSL2 passthrough attempt — consistent with the known
  G285 Maskrom flakiness. A separate physical Ubuntu machine with `rkdeveloptool` worked
  immediately and reliably by comparison.
- Loader file: `rk356x_spl_loader.bin`, sourced from Radxa's ROCK 3A CDN. Generic to the RK356x
  family; community-validated for this use even though it targets a different board.
- `mtools`/`debugfs` for editing files inside a raw disk image's partitions without
  loop-mounting.

## Bugs found and fixed

Two real, confirmed bugs were found and fixed before flashing stalled on a third, unresolved
issue.

**1. CXMT vs. SK Hynix DRAM.** This board's DRAM chip is CXMT, not the SK Hynix chip the
standard idbloader expects — confirmed by physically opening the EMI shield over the RAM chip.
This causes Maskrom/bootloader-download flakiness and matches Crankk's own documented unsolved
issue for some G285 units. Fix: use the idbloader from `bobcat-g285m`, Crankk's community
SD-boot-only workaround image built specifically for CXMT-affected units — extract it and
splice it into the target image.

**2. Hardcoded SD-card device index.** U-Boot's `boot.scr` uses `load mmc <dev>:<part>` syntax,
where the device index differs between SD card (`1`) and eMMC (`0`). Our image's `boot.scr` and
`fstab` both hardcoded the SD-card index and device path. Fix: a corrected `boot_emmc.cmd`
compiled to `boot_emmc.scr`:

```
setenv bootargs console=ttyS0,115200 root=/dev/mmcblk0p3 rw rootwait
load mmc 0:2 ${kernel_addr_r} Image
load mmc 0:2 ${fdt_addr_r} rk3566-bobcat.dtb
booti ${kernel_addr_r} - ${fdt_addr_r}
```

Both fixes were found independently by two parallel investigation efforts (this repo's
maintainer working from two machines at once) and converged on identical diagnoses.

## Where it stalled

Even with both fixes applied, **the kernel never mounts the eMMC root filesystem** — confirmed
via a clean `dumpe2fs` mount-count check before and after a boot attempt (unchanged, meaning the
filesystem was never touched). The device instead boots into a recovery/wait state.

Diagnosing further needs a serial console — U-Boot and early kernel output would show exactly
where boot stalls. On this specific unit, the serial console header is **confirmed
hardware-faulty** (no output on any tested baud rate/adapter), matching Crankk's documented
"degradation of serial port" issue for this board family. Without serial output, there's no way
to see whether U-Boot finishes, whether the kernel starts, or where in early boot it stops.

## Partition layout, for reference

Via `rkdeveloptool read-flash-info` and `list-partitions`:

- eMMC: Samsung, ~57.6GB
- GPT: `uboot` (4MB) / `skyboot` (512MB) / `update` (4GB) / `rootfs` (57GB) — four partitions,
  vs. the SD card's three (`uboot`/`skyboot`/`update` only)
- `rkdeveloptool` never references the eMMC hardware boot partitions (`mmcblk0boot0`/`boot1`)
  — it treats the `uboot` GPT partition as the boot target directly, the same scheme as SD
  card boot. Inferred from tool behavior, not exhaustively proven.

## If you want to pick this up

You need a working serial console on your specific unit — this is the one diagnostic that would
actually reveal the third bug. If your unit's debug port works (test it before attempting
anything else), the two fixes above should get you further than this investigation reached.
Everything else here — the DRAM chip fix, the boot.scr/fstab device-index fix, the tooling
setup — should still apply as-is.

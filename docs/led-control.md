# LED control investigation

Status: **blocked, not solved.** This document exists so anyone picking it up later doesn't
repeat the same dead ends. It assumes an SD-boot setup (see main [README](../README.md)).

## Goal

The Bobcat 300's front panel has an RGB status LED. On stock firmware it changes color to show
hotspot state (booting, syncing, synced). The goal was to drive it from our own SD-boot Debian
image — for example, to show Pi-hole status instead.

## What controls the LED on stock firmware

Confirmed by getting root on stock firmware (via
[sicXnull/Bobcat-SSH-Access](https://github.com/sicXnull/Bobcat-SSH-Access) — this tool
permanently patches the eMMC stock firmware; not reversible like the rest of this project) and
inspecting the running `gateway_config` process. This app (an Erlang/OTP binary,
`/opt/gateway_config/bin/gateway_config`, using the `erlang_ale` hardware library) drives the
LED directly. It is not the miner binary — the Rust `helium_gateway` process was checked too
and only touches `/dev/i2c-2` for the ECC crypto chip, no GPIO.

Confirmed live, by toggling each pin on stock firmware and watching the LED change:

| GPIO | Bank | Color |
|---|---|---|
| 128 | `gpiochip4` (`fe770000.gpio`, offset 0) | Green |
| 129 | `gpiochip4` (offset 1) | Blue |
| 130 | `gpiochip4` (offset 2) | Red |

## Why the same GPIOs don't work from our SD-boot image

Writing to these same GPIOs on the SD-boot Debian image succeeds at the register level —
`/sys/kernel/debug/gpio` shows the write took — but produces **no physical effect** on the LED.

The cause: which physical SoC pad a GPIO controller signal reaches is set by pin *muxing*,
configured during early hardware bring-up by U-Boot, not by the device tree alone.
`/sys/kernel/debug/pinctrl/pinctrl-rockchip-pinctrl/pinmux-pins` shows all three pins as `MUX
UNCLAIMED`, and nothing in the community DTB references them. Stock firmware's proprietary
U-Boot mux's these pads to GPIO function during its own board bring-up, since Bobcat's hardware
wires the LED there. The generic community U-Boot build we use has no reason to know about
this Bobcat-specific wiring.

## What we tried

All three approaches below successfully got Linux to claim and toggle the GPIO lines at the
software level. None reached the physical LED.

1. **`gpio set` in `boot.scr`** — our U-Boot binary already contains literal `gpio set
   128/129/130` command strings (part of Rockchip's generic recovery-mode LED indication, not
   Bobcat-specific). Adding `gpio clr 129/130; gpio set 128` to `boot.scr` did cause a real,
   visible transition (blank → green) during the U-Boot stage — confirming U-Boot-time control
   works. But the kernel's own GPIO driver resets pin direction to input on probe, about 0.2s
   into boot, wiping this out before userspace runs.
2. **`gpio-hog` device tree node** — got the kernel to properly claim the lines at boot (debug
   GPIO listing showed real names like `bobcat-led-green` instead of generic `sysfs`). But
   hogged lines don't get a legacy numeric `/sys/class/gpio/gpioN` export, and the kernel here
   (4.19.232) is too old for the modern `libgpiod` v2 tools Debian 13 ships (ioctl ABI
   mismatch) — no toggle path found via this route.
3. **`gpio-leds` device tree binding** — the purpose-built binding for GPIO-driven LEDs,
   exposed via `/sys/class/leds/<name>/brightness` (kernel-version-independent, unlike
   libgpiod). This is the binding to use if revisiting this. Deployed and rebooted;
   `/sys/class/leds/bobcat:red`, `bobcat:blue`, `bobcat:green` all appeared as expected.

## Final result

`gpio-leds` also never reached the physical pad. Tested all three channels individually plus a
slow blink sequence, on both a warm reboot and a genuine cold power cycle (Ethernet unplugged
too, to rule out a network-state correlation) — LED stayed solid green throughout.

One telling detail: after writing a color, `brightness` reads back correctly per the LED-class
driver's own bookkeeping (e.g. `red=255`), but the underlying GPIO controller's hardware
register (`/sys/kernel/debug/gpio`) shows the *opposite* state moments later. Something is
actively reverting the raw register, not just failing to propagate to the pad.

## Leading theory

This is very likely the Boot ROM/TF-A's own **SD-card-vs-eMMC boot-source indicator** — a
hardcoded, actively-enforced signal that forces solid green for as long as the SoC boots from
SD card, independent of anything Linux does. This explains every observation: full control on
stock firmware (eMMC boot), fully locked on every SD-boot attempt regardless of DT approach,
and the state survives warm reboot, cold power cycle, and network changes — none of which
change the boot source.

## If you want to pick this up

This is not fixable from the DTB, U-Boot config, or kernel while booting from SD card. It would
require booting from eMMC instead, which the companion [eMMC flashing
investigation](emmc-flashing.md) also could not get working — see that document for where it
stalled and what would be needed to unblock it. If eMMC boot ever succeeds, retesting the
`gpio-leds` approach documented above (step 3) is the fastest way to confirm or refute this
theory.

## Also worth knowing: a hardware-crash lesson

Blindly toggling unclaimed GPIOs is genuinely dangerous on this board. Batch-testing pins 1-15
on `gpiochip0` (`fdd60000.gpio`, the SoC's PMU IO domain) crashed the device solid — no ping, no
SSH — until a physical power cycle. The likely cause: forcing an I2C line to the PMIC (which
manages core voltage regulation) into GPIO mode mid-write. **Avoid `gpiochip0` (GPIOs 0-31)
entirely** in any future GPIO experiments on this board.

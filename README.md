# bobcat300-pihole

Turn a dead Bobcat Miner 300 (Helium hotspot) into a network-wide Pi-hole DNS ad-blocker.

Helium mining no longer covers its costs for most people. Many Bobcat 300 units now sit idle.
The hardware still works: a Rockchip RK3566 SoC, ~2GB RAM, and Ethernet. This repo turns one
into a Pi-hole box. No soldering. No eMMC flashing. Pull the SD card, and it's a stock miner
again.

## Choose a path

| | Path A: Trixie (recommended) | Path B: Bullseye |
|---|---|---|
| Debian version | 13 | 11 |
| How | Fresh image, built from scratch | Community image + cleanup script |
| Miner stack (Docker, nginx, timers) | Never installed | Installed, then removed |
| Effort | More setup, or a bigger download | Less setup |

Both paths share the same bootloader and kernel. Path B is the original base image this
project started from.

## Requirements

- A Bobcat Miner 300 (tested on a G285; base image also lists G280/G29x)
- A microSD card, 16GB+, Class 10 / UHS-I
- A USB SD card reader
- An Ethernet cable from the Bobcat to your router (both paths disable WiFi)

## Flash the image

Use [Rufus](https://rufus.ie/), not Balena Etcher. Etcher crashes on Windows
("writer process ended unexpectedly") when it decompresses a `.img.xz` while writing — even as
Administrator, even on a freshly wiped card. Extract first, then flash the raw `.img`.

1. Extract the `.img.xz` file with 7-Zip.
2. Open Rufus, select the `.img` file and your SD card, and write it.

---

## Path A: Debian 13 (Trixie)

Reuses the proven bootloader and kernel (4.19.232) from the original image. Replaces the root
filesystem with a fresh Debian 13 install. No miner stack to remove, because none is installed.

### Get the image

Option 1 — download a prebuilt image from this repo's
[Releases](https://github.com/nandyalu/bobcat300-pihole/releases) page.

Option 2 — build it yourself. Requires a Linux environment (WSL2 works on Windows) with these
packages: `debootstrap`, `qemu-user-static`, `binfmt-support`, `parted`, `util-linux`, `gdisk`,
`kpartx`, `rsync`. Also requires a copy of `BobcatDebian285.img` (or your board's variant) from
[sicXnull/Bobcat300-Debian releases](https://github.com/sicXnull/Bobcat300-Debian/releases) —
the build script takes the kernel and modules from it and discards the rest.

Run the build script (takes a while — it runs Debian's installer under CPU emulation):
```
sudo build/build-trixie-image.sh /path/to/BobcatDebian285.img ./BobcatTrixie.img
```

### Set up the device

Flash `BobcatTrixie.img` to the SD card (see [Flash the image](#flash-the-image) above).

Insert the card into the Bobcat, connect Ethernet, and power on. Wait a few minutes for first
boot — the filesystem expands to fill the card.

Find the device's IP address in your router's DHCP client list (hostname `bobcat`), then
connect:
```
ssh root@<device-ip>          # password: bobcat
```

Change the root password:
```
passwd
```

Rotate the SSH host keys. The image ships with keys baked in at build time, so every copy
starts out with the same ones:
```
rm /etc/ssh/ssh_host_*; ssh-keygen -A
```

Install Pi-hole:
```
curl -sSL https://install.pi-hole.net | bash
```

Restart FTL. The installer starts it before the blocklist database finishes building, so it
serves an empty blocklist until you restart it:
```
systemctl restart pihole-FTL
```

Confirm blocking works. This command must return `0.0.0.0`:
```
dig doubleclick.net @127.0.0.1
```

Last step: on your router, give the device a static IP (or DHCP reservation), then set your
router's DNS server to that IP. This applies Pi-hole to your whole network.

### Known caveats (Path A)

- **SSH host keys are baked into the image.** This board has no initrd, so systemd can't
  detect first boot and generate fresh keys on its own. Rotate them yourself (see above).
- **No real-time clock.** The clock resets on every cold boot until NTP syncs. The build script
  installs and enables `systemd-timesyncd` to fix this quickly. Without it, `apt` fails with
  OpenPGP "not live until \<future date\>" errors until the clock catches up.
- **No initrd, no GRUB.** U-Boot's `boot.scr` loads the kernel and device tree directly.
  `/boot/grub` exists on the image but is never used. Don't add an initramfs-based boot step
  without accounting for this.
- **WiFi is disabled.** Both paths assume Ethernet-only use.

### Hardware watchdog

Both paths enable this board's hardware watchdog timer (`dw_wdt`) through systemd. If the
system ever hard-hangs — this happened once during development, for about 14 hours, until
someone noticed and power-cycled it — the hardware forces a reboot within about 90 seconds. No
setup needed on Path A; it's already in the image.

Check that it's armed:
```
systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec
```

---

## Path B: Debian 11 (Bullseye) + cleanup script

Uses [sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian)'s image
directly. Then `setup.sh` in this repo removes the stock miner monitoring stack, including a
self-healing watchdog that silently resurrects the Helium miner container even after you
delete it.

### Set up the device

Download the image matching your Bobcat's variant from the
[upstream releases page](https://github.com/sicXnull/Bobcat300-Debian/releases). Check the
serial number on the unit — a S/N containing `285` is the G285 variant.

Flash the image to the SD card (see [Flash the image](#flash-the-image) above).

Insert the card into the Bobcat, connect Ethernet, and power on. First boot takes 5-10
minutes — longer than normal, because it expands the filesystem to fill the card.

Find the device's IP address in your router's DHCP client list, then connect:
```
ssh root@<device-ip>          # password: bobcat
```

Change the root password:
```
passwd
```

Run the cleanup and setup script. It removes the miner stack (see table below) and asks
whether to install Pi-hole — say yes:
```
curl -sSL https://raw.githubusercontent.com/nandyalu/bobcat300-pihole/main/setup.sh | bash
```

Restart FTL. The installer starts it before the blocklist database finishes building, so it
serves an empty blocklist until you restart it:
```
systemctl restart pihole-FTL
```

Confirm blocking works. This command must return `0.0.0.0`:
```
dig doubleclick.net @127.0.0.1
```

Last step: on your router, give the device a static IP (or DHCP reservation), then set your
router's DNS server to that IP. This applies Pi-hole to your whole network.

### What `setup.sh` removes

| Component | Why it's removed |
|---|---|
| `helium-miner`, `portainer`, `pktfwd` Docker containers | The dead miner, a container management UI, and the LoRa packet forwarder — none needed |
| ~25 stock monitoring `systemd` timers | Fire every 15-30 seconds, forking `sudo`+`docker` processes for no purpose — pure CPU/RAM churn |
| `update-miner-check.service` | Silently runs `docker run --privileged ...` to resurrect the miner container if it's missing. Disabled before Docker is removed, or it just comes back |
| `nginx` (stock miner dashboard) | Was bound to ports 80/443, colliding with Pi-hole's web UI |
| `docker.service` + `docker.socket` | Nothing left needs Docker. Stopping the socket too prevents any leftover `docker` command from relaunching it |
| WiFi + Bluetooth radios (`rfkill block`) | This setup assumes Ethernet. Re-enable anytime with `rfkill unblock wifi bluetooth` |

### What `setup.sh` enables

The hardware watchdog (`dw_wdt`), through systemd. This replaces the stock self-healing
watchdog removed above — that one resurrected a dead container, this one protects the system.
If the box ever hard-hangs completely, the hardware forces a reboot within about 90 seconds.

Check that it's armed:
```
systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec
```

### Known caveats (Path B)

- **No real-time clock.** The clock resets on every cold boot until NTP syncs a few seconds
  in. When checking logs, use `journalctl --since '<date>' --until '<date>'` with real dates
  instead of `journalctl -b -1`.
- **`setup.sh` is a community script**, not an official tool. It only touches userspace
  services and Docker — never the bootloader, kernel, or partition table. Worst case, reflash
  the SD card to start over.
- **Helium mining is permanently disabled by either path.** To go back to mining, remove the
  SD card — the stock firmware on eMMC is untouched.

## Further investigation (unfinished)

Two side investigations didn't reach a working result, but are documented in detail for anyone
who wants to continue them:

- [**LED control**](docs/led-control.md) — the front-panel LED's GPIO mapping is fully
  reverse-engineered, but not controllable from Linux while booting via SD card. Likely fixable
  only by booting from eMMC (see next).
- [**eMMC flashing**](docs/emmc-flashing.md) — flashing this image directly to eMMC (no SD card
  needed) got past two real bugs, then stalled on a third with no working serial console left
  to diagnose it. SD-boot remains the supported setup.

## Credits

Base image and kernel/bootloader (both paths):
[sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian)

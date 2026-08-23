# bobcat300-pihole

Turn a dead Bobcat Miner 300 (Helium hotspot) into a network-wide Pi-hole DNS ad-blocker.

Helium hotspot mining stopped being worth the re-registration/token costs for most people a
while ago, leaving a lot of Bobcat 300 units sitting idle. The hardware itself (ARM SoC, ~2GB
RAM, Ethernet) is perfectly capable of running as a small always-on Debian server — this repo
turns one into a Pi-hole box in about 20 minutes, no soldering, no eMMC flashing, fully
reversible (pull the SD card and it's a stock miner again).

This builds on [sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian), which
solved the hard part — a Debian 11 image with a working bootloader/kernel for this hardware,
booted entirely from a microSD card (the internal eMMC and stock firmware are never touched).
That image still ships with the *entire* stock miner monitoring stack running in the
background, though — including a self-healing watchdog that silently resurrects the Helium
miner container even after you delete it. `setup.sh` in this repo strips all of that out and
optionally installs Pi-hole.

## Requirements

- A Bobcat Miner 300 (tested on a G285; the base image also lists G280/G29x support — see
  upstream repo for details)
- A microSD card, 16GB+ Class 10 / UHS-I
- A USB SD card reader/adapter (the Bobcat's onboard slot is used for the final boot, but you
  need a way to write the image from your PC first)
- Ethernet cable from the Bobcat to your router (WiFi is disabled by this script — see below)

## ⚠️ Known gotcha: use Rufus, not Balena Etcher, to flash the image

Balena Etcher reliably crashes ("writer process ended unexpectedly") writing this specific
image on Windows, even after running as Administrator and doing a full clean wipe of the card
first. The card and the downloaded image are not at fault — it's specifically Etcher's
on-the-fly `.xz` decompression-while-writing path that breaks. **Extract the `.img.xz` first
(7-Zip), then flash the raw `.img` with [Rufus](https://rufus.ie/) instead** — this wrote
cleanly on the first try in testing.

## Setup

1. Download the image matching your Bobcat's variant from the
   [upstream releases page](https://github.com/sicXnull/Bobcat300-Debian/releases) (check the
   serial number on the unit — e.g. a S/N containing `285` is the G285 variant).
2. Extract the `.img.xz` with 7-Zip, then flash the resulting `.img` to your SD card with Rufus.
3. Insert the card into the Bobcat, connect Ethernet, power on. First boot takes longer than
   normal (it expands the filesystem to fill the card) — give it 5-10 minutes.
4. Find its IP address (check your router's DHCP client list), then SSH in:
   ```
   ssh root@<device-ip>          # password: bobcat
   ```
5. **Immediately change the root password**: `passwd`
6. Run the cleanup + setup script:
   ```
   curl -sSL https://raw.githubusercontent.com/nandyalu/bobcat300-pihole/main/setup.sh | bash
   ```
   It'll strip the miner stack (see below) and ask whether to install Pi-hole. Say yes, or run
   the [official installer](https://install.pi-hole.net) yourself later.
7. Once Pi-hole is up, set a static IP/DHCP reservation for the device on your router, then
   point your router's DNS setting at it (DHCP/LAN settings) so it applies network-wide.

## What the script disables, and why

| Component | Why it's removed |
|---|---|
| `helium-miner`, `portainer`, `pktfwd` Docker containers | The dead miner itself, a container management UI, and the LoRa packet forwarder — none needed |
| ~25 stock monitoring `systemd` timers (miner/WiFi/Bluetooth/temp/password/dashboard checks, etc.) | Fire every 15-30 seconds nonstop, forking `sudo`+`docker` processes for no purpose on a repurposed box — pure CPU/RAM churn on a resource-constrained board |
| `update-miner-check.service` specifically | The self-healing one — silently runs `docker run --privileged ...` to resurrect the miner container if it's ever missing. Must be disabled *before* removing Docker or it just comes back |
| `nginx` (stock miner dashboard) | Was bound to ports 80/443 bare-metal, colliding with Pi-hole's own web UI |
| `docker.service` + `docker.socket` | Nothing left needs Docker; stopping the socket too prevents it from being silently relaunched by any leftover `docker` command |
| WiFi + Bluetooth radios (`rfkill block`) | This setup assumes Ethernet. The vendor WiFi driver spams the kernel log with errors even when idle. Re-enable anytime with `rfkill unblock wifi bluetooth` if you want WiFi instead |

## Known caveats

- **No RTC**: this board has no battery-backed real-time clock, so its system clock resets to
  1970 on every cold boot until NTP syncs a few seconds in. This can confuse boot-relative log
  queries — use `journalctl --since '<date>' --until '<date>'` with real dates instead of
  `journalctl -b -1` when debugging this hardware.
- This is a community script, not an official/supported tool. It only touches the userspace
  services and Docker layer — it never touches the bootloader, kernel, or partition table, so
  worst case you can always reflash the SD card from scratch to start over.
- Helium mining is permanently disabled by running this. If you want to go back to mining,
  just remove the SD card — the stock firmware on eMMC is untouched.

## Credits

Base image: [sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian)

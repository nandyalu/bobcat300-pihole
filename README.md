# bobcat300-pihole

Turn a dead Bobcat Miner 300 (Helium hotspot) into a network-wide Pi-hole DNS ad-blocker.

Helium hotspot mining stopped being worth the re-registration/token costs for most people a
while ago, leaving a lot of Bobcat 300 units sitting idle. The hardware itself (a Rockchip
RK3566 SoC, ~2GB RAM, Ethernet) is perfectly capable of running as a small always-on Debian
server — this repo turns one into a Pi-hole box, no soldering, no eMMC flashing, fully
reversible (pull the SD card and it's a stock miner again).

There are two ways to get there. **Path A (Debian 13 / Trixie, recommended)** builds a fresh,
genuinely clean image from scratch — nothing to strip out, because it was never there. **Path B
(Debian 11 / Bullseye)** uses the original community image directly and runs a cleanup script
afterward. Path A is more work up front (or a bigger download if you grab the prebuilt image)
but is the better starting point going forward; Path B is here because it's what this project
started with, and the underlying image/kernel Path A reuses comes from it.

## Requirements (either path)

- A Bobcat Miner 300 (tested on a G285; the base image also lists G280/G29x support)
- A microSD card, 16GB+ Class 10 / UHS-I
- A USB SD card reader/adapter
- Ethernet cable from the Bobcat to your router (WiFi is disabled by both paths — see below)

## ⚠️ Known gotcha: use Rufus, not Balena Etcher, to flash images

Balena Etcher reliably crashes ("writer process ended unexpectedly") writing these images on
Windows, even after running as Administrator and doing a full clean wipe of the card first.
The card and the image are not at fault — it's specifically Etcher's on-the-fly `.xz`
decompression-while-writing path that breaks. **Extract any `.img.xz` first (7-Zip), then flash
the raw `.img` with [Rufus](https://rufus.ie/) instead** — this wrote cleanly on the first try
in testing.

---

## Path A: Debian 13 (Trixie)

This reuses the exact proven bootloader and kernel (4.19.232) from the original image — that's
the part that's genuinely hardware-specific and risky to rebuild — but replaces the root
filesystem with a fresh `debootstrap` of Debian 13. Since it's built from scratch, none of the
stock miner monitoring stack (Docker, nginx, ~25 self-healing systemd timers) exists in the
first place. No cleanup script needed.

### Option 1: build it yourself

Requires a Linux environment (WSL2 works fine on Windows) with `debootstrap`,
`qemu-user-static`, `binfmt-support`, `parted`, `util-linux`, `gdisk`, `kpartx`, `rsync`
installed, plus a copy of the original `BobcatDebian285.img` (or matching variant) from
[sicXnull/Bobcat300-Debian releases](https://github.com/sicXnull/Bobcat300-Debian/releases) —
Path A's build script pulls the kernel/modules from it but discards the rest.

```
sudo build/build-trixie-image.sh /path/to/BobcatDebian285.img ./BobcatTrixie.img
```

This debootstraps Trixie under `qemu-aarch64` emulation, so expect it to take a while.

### Option 2: use a prebuilt image

Grab the latest `BobcatTrixie.img.xz` from this repo's
[Releases](https://github.com/nandyalu/bobcat300-pihole/releases) page.

### Setup

1. Flash `BobcatTrixie.img` (extract first if `.xz`) to the SD card with Rufus.
2. Insert into the Bobcat, connect Ethernet, power on. Give it a few minutes for first boot
   (filesystem auto-expands to fill the card).
3. Find its IP (router's DHCP client list — hostname `bobcat`), then SSH in:
   ```
   ssh root@<device-ip>          # password: bobcat
   ```
4. **Change the root password immediately**: `passwd`. Also worth rotating the SSH host keys
   (`rm /etc/ssh/ssh_host_*; ssh-keygen -A`) — they're baked into the image at build time (see
   caveats below), so every copy of this image initially shares the same ones.
5. Install Pi-hole:
   ```
   curl -sSL https://install.pi-hole.net | bash
   ```
6. **Restart FTL once after the installer finishes**: `systemctl restart pihole-FTL`. In
   testing, the installer starts FTL *before* the gravity (blocklist) database finishes
   building, so FTL can end up serving its stale near-empty initial state — blocking silently
   doesn't work, and the web UI shows zero configured adlists, until it's restarted. Verify
   blocking works before moving on: `dig doubleclick.net @127.0.0.1` should return `0.0.0.0`.
7. Set a static IP/DHCP reservation for the device on your router, then point your router's DNS
   setting at it (DHCP/LAN settings) so it applies network-wide.

### Known caveats (Path A)

- **SSH host keys are baked into the image**, not generated fresh per device. This board has no
  initrd, and systemd's usual first-boot detection (`ConditionFirstBoot`) fundamentally depends
  on one being present to stage a transient machine-id — so it can't fire here no matter what.
  Baking in keys at build time was the practical fix; rotate them after first login if that
  matters to you (see step 4).
- **No RTC**: this board has no battery-backed real-time clock, so its system clock resets to a
  stale value on every cold boot until NTP syncs. `systemd-timesyncd` is installed and enabled
  by the build script specifically to fix this quickly — if you're customizing the build and
  drop it, expect `apt` to fail with OpenPGP "not live until \<future date\>" signature errors
  until the clock catches up.
- This board boots via a U-Boot script (`boot.scr`) that loads the kernel and device tree
  directly with **no initrd and no GRUB**, despite `/boot/grub` existing on the original image
  (it's vestigial, never actually invoked). The build script relies on this — don't add an
  initramfs-based boot step without accounting for it.
- WiFi (`cywdhd`, Marvell `mwifiex`) and the disabled predictable-network-interface-naming rule
  assume Ethernet-only use, same as Path B.

---

## Path B: Debian 11 (Bullseye) + cleanup script

Uses [sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian)'s image directly,
then `setup.sh` in this repo strips the stock miner monitoring stack out afterward — including a
self-healing watchdog that silently resurrects the Helium miner container even after you delete
it.

### Setup

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
   the [official installer](https://install.pi-hole.net) yourself later. Same FTL-restart
   caveat as Path A step 6 applies here too — verify blocking actually works before moving on.
7. Once Pi-hole is up, set a static IP/DHCP reservation for the device on your router, then
   point your router's DNS setting at it (DHCP/LAN settings) so it applies network-wide.

### What `setup.sh` disables, and why

| Component | Why it's removed |
|---|---|
| `helium-miner`, `portainer`, `pktfwd` Docker containers | The dead miner itself, a container management UI, and the LoRa packet forwarder — none needed |
| ~25 stock monitoring `systemd` timers (miner/WiFi/Bluetooth/temp/password/dashboard checks, etc.) | Fire every 15-30 seconds nonstop, forking `sudo`+`docker` processes for no purpose on a repurposed box — pure CPU/RAM churn on a resource-constrained board |
| `update-miner-check.service` specifically | The self-healing one — silently runs `docker run --privileged ...` to resurrect the miner container if it's ever missing. Must be disabled *before* removing Docker or it just comes back |
| `nginx` (stock miner dashboard) | Was bound to ports 80/443 bare-metal, colliding with Pi-hole's own web UI |
| `docker.service` + `docker.socket` | Nothing left needs Docker; stopping the socket too prevents it from being silently relaunched by any leftover `docker` command |
| WiFi + Bluetooth radios (`rfkill block`) | This setup assumes Ethernet. The vendor WiFi driver spams the kernel log with errors even when idle. Re-enable anytime with `rfkill unblock wifi bluetooth` if you want WiFi instead |

### Known caveats (Path B)

- **No RTC**: same as Path A — clock resets to a stale value on every cold boot until NTP
  syncs a few seconds in. This can confuse boot-relative log queries — use
  `journalctl --since '<date>' --until '<date>'` with real dates instead of `journalctl -b -1`
  when debugging this hardware.
- `setup.sh` is a community script, not an official/supported tool. It only touches the
  userspace services and Docker layer — it never touches the bootloader, kernel, or partition
  table, so worst case you can always reflash the SD card from scratch to start over.
- Helium mining is permanently disabled by either path. If you want to go back to mining, just
  remove the SD card — the stock firmware on eMMC is untouched.

## Credits

Base image and kernel/bootloader (both paths):
[sicXnull/Bobcat300-Debian](https://github.com/sicXnull/Bobcat300-Debian)

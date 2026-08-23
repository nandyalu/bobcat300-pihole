#!/usr/bin/env bash
# bobcat300-pihole setup script
# Strips the stock Helium miner monitoring stack from sicXnull's Bobcat300-Debian
# image and (optionally) installs Pi-hole. Run as root on the device itself.
#
# https://github.com/sicXnull/Bobcat300-Debian (base image this targets)
#
# WARNING: this permanently disables Helium mining on this device (stops/removes
# the miner container and the watchdog that keeps recreating it). Only run this
# if you're repurposing the hardware and don't want it mining anymore.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this as root (e.g. as the root user over SSH)." >&2
  exit 1
fi

echo "== Removing Helium miner Docker containers =="
for c in helium-miner portainer pktfwd; do
  docker stop "$c" >/dev/null 2>&1
  docker rm "$c" >/dev/null 2>&1
done

echo "== Disabling stock miner dashboard (nginx, serves ports 80/443) =="
systemctl stop nginx >/dev/null 2>&1
systemctl disable nginx >/dev/null 2>&1

echo "== Disabling stock miner watchdog/monitoring timers =="
# These are stock-firmware self-healing timers. Several of them (notably
# update-miner-check) will silently re-create and restart the miner container
# if it's ever missing -- so they must be disabled *before* removing Docker,
# otherwise something keeps relaunching the daemon underneath you.
TIMER_UNITS=(
  packet-forwarder-sniffer
  bt-service-check bt-check miner-service-check pf-service-check reboot-check
  wifi-service-check cpu-check miner-check password-check server-detection
  timezone-config-check update-dashboard-check wifi-check wifi-config-check
  temp-check pf-check bobcat-watchdog local-ip-check auto-maintain auto-update
  miner-version-check update-miner-check pubkeys-check external-ip-check update-check
)
for u in "${TIMER_UNITS[@]}"; do
  systemctl stop "$u.timer" "$u.service" >/dev/null 2>&1
  systemctl disable "$u.timer" "$u.service" >/dev/null 2>&1
done

echo "== Stopping Docker entirely (not needed once the miner stack is gone) =="
systemctl stop docker.service docker.socket >/dev/null 2>&1
systemctl disable docker.service docker.socket >/dev/null 2>&1

echo "== Blocking unused WiFi/Bluetooth radios =="
# This setup assumes Ethernet. The vendor WiFi driver (dhd, not mainline
# brcmfmac) spams the kernel log with errors even when unused. Re-enable with
# `rfkill unblock wifi bluetooth` if you actually want WiFi on your box.
if command -v rfkill >/dev/null 2>&1; then
  rfkill block wifi >/dev/null 2>&1
  rfkill block bluetooth >/dev/null 2>&1
fi

echo
echo "Cleanup complete. Remaining active timers (should just be standard Debian/Pi-hole maintenance -- logrotate, fstrim, apt-daily, etc.):"
systemctl list-timers --all --no-pager 2>/dev/null

echo
if [[ -t 0 ]]; then
  read -r -p "Install Pi-hole now? [y/N] " REPLY
else
  REPLY="n"
fi
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  curl -sSL https://install.pi-hole.net | bash
else
  echo "Skipped. Install later with:"
  echo "  curl -sSL https://install.pi-hole.net | bash"
fi

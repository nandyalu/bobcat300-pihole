#!/usr/bin/env bash
# Builds a Debian 13 (Trixie) image for the Bobcat Miner 300 (RK3566), reusing the
# proven bootloader/kernel from sicXnull/Bobcat300-Debian's image while replacing the
# root filesystem userland with a fresh debootstrap.
#
# Run inside a Debian/Ubuntu WSL2 or native Linux environment with root privileges.
# Requires: debootstrap qemu-user-static binfmt-support parted util-linux gdisk kpartx rsync
#
# Usage: build-trixie-image.sh <path-to-BobcatDebian285.img> <output-image-path>
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <path-to-base-.img> <output-image-path>" >&2
  exit 1
fi

BASE_IMG="$1"
OUT_IMG="$2"
WORK=$(mktemp -d)
ROOTFS="$WORK/trixie-rootfs"
trap 'losetup -d "$LOOP" 2>/dev/null || true; umount "$WORK/basemount" 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "== Extracting kernel modules from the base image =="
mkdir -p "$WORK/basemount"
LOOP=$(losetup -fP --show "$BASE_IMG")
mount -o ro "${LOOP}p3" "$WORK/basemount"
mkdir -p "$ROOTFS/lib/modules"
KVER=$(ls "$WORK/basemount/lib/modules")
cp -a "$WORK/basemount/lib/modules/$KVER" "$ROOTFS/lib/modules/"
umount "$WORK/basemount"
losetup -d "$LOOP"

echo "== debootstrap: Debian 13 (trixie) arm64, stage 1 =="
mkdir -p "$ROOTFS"
debootstrap --arch=arm64 --foreign trixie "$ROOTFS" http://deb.debian.org/debian

echo "== debootstrap stage 2 (qemu-aarch64 chroot) =="
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -c '/debootstrap/debootstrap --second-stage'

echo "== apt sources =="
cat > "$ROOTFS/etc/apt/sources.list" << 'APTEOF'
deb http://deb.debian.org/debian trixie main
deb http://deb.debian.org/debian trixie-updates main
deb http://security.debian.org/debian-security trixie-security main
APTEOF

echo "== fstab =="
# Deliberately no /boot entry: the original image never mounts it either (fstab was the
# unconfigured placeholder) since U-Boot reads the boot partition directly, pre-Linux.
cat > "$ROOTFS/etc/fstab" << 'FSTABEOF'
/dev/mmcblk1p3  /      ext4   defaults,noatime  0  1
FSTABEOF

echo "== hostname / hosts =="
echo "bobcat" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" << 'HOSTSEOF'
127.0.0.1   localhost
127.0.1.1   bobcat
::1         localhost ip6-localhost ip6-loopback
HOSTSEOF

echo "== networking (DHCP on eth0) =="
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" << 'IFEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IFEOF

echo "== force eth0 naming (disable predictable network interface naming) =="
mkdir -p "$ROOTFS/etc/udev/rules.d"
ln -sf /dev/null "$ROOTFS/etc/udev/rules.d/80-net-setup-link.rules"

echo "== first-boot resize-to-fill-card service =="
cat > "$ROOTFS/usr/local/sbin/first-boot-resize.sh" << 'RESIZEEOF'
#!/bin/bash
set -e
MARKER=/var/lib/misc/firstboot-resize-done
if [ -f "$MARKER" ]; then
    exit 0
fi
ROOT_DEV=$(findmnt -n -o SOURCE /)
DISK="/dev/${ROOT_DEV#/dev/}"
DISK="${DISK%p3}"
growpart "$DISK" 3 || true
resize2fs "$ROOT_DEV" || true
mkdir -p /var/lib/misc
touch "$MARKER"
RESIZEEOF
chmod +x "$ROOTFS/usr/local/sbin/first-boot-resize.sh"

cat > "$ROOTFS/etc/systemd/system/first-boot-resize.service" << 'SVCEOF'
[Unit]
Description=Resize root filesystem to fill SD card on first boot
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/first-boot-resize.sh
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVCEOF

echo "== chroot: packages, root password, ssh host keys, wifi blacklist =="
mount --bind /dev "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    systemd-sysv systemd-timesyncd dbus openssh-server sudo cron dhcpcd-base ifupdown \
    cloud-guest-utils e2fsprogs kmod iproute2 iputils-ping ca-certificates \
    curl sqlite3 less nano dnsutils
echo "root:bobcat" | chpasswd
sed -i "s/^#PermitRootLogin.*/PermitRootLogin yes/; s/^PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
systemctl enable ssh.service
systemctl enable systemd-timesyncd.service
systemctl enable first-boot-resize.service
sed -i "s/^#RuntimeWatchdogSec=off/RuntimeWatchdogSec=60s/" /etc/systemd/system.conf
depmod -a '"$KVER"'
rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
ssh-keygen -A
apt-get clean
'

umount "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"
rm -f "$ROOTFS/etc/resolv.conf"

echo "== blacklist unused WiFi drivers (Ethernet-only setup; avoids a ~30s boot-time retry storm) =="
mkdir -p "$ROOTFS/etc/modprobe.d"
cat > "$ROOTFS/etc/modprobe.d/blacklist-wifi.conf" << 'BLEOF'
blacklist cywdhd
blacklist mwifiex
blacklist mwifiex_sdio
BLEOF

echo "== machine-id: leave empty (best-effort; this board has no initrd so systemd's =="
echo "== ConditionFirstBoot mechanism can't actually detect first boot here, but an  =="
echo "== empty machine-id is still correct practice for a distributable image)       =="
truncate -s 0 "$ROOTFS/etc/machine-id"
rm -rf "$ROOTFS/var/log/journal"/*

echo "== assembling final image =="
cp "$BASE_IMG" "$OUT_IMG"
LOOP=$(losetup -fP --show "$OUT_IMG")
mkfs.ext4 -F -L rootfs "${LOOP}p3"
mkdir -p "$WORK/newroot"
mount "${LOOP}p3" "$WORK/newroot"
rsync -aAX "$ROOTFS/" "$WORK/newroot/"
mkdir -p "$WORK/newroot"/{boot,proc,sys,dev,run,tmp}
chmod 1777 "$WORK/newroot/tmp"
sync
umount "$WORK/newroot"
losetup -d "$LOOP"

echo "== Done: $OUT_IMG =="
ls -la "$OUT_IMG"

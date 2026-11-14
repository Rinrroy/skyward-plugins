#!/usr/bin/env bash
# Build the full mode's Linux root: a Debian arm64 root file system with
# Chromium in it, plus run.sh, packed as chromium-<version>-arm64.tar.gz.
#
# The recovery installs that tarball into its internal storage and runs
# run.sh inside a chroot, so the root has to be the arm64 one and Chromium
# has to be the Debian build: the recovery's own bionic cannot load it.
#
# Runs on an arm64 Linux box (or the arm64 runner in .github/workflows), with
# debootstrap and sudo available. Needs about 3 GB of disk.
#
#   ./chromium/build.sh 1.0
#
# The output is chromium-<version>-arm64.tar.gz next to the repository root.
#
# The base system is made with the minbase variant alone, and Chromium is
# installed afterwards through apt inside the new root: debootstrap cannot
# finish a base system that already includes Chromium, because some of the
# packages it pulls in (dconf-service) fail to configure while debootstrap
# has the root half set up, and it gives up after five attempts.
set -euo pipefail

VERSION="${1:-1.0}"
ARCH=arm64
SUITE=bookworm
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TOP="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-$TOP/.work/chromium}"
ROOT="$WORK/rootfs"
OUT="$TOP/chromium-$VERSION-arm64.tar.gz"

echo "chrome root: Debian $SUITE $ARCH, version $VERSION"

if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

if ! command -v debootstrap >/dev/null; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq debootstrap
fi

rm -rf "$WORK"
mkdir -p "$WORK"

echo "--- base system"

$SUDO debootstrap --arch="$ARCH" --variant=minbase \
  --include=ca-certificates,busybox \
  "$SUITE" "$ROOT" "$MIRROR"

echo "--- the phone's name servers, and no service left running"

$SUDO mkdir -p "$ROOT/etc"
if [ -s /etc/resolv.conf ]; then
  $SUDO cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
else
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' | $SUDO tee "$ROOT/etc/resolv.conf" >/dev/null
fi
# Nothing in here is started as a service: the phone runs run.sh by hand.
printf '#!/bin/sh\nexit 101\n' | $SUDO tee "$ROOT/usr/sbin/policy-rc.d" >/dev/null
$SUDO chmod 755 "$ROOT/usr/sbin/policy-rc.d"

cleanup() {
  set +e
  for at in dev/pts dev proc sys; do
    $SUDO umount "$ROOT/$at" 2>/dev/null
  done
}
trap cleanup EXIT

$SUDO mount -t proc proc "$ROOT/proc"
$SUDO mount -t sysfs sysfs "$ROOT/sys"
$SUDO mount --bind /dev "$ROOT/dev"
$SUDO mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || true

echo "--- chromium"

# --no-install-recommends keeps the root to what the browser links against
# and what it reads: sound servers, avahi and the like are left out.
$SUDO chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get update -qq
$SUDO chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y -qq --no-install-recommends \
  chromium fonts-noto-cjk fonts-dejavu-core

cleanup
trap - EXIT

echo "--- run.sh, and what a headless browser never reads"

$SUDO cp "$HERE/run.sh" "$ROOT/run.sh"
$SUDO chmod 755 "$ROOT/run.sh"

$SUDO rm -rf "$ROOT/usr/share/doc" "$ROOT/usr/share/man" "$ROOT/usr/share/info" \
  "$ROOT/usr/share/lintian" "$ROOT/usr/lib/chromium/locales"/* \
  "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt/archives"/*.deb
$SUDO mkdir -p "$ROOT/tmp" "$ROOT/dev/shm" "$ROOT/root" "$ROOT/etc/ssl/certs"
$SUDO chmod 1777 "$ROOT/tmp" "$ROOT/dev/shm"

# Chromium refuses to start as root without these two, and the recovery runs
# as root; both are inside the root, so nothing on the phone is loosened.
echo "chrome-headless" | $SUDO tee "$ROOT/etc/hostname" >/dev/null

echo "--- packing"

$SUDO tar -C "$ROOT" --numeric-owner -czf "$OUT" .
ls -l "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"

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

command -v debootstrap >/dev/null || $SUDO apt-get update -qq && $SUDO apt-get install -y -qq debootstrap

rm -rf "$WORK"
mkdir -p "$WORK"

# minbase first, then the packages the browser needs. fonts-noto-cjk is not
# optional: without it Chinese pages draw as boxes.
$SUDO debootstrap --arch="$ARCH" --variant=minbase \
  --include=ca-certificates,chromium,fonts-noto-cjk,fonts-dejavu-core,busybox \
  "$SUITE" "$ROOT" "$MIRROR"

$SUDO cp "$HERE/run.sh" "$ROOT/run.sh"
$SUDO chmod 755 "$ROOT/run.sh"

# Strip what a headless browser never reads, so the tarball stays small
# enough to move onto a phone by hand.
$SUDO rm -rf "$ROOT/usr/share/doc" "$ROOT/usr/share/man" "$ROOT/usr/share/info" \
  "$ROOT/usr/share/lintian" "$ROOT/usr/lib/chromium/locales"/* \
  "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt/archives"/*.deb
$SUDO mkdir -p "$ROOT/tmp" "$ROOT/dev/shm" "$ROOT/root"
$SUDO chmod 1777 "$ROOT/tmp" "$ROOT/dev/shm"

# Chromium refuses to start as root without these two, and the recovery runs
# as root; both are inside the root, so nothing on the phone is loosened.
echo "chrome-headless" | $SUDO tee "$ROOT/etc/hostname" >/dev/null

command -v chroot >/dev/null && $SUDO chroot "$ROOT" /usr/lib/chromium/chromium --version 2>/dev/null \
  | tee "$WORK/version.txt" || true

$SUDO tar -C "$ROOT" --numeric-owner -czf "$OUT" .
ls -l "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"

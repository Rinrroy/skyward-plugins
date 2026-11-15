#!/usr/bin/env bash
# Build the full mode's Linux root: a Debian arm64 root file system with
# Chromium in it, plus run.sh, packed as chromium-<version>-arm64.tar.gz.
#
# The recovery installs that tarball into its internal storage and runs
# run.sh inside a chroot, so the root has to be the arm64 one and Chromium
# has to be a glibc build: the recovery's own bionic cannot load it. The
# Chromium itself is Raspberry Pi OS's, for the codecs it keeps (below).
#
# Runs on an arm64 Linux box (or the arm64 runner in .github/workflows), with
# debootstrap, curl and sudo available. Needs about 4 GB of disk.
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
# Raspberry Pi OS builds this Chromium with the proprietary codecs left in:
# H.264 decodes through Cisco's OpenH264, which is why the binary depends on
# libopenh264-7, and AAC through the decoder it carries itself. Debian cannot
# ship those, so its build answers "no" to every MP4 the pages offer. The rest
# of the browser is the same, it is still arm64 glibc (it asks for 2.35, and
# bookworm has 2.36), and the libraries it newly needs are all in bookworm
# main, so apt inside the new root can resolve them.
CHROMIUM_VERSION="156.0.8078.79-1~deb12u1+rpt1"
CHROMIUM_POOL="http://archive.raspberrypi.com/debian/pool/main/c/chromium"
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

# The browser is Raspberry Pi OS's build, for the codecs it keeps. Its own
# package cannot be installed, though: chromium-common there depends on a name
# Debian does not have (zenoty), so apt refuses the pair outright. The root
# therefore gets Debian's chromium first — that is what brings in every library
# this browser links against — and then the Pi files are laid over it, which
# replaces the browser, resources.pak and the locale pack with the 156 ones.
mkdir -p "$WORK/debs"
for deb in "chromium_${CHROMIUM_VERSION}_arm64.deb" \
  "chromium-common_${CHROMIUM_VERSION}_arm64.deb"; do
  curl -fsSL -o "$WORK/debs/$deb" "$CHROMIUM_POOL/$deb"
done

# --no-install-recommends keeps the root to what the browser links against
# and what it reads: sound servers, avahi and the like are left out.
# libopenh264-7 is the H.264 decoder the Pi build links, and libxnvctrl0 a
# library it names that Debian's own chromium never asks for.
$SUDO chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get update -qq
$SUDO chroot "$ROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
  /usr/bin/apt-get install -y -qq --no-install-recommends \
  chromium libopenh264-7 libxnvctrl0 fonts-noto-cjk fonts-dejavu-core

for deb in "$WORK/debs"/*.deb; do
  $SUDO dpkg-deb -x "$deb" "$ROOT"
done

# The whole reason for this build is that it can decode H.264, and it can
# because it links Cisco's decoder rather than carrying one of its own. If a
# future archive leaves this out, the pack would look fine and play nothing,
# so the pack is not made at all.
if ! ls "$ROOT"/usr/lib/*/libopenh264.so.* >/dev/null 2>&1; then
  echo "this Chromium has no OpenH264, so it cannot decode H.264" >&2
  exit 1
fi

# Laid over Debian's chromium, the Pi binary has to find everything it was
# linked against; a library left behind would show up on the phone as a
# browser that never starts.
missing=$($SUDO chroot "$ROOT" /usr/bin/env \
  LD_LIBRARY_PATH=/usr/lib/chromium:/usr/lib/aarch64-linux-gnu \
  /usr/bin/ldd /usr/lib/chromium/chromium 2>/dev/null | grep 'not found' || true)
if [ -n "$missing" ]; then
  echo "this Chromium is missing libraries the phone cannot give it:" >&2
  echo "$missing" >&2
  exit 1
fi

cleanup
trap - EXIT

echo "--- run.sh, and what a headless browser never reads"

$SUDO cp "$HERE/run.sh" "$ROOT/run.sh"
$SUDO chmod 755 "$ROOT/run.sh"

# The locale file stays. Chromium loads it as a data pack and asks it for
# every localized word the browser itself says; with locales/ empty it stops
# on the first one it wants, as a trap with no message before it (the page
# the recovery draws then only ever says the connection timed out). Only
# en-US is kept: run.sh sets no LANG, so en-US is the locale Chromium
# resolves, and the other languages cost download and nothing else.
$SUDO rm -rf "$ROOT/usr/share/doc" "$ROOT/usr/share/man" "$ROOT/usr/share/info" \
  "$ROOT/usr/share/lintian" \
  "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt/archives"/*.deb
$SUDO find "$ROOT/usr/lib/chromium/locales" -type f ! -name 'en-US.pak' -delete
if [ ! -s "$ROOT/usr/lib/chromium/locales/en-US.pak" ]; then
  echo "the locale file Chromium stops without is not in the root" >&2
  exit 1
fi

# Video is decoded on the processor. H.264 comes through OpenH264 and AAC
# through the decoder inside the binary; VP8, VP9 and AV1 have always worked.
# Those two are what nearly every mobile site serves, which is why the pack
# uses this build of Chromium rather than Debian's.
echo "$VERSION" | $SUDO tee "$WORK/version.txt" >/dev/null
$SUDO mkdir -p "$ROOT/tmp" "$ROOT/dev/shm" "$ROOT/root" "$ROOT/etc/ssl/certs"
$SUDO chmod 1777 "$ROOT/tmp" "$ROOT/dev/shm"

# Chromium refuses to start as root without these two, and the recovery runs
# as root; both are inside the root, so nothing on the phone is loosened.
echo "chrome-headless" | $SUDO tee "$ROOT/etc/hostname" >/dev/null

echo "--- packing"

$SUDO tar -C "$ROOT" --numeric-owner -czf "$OUT" .
ls -l "$OUT"
sha256sum "$OUT" | tee "$OUT.sha256"

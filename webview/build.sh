#!/bin/bash
# Build the browser payload: a Debian arm64 rootfs holding Chromium, an X
# server, Mesa and udev, packed into one image the recovery can mount.
#
# Run on an arm64 machine (the CI runner is ubuntu-24.04-arm): debootstrap for
# a foreign architecture needs qemu, which is one more thing to go wrong.
#
# The display is Xvfb, and this is the third answer to the same question.
#
# A Wayland compositor cannot work: the kernel is built with CONFIG_VT unset, so
# libseat can never mark a session active.
#
# Xorg with the modesetting driver cannot work either, and that was measured
# rather than guessed: it opens the card, reaches screen initialisation, and
# segfaults inside modesetting_drv.so while describing the card's outputs to
# RandR (gdb: AddScreen -> xf86CrtcScreenInit -> xf86RandR12Init ->
# RRChangeOutputProperty -> crash). One output, four outputs, glamor, shadow,
# software cursor, no cursor, ZaphodHeads -- the same place every time.
#
# So the payload stops asking the card for anything. Xvfb draws into a plain
# memory framebuffer it owns, and `-fbdir` writes that framebuffer to a file the
# recovery can mmap: the recovery puts those pixels on the panel itself, since
# it already has the card, a drawing surface and the touch screen. A finger
# reaches the page the other way round, as one line per touch into a FIFO that
# this payload turns into an xdotool command.
#
# The image is erofs, not squashfs, and that is not a preference: the recovery
# mounts the phone's own system partitions with erofs, so the kernel in the
# ramdisk is certain to read it. squashfs depends on a kernel option Android
# does not always turn on, and a payload that cannot be mounted is a browser
# that cannot start.
set -euo pipefail

SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
ROOT="rootfs"
OUT="${OUT:-webview-arm64.erofs}"

sudo apt-get update
sudo apt-get install --yes --no-install-recommends debootstrap erofs-utils zstd

rm -rf "$ROOT"
sudo debootstrap --arch=arm64 --variant=minbase --include=ca-certificates \
    "$SUITE" "$ROOT" "$MIRROR"

sudo chroot "$ROOT" apt-get update
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends \
    chromium libinput10 udev libgl1-mesa-dri libegl-mesa0 libgbm1 \
    fonts-noto-cjk fonts-noto-color-emoji ca-certificates xdg-utils

# Xvfb is the display: it never touches the card, so it cannot hit the crash the
# modesetting driver hits. xdotool is how a finger gets from the recovery's touch
# screen into the page, and x11-utils is for the one question worth asking of a
# display server (how big is it). xkb-data is the keymap the browser reads.
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends \
    xvfb x11-utils xdotool xkb-data \
    || echo "the display did not install; the browser will have nowhere to draw"
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends xvkbd \
    || echo "no on-screen keyboard; the page can be looked at but not typed into"

# A debugger, because a display server that dies during screen initialisation
# reports an address and not a place, and a stack trace is what turns the next
# attempt into an answer instead of a guess. About thirty megabytes.
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends gdb \
    || echo "no debugger in the image; a crash will only be an address"

# The default search engine, the home page, and nothing that phones home.
sudo mkdir -p "$ROOT/etc/chromium/policies/managed"
sudo tee "$ROOT/etc/chromium/policies/managed/skyward.json" > /dev/null <<'POLICY'
{
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderName": "Bing",
  "DefaultSearchProviderSearchURL": "https://cn.bing.com/search?q={searchTerms}",
  "DefaultSearchProviderSuggestURL": "https://cn.bing.com/qsearch?q={searchTerms}",
  "HomepageLocation": "https://cn.bing.com",
  "HomepageIsNewTabPage": false,
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["https://cn.bing.com"],
  "MetricsReportingEnabled": false,
  "BreakpadEnabled": false,
  "BackgroundModeEnabled": false,
  "PasswordManagerEnabled": false
}
POLICY

# Xvfb needs no configuration file: it has no card to be told about, and the
# screen size is passed on its command line.


# The launcher, and the mountpoints the recovery binds into.
sudo mkdir -p "$ROOT/opt/skyward"
sudo cp webview/start.sh "$ROOT/opt/skyward/start.sh"
sudo chmod 0755 "$ROOT/opt/skyward/start.sh"
sudo mkdir -p "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/tmp" "$ROOT/run" "$ROOT/data"
sudo chmod 1777 "$ROOT/tmp"

# resolv.conf must be a file the recovery can write, not a link into a
# resolver that is not running.
sudo rm -f "$ROOT/etc/resolv.conf"
sudo tee "$ROOT/etc/resolv.conf" > /dev/null <<'CONF'
nameserver 223.5.5.5
nameserver 119.29.29.29
CONF

# Nothing here boots; the recovery starts one program by hand.
sudo rm -rf "$ROOT/var/lib/apt/lists" "$ROOT/var/cache/apt" "$ROOT/usr/share/doc" "$ROOT/usr/share/man"

sudo du -sh "$ROOT"
# Which compressor erofs-utils can reach depends on how it was built; an image
# that is merely larger is worth more than a run that stops here.
if ! sudo mkfs.erofs -zlz4hc,9 "$OUT" "$ROOT"; then
    echo "no lz4hc; trying zstd"
    if ! sudo mkfs.erofs -zzstd "$OUT" "$ROOT"; then
        echo "no zstd either; packing it plain"
        sudo mkfs.erofs "$OUT" "$ROOT"
    fi
fi
ls -l "$OUT"
sha256sum "$OUT"

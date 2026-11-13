#!/bin/bash
# Build the browser payload: a Debian arm64 rootfs holding Chromium, an X
# server, Mesa and udev, packed into one image the recovery can mount.
#
# Run on an arm64 machine (the CI runner is ubuntu-24.04-arm): debootstrap for
# a foreign architecture needs qemu, which is one more thing to go wrong.
#
# The display is an X server, not a Wayland compositor, and that is forced by
# the kernel: it is built with CONFIG_VT unset, so libseat can never mark a
# session active and every compositor that goes through it dies before it makes
# a socket. Xorg's modesetting driver opens /dev/dri itself and needs no seat.
#
# It has to be told what to ignore. The card this phone exposes advertises three
# outputs besides the panel -- two "Virtual" connectors the vendor driver keeps
# for screen recording, and a DisplayPort that is not plugged into anything --
# and the modesetting driver puts all of them into one screen at their bounding
# box. That is a 1920x3200 framebuffer for a 1440x3200 panel, and three CRTCs
# sharing one card, and with it Xorg segfaults during screen initialisation
# before it makes a socket. The config below turns the three of them off and
# leaves the panel; glamor is off as well, because it refuses to run on llvmpipe
# anyway ("Refusing to try glamor on llvmpipe") and the software path it falls
# back to is the one that works.
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

# The panel has no virtual terminal to hand to a compositor (`CONFIG_VT is not
# set`), so the display comes from an X server, whose modesetting driver opens
# the card itself. The keyboard is an X client too: nothing else can type.
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends \
    xserver-xorg-core xserver-xorg-input-libinput xkb-data x11-utils \
    || echo "the X server did not install; the browser will have no display"
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends xvkbd \
    || echo "no on-screen keyboard; the page can be looked at but not typed into"

# A debugger, because the X server dies inside its own screen initialisation
# and the address it reports is not a place: a stack trace is. The image pays
# about thirty megabytes for being able to answer "where" instead of guessing.
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

# What Xorg is told about this phone's card: one screen, the panel only.
sudo mkdir -p "$ROOT/etc/X11/xorg.conf.d"
sudo tee "$ROOT/etc/X11/xorg.conf.d/20-skyward.conf" > /dev/null <<'XCONF'
# Three outputs this phone's card advertises but this display does not use.
# "Ignore" is what keeps them out of the screen: without it the modesetting
# driver builds one screen at the bounding box of all four and dies.
Section "Monitor"
    Identifier "ignored-virtual-1"
    Option "Ignore" "true"
EndSection

Section "Monitor"
    Identifier "ignored-virtual-2"
    Option "Ignore" "true"
EndSection

Section "Monitor"
    Identifier "ignored-dp"
    Option "Ignore" "true"
EndSection

Section "Monitor"
    Identifier "panel"
EndSection

Section "Device"
    Identifier "gpu"
    Driver "modesetting"
    # glamor refuses to initialise on llvmpipe and then falls back anyway; the
    # fallback is the path that works, so it is asked for directly.
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
    Option "EnablePageFlip" "false"
    Option "Monitor-Virtual-1" "ignored-virtual-1"
    Option "Monitor-Virtual-2" "ignored-virtual-2"
    Option "Monitor-DP-1" "ignored-dp"
    Option "Monitor-DSI-1" "panel"
EndSection

Section "Screen"
    Identifier "screen"
    Device "gpu"
    DefaultDepth 24
EndSection

Section "ServerLayout"
    Identifier "layout"
    Screen "screen"
EndSection
XCONF

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

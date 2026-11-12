#!/bin/sh
# What runs inside the payload when the recovery hands the phone over.
#
# The recovery has already done the parts that need its privileges: the image
# is mounted at /, /dev /proc /sys /data are bound in, /etc/resolv.conf holds
# the DHCP answer, and the DRM card has been released. This script starts the
# two daemons Chromium expects on a Linux desktop and then gets out of the
# way.
set -e

export HOME=/data/skyward/browser
export XDG_RUNTIME_DIR=/run/skyward
export XDG_CACHE_HOME=/data/skyward/browser/cache
export XDG_CONFIG_HOME=/data/skyward/browser/config
export XDG_DATA_HOME=/data/skyward/browser/data

mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
chmod 700 "$XDG_RUNTIME_DIR"

# The recovery mounts a tmpfs here; if it did not, make one.
mountpoint -q /run || mount -t tmpfs -o mode=0755 tmpfs /run

# udev, so libinput finds the touchscreen: it reads /sys, which the recovery
# bound in, and writes the database libinput reads from /run/udev.
if command -v udevadm > /dev/null 2>&1; then
    if ! pgrep -x systemd-udevd > /dev/null 2>&1; then
        systemd-udevd --daemon || true
    fi
    udevadm trigger --action=add || true
    udevadm settle --timeout=10 || true
fi

# Weston owns the DRM card; Chromium draws into it over Wayland. Kiosk shell
# because there is no desktop here: one window, full screen, no chrome.
if ! pgrep -x weston > /dev/null 2>&1; then
    weston --backend=drm-backend.so --shell=kiosk-shell.so \
        --idle-time=0 --log=/tmp/weston.log &
    # Give it the panel before Chromium asks for it.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -S "$XDG_RUNTIME_DIR/wayland-0" ] && break
        sleep 0.25
    done
fi

# --no-sandbox because the payload runs as root inside a chroot that has
# nothing else in it; there is no other user to drop to, and the alternative
# is a browser that cannot start.
exec chromium \
    --ozone-platform=wayland \
    --kiosk \
    --no-sandbox \
    --no-first-run \
    --no-default-browser-check \
    --disable-dev-shm-usage \
    --user-data-dir="$HOME/profile" \
    --start-fullscreen \
    "${SKYWARD_START_URL:-https://cn.bing.com}"

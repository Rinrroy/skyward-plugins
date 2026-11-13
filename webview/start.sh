#!/bin/sh
# What runs inside the payload when the recovery hands the phone over.
#
# The recovery has already done the parts that need its privileges: the image
# is mounted at /, /dev /proc /sys /data are bound in, /etc/resolv.conf holds
# the DHCP answer, and the DRM card has been released.
#
# This kernel is built without virtual terminals -- `# CONFIG_VT is not set` --
# and that closes one door for good: libseat marks a session active by opening
# tty0, so no compositor that goes through it can ever open the card. Weston
# dies with "Could not open VT for client" before it makes a socket, which is
# why Chromium used to report "Failed to connect to Wayland display".
#
# An X server needs no seat. Its modesetting driver opens /dev/dri itself and
# -sharevts keeps it out of VT handling entirely, and the Chromium in this
# image was built with the x11 ozone platform. So: X owns the panel, Chromium
# draws into it, and everything this script says goes to a log a person can
# read over adb.
set -u

LOG=/data/skyward/browser/logs
mkdir -p "$LOG" 2>/dev/null
exec >>"$LOG/start.log" 2>&1
echo "--- start: $(date)"

export HOME=/data/skyward/browser
export XDG_CACHE_HOME="$HOME/cache"
export XDG_CONFIG_HOME="$HOME/config"
export XDG_DATA_HOME="$HOME/data"
export XDG_RUNTIME_DIR=/run/skyward
export TMPDIR=/tmp
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

mountpoint -q /run 2>/dev/null || mount -t tmpfs -o mode=0755 tmpfs /run \
    || echo "no tmpfs on /run"
mkdir -p /dev/shm
mountpoint -q /dev/shm 2>/dev/null || mount -t tmpfs -o mode=1777 tmpfs /dev/shm \
    || echo "no tmpfs on /dev/shm"
# The image is mounted read-only and Xorg wants somewhere to put compiled
# keymaps; a tmpfs there keeps it from complaining about a read-only /var.
mkdir -p /var/lib/xkb 2>/dev/null
mountpoint -q /var/lib/xkb 2>/dev/null || mount -t tmpfs -o mode=0755 tmpfs /var/lib/xkb \
    || echo "no tmpfs on /var/lib/xkb"

# udev, so libinput finds the touchscreen. `systemd-udevd` is not on PATH in
# this suite: the file is a link to udevadm, a multicall binary, and it has to
# be started by its real name. udevadm itself refuses inside a chroot
# ("Running in chroot, ignoring request"), so the kernel is told about each
# input device directly instead.
if [ -x /usr/lib/systemd/systemd-udevd ] && ! pgrep -x systemd-udevd > /dev/null 2>&1; then
    /usr/lib/systemd/systemd-udevd --daemon || echo "udevd did not start"
fi
for u in /sys/class/input/event*/uevent; do
    [ -w "$u" ] && echo add > "$u"
done

URL="${SKYWARD_START_URL:-https://cn.bing.com}"

XORG=/usr/lib/xorg/Xorg
if [ ! -x "$XORG" ]; then
    echo "no X server in this payload"
    exit 1
fi

rm -f /tmp/.X11-unix/X0
"$XORG" :0 -sharevts -novtswitch -noreset -nolisten tcp \
    -logfile "$LOG/xorg.log" &
XPID=$!
i=0
while [ "$i" -lt 80 ]; do
    [ -S /tmp/.X11-unix/X0 ] && break
    kill -0 "$XPID" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
done
if [ ! -S /tmp/.X11-unix/X0 ]; then
    echo "the X server did not come up; see $LOG/xorg.log"
    kill "$XPID" 2>/dev/null
    exit 1
fi
echo "x is up"

export DISPLAY=:0

# How big the panel is, so the keyboard can be told where to sit. Without a
# window manager nothing places windows, so every size here is asked for.
WIDTH=1440
HEIGHT=3200
if command -v xdpyinfo > /dev/null 2>&1; then
    SIZE=$(xdpyinfo -display :0 | awk '/dimensions:/ {print $2; exit}')
    case "$SIZE" in
        *x*) WIDTH=${SIZE%x*}; HEIGHT=${SIZE#*x} ;;
    esac
fi
echo "panel is ${WIDTH}x${HEIGHT}"

# A keyboard that can be touched: a captive portal cannot be answered, and a
# search cannot be typed, without one. It starts after the browser so that it
# is mapped on top of it.
if [ -x /usr/bin/xvkbd ]; then
    (
        sleep 6
        exec /usr/bin/xvkbd -geometry "$((WIDTH * 9 / 10))x$((HEIGHT / 4))-0-0" \
            -no-keypad -windowed
    ) &
fi

# --no-sandbox because the payload runs as root inside a chroot that has
# nothing else in it; there is no other user to drop to, and the alternative
# is a browser that cannot start.
#
# There is no window manager, so nothing else will give the window a size: the
# geometry is asked for here. The first attempt keeps the GPU; a browser that
# dies on the GPU path is worth one more try without it, because a page that
# scrolls slowly is worth more than a black panel.
browser() {
    /usr/lib/chromium/chromium \
        --ozone-platform=x11 \
        --kiosk \
        --start-fullscreen \
        --window-position=0,0 \
        --window-size="$WIDTH,$HEIGHT" \
        --no-sandbox \
        --no-first-run \
        --no-default-browser-check \
        --disable-dev-shm-usage \
        --user-data-dir="$HOME/profile" \
        "$@" \
        "$URL"
}

browser
RC=$?
echo "chromium exited $RC"
if [ "$RC" -ne 0 ]; then
    echo "trying again without the gpu"
    exec /usr/lib/chromium/chromium \
        --ozone-platform=x11 \
        --kiosk \
        --start-fullscreen \
        --window-position=0,0 \
        --window-size="$WIDTH,$HEIGHT" \
        --disable-gpu \
        --disable-gpu-compositing \
        --no-sandbox \
        --no-first-run \
        --no-default-browser-check \
        --disable-dev-shm-usage \
        --user-data-dir="$HOME/profile" \
        "$URL"
fi
exit "$RC"

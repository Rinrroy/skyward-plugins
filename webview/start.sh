#!/bin/sh
# What runs inside the payload when the recovery hands the phone over.
#
# The recovery has already done the parts that need its privileges: the image
# is mounted at /, /dev /proc /sys /data are bound in, /etc/resolv.conf holds
# the DHCP answer, and the DRM card has been released.
#
# This kernel is built without virtual terminals -- `# CONFIG_VT is not set` --
# and that closes one door for good: libseat marks a session active by opening
# tty0, so no compositor that goes through it can ever open the card. An X
# server needs no seat: its modesetting driver opens /dev/dri itself and
# -sharevts keeps it out of VT handling.
#
# It does not come up on the first try, and the log it leaves says why: it
# reaches "Silken mouse enabled" during screen initialisation and segfaults at
# address 0. So the X server is not started once and hoped for -- several
# variations are tried in turn, each with a log of its own, and whichever makes
# its socket is the one the browser gets. Everything is narrated into
# /data/skyward/browser/logs/start.log, which the recovery copies to internal
# storage when the payload ends.
set -u

LOG=/data/skyward/browser/logs
mkdir -p "$LOG" 2>/dev/null
exec >>"$LOG/start.log" 2>&1
rm -f "$LOG"/xorg-*.log "$LOG"/x-*.out
echo "--- start: $(date)"
echo "kernel: $(uname -r 2>/dev/null)"

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
mkdir -p /var/lib/xkb 2>/dev/null
mountpoint -q /var/lib/xkb 2>/dev/null || mount -t tmpfs -o mode=0755 tmpfs /var/lib/xkb \
    || echo "no tmpfs on /var/lib/xkb"

echo "--- the card, as the kernel sees it"
ls -l /dev/dri 2>&1
for conn in /sys/class/drm/card0-*/status; do
    [ -r "$conn" ] && echo "$conn: $(cat "$conn")"
done

if [ -x /usr/lib/systemd/systemd-udevd ] && ! pgrep -x systemd-udevd > /dev/null 2>&1; then
    /usr/lib/systemd/systemd-udevd --daemon || echo "udevd did not start"
fi
for u in /sys/class/input/event*/uevent; do
    [ -w "$u" ] && echo add > "$u"
done

URL="${SKYWARD_START_URL:-https://cn.bing.com}"

XORG=""
for candidate in /usr/lib/xorg/Xorg /usr/bin/Xorg /usr/lib/xorg/Xorg.wrap; do
    if [ -x "$candidate" ]; then XORG="$candidate"; break; fi
done
if [ -z "$XORG" ] && command -v Xorg > /dev/null 2>&1; then XORG=$(command -v Xorg); fi
if [ -z "$XORG" ]; then
    echo "no X server in this payload; /usr/lib/xorg holds:"
    ls -l /usr/lib/xorg 2>&1
    exit 1
fi
echo "x server: $XORG"
"$XORG" -version 2>&1 || true

# The config the image carries, and two variations made from it here: one that
# keeps the cursor in software (the hardware cursor is initialised right where
# the crash is), and one that goes back to glamor.
CONF=/etc/X11/xorg.conf.d/20-skyward.conf
{
    cat "$CONF"
    printf '\nSection "ServerFlags"\n    Option "SWcursor" "true"\nEndSection\n'
} > /tmp/swcursor.conf
sed 's/"none"/"glamor"/; s/"ShadowFB" "true"/"ShadowFB" "false"/' "$CONF" > /tmp/glamor.conf

mkdir -p /tmp/.X11-unix

# Starts the server once and waits for its socket. Returns 0 when it is up.
try_x() {
    name=$1
    shift
    rm -f /tmp/.X11-unix/X0
    "$XORG" :0 -sharevts -novtswitch -noreset -nolisten tcp \
        -logfile "$LOG/xorg-$name.log" "$@" >>"$LOG/x-$name.out" 2>&1 &
    XPID=$!
    i=0
    while [ "$i" -lt 80 ]; do
        [ -S /tmp/.X11-unix/X0 ] && return 0
        kill -0 "$XPID" 2>/dev/null || break
        sleep 0.25
        i=$((i + 1))
    done
    kill -9 "$XPID" 2>/dev/null
    wait "$XPID" 2>/dev/null
    echo "--- $name did not come up; last of its log:"
    tail -n 14 "$LOG/xorg-$name.log" 2>&1
    return 1
}

XUP=""
for attempt in plain swcursor nocursor glamor; do
    [ -n "$XUP" ] && break
    echo "--- X server, attempt: $attempt"
    case "$attempt" in
        plain)    try_x plain -config "$CONF" && XUP=plain ;;
        swcursor) try_x swcursor -config /tmp/swcursor.conf && XUP=swcursor ;;
        nocursor) try_x nocursor -config "$CONF" -nocursor && XUP=nocursor ;;
        glamor)   try_x glamor -config /tmp/glamor.conf && XUP=glamor ;;
    esac
done

if [ -z "$XUP" ]; then
    echo "--- no X server came up; asking a debugger where it died"
    if [ -x /usr/bin/gdb ]; then
        timeout 90 /usr/bin/gdb -batch \
            -ex "set confirm off" -ex "set pagination off" -ex run \
            -ex "bt" -ex "thread apply all bt" -ex "info registers" \
            --args "$XORG" :0 -sharevts -novtswitch -noreset -nolisten tcp \
            -config "$CONF" -logfile /tmp/gdb-xorg.log 2>&1 | tail -n 80
    else
        echo "no debugger in this payload"
    fi
    # The browser still gets a chance: headless needs no display server, and a
    # screenshot proves the engine and the network work even when the panel
    # path does not.
    echo "--- chromium, headless, one screenshot"
    timeout 120 /usr/lib/chromium/chromium --headless=new --no-sandbox \
        --disable-gpu --user-data-dir="$HOME/profile" \
        --screenshot=/data/skyward/browser/logs/headless.png \
        --window-size=1440,3200 "$URL" 2>&1 | tail -n 20
    exit 1
fi
echo "--- x is up (attempt: $XUP)"

export DISPLAY=:0

WIDTH=1440
HEIGHT=3200
if command -v xdpyinfo > /dev/null 2>&1; then
    SIZE=$(xdpyinfo -display :0 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    case "$SIZE" in
        *x*) WIDTH=${SIZE%x*}; HEIGHT=${SIZE#*x} ;;
    esac
fi
echo "panel is ${WIDTH}x${HEIGHT}"

if [ -x /usr/bin/xvkbd ]; then
    (
        sleep 6
        exec /usr/bin/xvkbd -geometry "$((WIDTH * 9 / 10))x$((HEIGHT / 4))-0-0" \
            -no-keypad -windowed
    ) &
fi

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

if [ ! -x /usr/lib/chromium/chromium ]; then
    echo "no browser binary at /usr/lib/chromium/chromium; /usr/lib/chromium holds:"
    ls /usr/lib/chromium 2>&1
    exit 1
fi

echo "--- chromium, first attempt"
browser
RC=$?
echo "chromium exited $RC"
if [ "$RC" -ne 0 ]; then
    echo "--- chromium, second attempt without the gpu"
    browser --disable-gpu --disable-gpu-compositing
    RC=$?
    echo "chromium exited $RC on the second attempt"
fi
exit "$RC"

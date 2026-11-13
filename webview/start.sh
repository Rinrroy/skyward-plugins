#!/bin/sh
# What runs inside the payload when the recovery hands the phone over.
#
# The recovery has already done the parts that need its privileges: the image
# is mounted at /, /dev /proc /sys /data are bound in, /etc/resolv.conf holds
# the DHCP answer, and the DRM card has been released.
#
# Two display servers have now been measured on this phone and neither works:
#
#   weston / cage / wlroots -- need a seat, and this kernel has no VT
#                              (`# CONFIG_VT is not set`), so libseat can never
#                              mark a session active;
#   Xorg with modesetting   -- opens the card itself, then segfaults inside
#                              modesetting_drv.so while describing the card's
#                              outputs to RandR (gdb: AddScreen ->
#                              xf86CrtcScreenInit -> xf86RandR12Init ->
#                              RRChangeOutputProperty -> crash), with one output,
#                              four outputs, glamor, shadow, no cursor -- the
#                              same place every time.
#
# So the payload no longer asks the card for anything. Xvfb draws into a plain
# memory framebuffer of its own (`-fbdir` writes it to a file that its owner can
# mmap), Chromium draws into Xvfb, and the recovery puts those pixels on the
# panel itself -- it already has the card, a drawing surface and the touch
# screen. Input comes back the other way: the recovery writes one line per touch
# into a FIFO and the loop below turns it into an xdotool command.
set -u

LOG=/data/skyward/browser/logs
FB=/data/skyward/browser/fb
mkdir -p "$LOG" "$FB" 2>/dev/null
exec >>"$LOG/start.log" 2>&1
rm -f "$LOG"/xorg-*.log "$LOG"/x-*.out "$LOG"/xvfb.out
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

echo "--- the card, as the kernel sees it"
ls -l /dev/dri 2>&1

if [ -x /usr/lib/systemd/systemd-udevd ] && ! pgrep -x systemd-udevd > /dev/null 2>&1; then
    /usr/lib/systemd/systemd-udevd --daemon || echo "udevd did not start"
fi
for u in /sys/class/input/event*/uevent; do
    [ -w "$u" ] && echo add > "$u"
done

URL="${SKYWARD_START_URL:-https://cn.bing.com}"
TOUCH=/data/skyward/browser/touch.fifo

if [ ! -x /usr/bin/Xvfb ]; then
    echo "no Xvfb in this payload"
    exit 1
fi

rm -f "$FB"/Xvfb_screen0 /tmp/.X11-unix/X0
mkdir -p /tmp/.X11-unix
echo "--- starting Xvfb into $FB"
/usr/bin/Xvfb :0 -screen 0 1440x3200x24 -fbdir "$FB" -nolisten tcp \
    -nolisten local >"$LOG/xvfb.out" 2>&1 &
XPID=$!
i=0
while [ "$i" -lt 80 ]; do
    [ -S /tmp/.X11-unix/X0 ] && break
    kill -0 "$XPID" 2>/dev/null || break
    sleep 0.25
    i=$((i + 1))
done
if [ ! -S /tmp/.X11-unix/X0 ]; then
    echo "Xvfb did not come up; its own words:"
    cat "$LOG/xvfb.out" 2>&1
    exit 1
fi
echo "--- Xvfb is up"
ls -l "$FB" 2>&1

export DISPLAY=:0

fingerprint() {
    head -c 300000 "$FB/Xvfb_screen0" 2>/dev/null | md5sum | cut -d' ' -f1
}

WIDTH=1440
HEIGHT=3200
if command -v xdpyinfo > /dev/null 2>&1; then
    SIZE=$(xdpyinfo -display :0 2>/dev/null | awk '/dimensions:/ {print $2; exit}')
    case "$SIZE" in
        *x*) WIDTH=${SIZE%x*}; HEIGHT=${SIZE#*x} ;;
    esac
fi
echo "panel is ${WIDTH}x${HEIGHT}"
echo "framebuffer before the browser draws: $(fingerprint)"

if [ -x /usr/bin/xvkbd ]; then
    KEYBOARD=yes
else
    KEYBOARD=no
fi

# Asked for by the recovery, which owns the touch screen: "kbd on" puts the
# keyboard on the page, "kbd off" takes it away again.
keyboard() {
    case "${1:-}" in
        on)
            if [ "$KEYBOARD" = yes ] && ! pgrep -x xvkbd > /dev/null 2>&1; then
                /usr/bin/xvkbd -geometry "$((WIDTH * 9 / 10))x$((HEIGHT / 4))-0-0" \
                    -no-keypad -no-jump-pointer >/dev/null 2>&1 &
                echo "keyboard up"
            fi
            ;;
        off)
            pkill -x xvkbd > /dev/null 2>&1 && echo "keyboard down"
            ;;
    esac
}

if [ ! -x /usr/lib/chromium/chromium ]; then
    echo "no browser binary at /usr/lib/chromium/chromium"
    ls /usr/lib/chromium 2>&1
    exit 1
fi

# A page is shown to a site as the phone it is running on; without this the
# mobile layouts, the touch behaviour and the login pages all answer as if this
# were a desktop browser.
UA="Mozilla/5.0 (Linux; Android 15; 2410DPN6CC) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"

echo "--- chromium, first attempt"
/usr/lib/chromium/chromium \
    --ozone-platform=x11 \
    --kiosk \
    --start-fullscreen \
    --window-position=0,0 \
    --window-size="$WIDTH,$HEIGHT" \
    --user-agent="$UA" \
    --touch-events=enabled \
    --no-sandbox \
    --no-first-run \
    --no-default-browser-check \
    --disable-dev-shm-usage \
    --user-data-dir="$HOME/profile" \
    "$URL" >"$LOG/chromium.out" 2>&1 &
CPID=$!

sleep 20
echo "framebuffer after twenty seconds: $(fingerprint)"
if command -v xdotool > /dev/null 2>&1; then
    echo "xdotool sees: $(xdotool search --name . 2>&1 | tr '\n' ' ')"
    echo "display size: $(xdotool getdisplaygeometry 2>&1)"
else
    echo "no xdotool in this payload"
fi
if [ -p "$TOUCH" ]; then
    echo "touch fifo is there"
else
    mkfifo "$TOUCH" 2>/dev/null && echo "touch fifo made" || echo "no touch fifo"
fi

# One line per touch from the recovery: "down x y", "move x y", "up x y",
# "key Name" or "kbd on|off". The recovery owns the touch screen, so this is
# how a finger reaches the page.
#
# The pipe is held open for reading and writing by this shell: a reader that
# only ever opens it for reading sees the end of the file when the writer goes
# away, stops reading, and then nobody is there for the next line — which is
# what made every touch after the first one vanish.
if [ -p "$TOUCH" ] && command -v xdotool > /dev/null 2>&1; then
    (
        exec 3<>"$TOUCH"
        while read -r what a b <&3; do
            case "${what:-}" in
                down) xdotool mousemove "$a" "$b" mousedown 1 ;;
                move) xdotool mousemove "$a" "$b" ;;
                up)   xdotool mouseup 1 ;;
                key)  xdotool key "$a" ;;
                kbd)  keyboard "$a" ;;
            esac
        done
    ) &
fi

wait "$CPID"
RC=$?
echo "chromium exited $RC"
tail -n 30 "$LOG/chromium.out" 2>&1
exit "$RC"

#!/bin/sh
# The full mode's Chromium, started inside a Linux root by the recovery.
#
# The recovery binds /dev, /proc and /sys into this root and writes the
# phone's name servers to /etc/resolv.conf before running this, so the
# fallbacks below are for a bare chroot, not for the phone.
#
#   run.sh <url> serve   keep one page alive and listen on 9222, so the
#                        recovery can draw it, touch it and type into it
#   run.sh <url>         draw the page once and leave it at
#                        /tmp/skyward-chromium.png
set -u

# The recovery starts this inside a Linux root, where the recovery's own
# PATH names nothing that is there: everything below is found from these.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/root
# The recovery's own TMPDIR points at /data/local/tmp, which is not here, and
# Chromium asks the temp folder for the socket it keeps its profile under: an
# answer it cannot reach is the socket it cannot make.
export TMPDIR=/tmp
export TMP=/tmp

mkdir -p /tmp /dev/shm
[ -e /proc/self ] || mount -t proc proc /proc 2>/dev/null || busybox mount -t proc proc /proc 2>/dev/null || true
[ -e /sys/class ] || mount -t sysfs sysfs /sys 2>/dev/null || busybox mount -t sysfs sysfs /sys 2>/dev/null || true
[ -e /dev/null ] || { mknod -m 666 /dev/null c 1 3 2>/dev/null || busybox mknod -m 666 /dev/null c 1 3 2>/dev/null || true; }
[ -e /dev/urandom ] || { mknod -m 666 /dev/urandom c 1 9 2>/dev/null || busybox mknod -m 666 /dev/urandom c 1 9 2>/dev/null || true; }
[ -e /dev/random ] || { mknod -m 666 /dev/random c 1 8 2>/dev/null || busybox mknod -m 666 /dev/random c 1 8 2>/dev/null || true; }
[ -s /etc/resolv.conf ] || printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > /etc/resolv.conf 2>/dev/null || true

export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs

CHROMIUM=/usr/lib/chromium/chromium
[ -x "$CHROMIUM" ] || CHROMIUM=/usr/bin/chromium
[ -x "$CHROMIUM" ] || CHROMIUM=/usr/bin/chromium-browser

UA="Mozilla/5.0 (Linux; Android 14; Skyward) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

# --disable-features=AsyncDns keeps Chromium from going to 8.8.8.8:53 itself:
# the recovery has already written the phone's own name servers.
FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run \
--no-default-browser-check --disable-background-networking \
--ignore-certificate-errors --disable-quic --disable-dns-prefetch \
--disable-features=AsyncDns --hide-scrollbars --window-size=412,915 \
--force-device-scale-factor=2 --disable-crash-reporter --disable-breakpad"

URL="${1:-https://cn.bing.com}"

if [ "${2:-}" = "serve" ]; then
  # The profile keeps a socket beside itself, and the card this root sits on
  # is not a filesystem that has them: memory is.
  mount -t tmpfs tmpfs /tmp 2>/dev/null || busybox mount -t tmpfs tmpfs /tmp 2>/dev/null || true
  rm -rf /tmp/chromium-profile
  # shellcheck disable=SC2086
  exec "$CHROMIUM" --headless=new $FLAGS \
    --user-agent="$UA" \
    --enable-logging=stderr --v=0 \
    --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 \
    --remote-allow-origins='*' \
    --user-data-dir=/tmp/chromium-profile \
    "$URL"
fi

rm -f /tmp/skyward-chromium.png
# shellcheck disable=SC2086
"$CHROMIUM" --headless=new $FLAGS \
  --user-agent="$UA" \
  --screenshot=/tmp/skyward-chromium.png --timeout=30000 \
  "$URL" </dev/null >>/tmp/chromium.log 2>&1 || true
[ -s /tmp/skyward-chromium.png ]

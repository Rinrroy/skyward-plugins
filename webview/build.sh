#!/bin/bash
# Build the browser payload: a Debian arm64 rootfs holding Chromium, Weston,
# Mesa and udev, packed into one image the recovery can mount.
#
# Run on an arm64 machine (the CI runner is ubuntu-24.04-arm): debootstrap for
# a foreign architecture needs qemu, which is one more thing to go wrong.
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
    chromium weston libinput10 udev libgl1-mesa-dri libegl-mesa0 libgbm1 \
    fonts-noto-cjk fonts-noto-color-emoji ca-certificates xdg-utils

# Probe: this kernel has CONFIG_VT unset, so libseat can never make a session
# active and weston's DRM backend can never open the card. What is left is a
# toolkit whose KMS path opens /dev/dri itself. Qt's eglfs does; ask the suite
# whether it has Qt WebEngine and the platform plugin.
echo "=== what the suite offers"
sudo chroot "$ROOT" apt-cache policy python3-pyqt6.qtwebengine qt6-webengine-dev 2>&1 | head -20 || true
echo "=== installing qt webengine"
sudo chroot "$ROOT" apt-get install --yes --no-install-recommends \
    python3-pyqt6.qtwebengine qt6-webengine-dev 2>&1 | tail -20 \
    || echo "qt webengine is not installable here"
echo "=== qt platform plugins"
sudo chroot "$ROOT" sh -c 'ls /usr/lib/aarch64-linux-gnu/qt6/plugins/platforms/ 2>&1' || true
echo "=== eglfs present?"
sudo chroot "$ROOT" sh -c 'ls -l /usr/lib/aarch64-linux-gnu/qt6/plugins/platforms/libqeglfs.so 2>&1' || true
echo "=== a web page rendered with no display at all"
sudo tee "$ROOT/tmp/probe.py" > /dev/null <<'PY'
import sys
from PyQt6.QtCore import QUrl, QTimer
from PyQt6.QtWidgets import QApplication
from PyQt6.QtWebEngineWidgets import QWebEngineView

app = QApplication(sys.argv)
view = QWebEngineView()
view.resize(1280, 800)
view.load(QUrl("https://cn.bing.com"))

def done(ok):
    print("load ok:", ok, "title:", view.title(), flush=True)
    app.quit()

view.loadFinished.connect(done)
QTimer.singleShot(30000, app.quit)
app.exec()
print("qt webengine ran", flush=True)
PY
sudo chroot "$ROOT" env QT_QPA_PLATFORM=offscreen QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox" \
    python3 /tmp/probe.py 2>&1 | tail -15 || echo "the offscreen render did not finish"

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

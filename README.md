# Skyward plugins

The plugins Skyward downloads. Today there is one: a browser.

A plugin is a folder with a `plugin.json` in it. What makes this repository
different from a folder someone drops on their phone is the **payload**: an
image holding a whole program, too big to live in a recovery ramdisk and too
big to build on a phone.

## How Skyward finds them

Skyward asks for the newest release of this repository and reads the
`plugins.json` asset attached to it:

```
https://github.com/Rinrroy/skyward-plugins/releases/latest/download/plugins.json
```

That file names every plugin, what it is, and where its image is:

```json
{
  "version": 1,
  "plugins": [
    {
      "name": "webview",
      "title": "浏览器",
      "version": "1.0",
      "about": "在恢复里浏览网页",
      "needs": ["data", "network"],
      "payload": {
        "url": "https://github.com/Rinrroy/skyward-plugins/releases/download/webview-1.0/webview-1.0-arm64.squashfs",
        "sha256": "…64 hex…",
        "size": 734003200,
        "format": "squashfs",
        "program": "/opt/skyward/start.sh"
      }
    }
  ]
}
```

Skyward checks the digest of what it downloaded before the image is given a
name, so a mirror that serves something else costs a retry, not a broken
phone.

## The browser

`webview/` builds a Debian (arm64) rootfs holding:

- **Chromium**, kiosk mode, drawing through **Weston** on the DRM card the
  recovery hands over. Debian's Chromium has no `drm` ozone platform, so
  Weston is the compositor and Chromium talks Wayland to it.
- **Mesa**, for the GPU, with SwiftShader as the fallback when freedreno
  cannot drive this Adreno.
- **udev + libinput**, so the touchscreen is found the way it is on a
  desktop: the payload runs its own `udevd` against the `/sys` the recovery
  binds in.
- **Noto CJK**, so Chinese pages are not a wall of boxes.
- A managed policy that makes **Bing China** the search engine and the home
  page, and turns off the first-run experience.

The recovery does the rest: it mounts the image, binds `/dev`, `/proc`,
`/sys` and `/data`, writes `/etc/resolv.conf` from the DHCP answer, sets
SELinux permissive for the length of the run, releases the DRM card, and
`exec`s `/opt/skyward/start.sh` inside the chroot.

### Building it

`.github/workflows/webview.yml` builds the image on an arm64 runner, writes
`plugins.json` from the real digest and size, and attaches both to a release
tagged `webview-<version>`:

```
gh workflow run webview.yml -f version=1.0
```

The image is a squashfs of the rootfs, zstd-compressed, roughly 400 MB.

### What is known not to work yet

- **Audio.** The codec needs the vendor's audio HAL, which is not in a
  Debian rootfs. Video plays silently for now.
- **Hardware video decoding.** Qualcomm's Venus decoder is stateless V4L2 and
  needs an Android component in front of it; Chromium decodes in software.
- **GPU on some builds.** If freedreno cannot drive the Adreno, Chromium
  falls back to SwiftShader and the frame rate shows it.

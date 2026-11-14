# Skyward plugins

The plugins Skyward downloads. Today there is one: a browser.

A plugin is a folder with a `plugin.json` in it. What makes this repository
different from a folder someone drops on their phone is the **payload**: an
image holding a program, too big to live in a recovery ramdisk and too big to
build on a phone.

## How Skyward finds them

Skyward asks for the latest release of this repository and reads the
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
      "version": "3.0",
      "author": "Rinrroy",
      "about": "在恢复里浏览网页，默认用必应搜索。不运行脚本，也不播放视频。",
      "needs": ["data", "network"],
      "protocol": 1,
      "payload": {
        "url": "https://github.com/Rinrroy/skyward-plugins/releases/download/webview-3.0/webview-3.0-arm64.erofs",
        "sha256": "…64 hex…",
        "size": 12345678,
        "format": "erofs",
        "program": "/opt/skyward/bin/skyward-browser"
      }
    }
  ]
}
```

An entry is a plugin's own `plugin.json` with one key added, `name`: the folder
it is installed into (`/data/skyward/plugins/webview/`). `tools/index.py` writes
the file; it is generated, never edited, and never committed.

Skyward checks the digest of what it downloaded before the image is given a
name, so a mirror that serves something else costs a retry, not a broken phone.

## What a plugin is

A plugin with `"protocol": 1` is one program, cross-compiled for Android's arm64
ABI against the NDK the recovery itself is built with. The recovery mounts the
image read-only, `exec`s `payload.program` under its own `img/` mount point, and
otherwise stays out of the way:

- the program **draws** into a shared frame file it `mmap`s — a small header and
  then RGBA pixels — and the recovery puts those pixels on the panel;
- the recovery **writes touches and keys** into a FIFO, one command per line;
- `stop`, then a kill two seconds later, ends the run.

There is no chroot and no second libc: the program runs in the recovery's own
process space, which is why it is an `aarch64-linux-android` binary and not a
Debian one. How the program is started and what passes between the two sides is
[`webview/PROTOCOL.md`](webview/PROTOCOL.md).

Anything a plugin does beyond that is its own: windows, tabs, downloads, and the
full Chromium mode the browser offers are inside the program, not in the host.

## The browser

`webview/` builds the browser plugin: a Rust program from `webview/crate/`,
compiled against a pinned commit of
[Jamvii/skyward-for-aurora](https://github.com/Jamvii/skyward-for-aurora), with
the two fonts it draws with and a launcher, packed into an erofs image:

```
opt/skyward/bin/skyward-browser          # the program the manifest names
opt/skyward/share/fonts/MiSansVF.ttf     # the UI text
opt/skyward/share/fonts/KirkMono-Regular.ttf
opt/skyward/run.sh                       # optional entry point, for a shell first
```

The image is erofs because the recovery already mounts the phone's own system
partitions with erofs, so the kernel in the ramdisk is certain to read it.

This replaces the earlier design, which shipped a whole Debian arm64 rootfs with
Chromium under Weston on a chrooted DRM card. That approach needed Xvfb, a
framebuffer copy and a 400 MB image to show a window, most of it a userspace the
recovery does not need. This version is the basic browser only; full Chromium
mode stays the plugin's own business if it comes back — the plugin would start
it, chroot into a Chromium rootfs it finds under the plugin store, and the
recovery would never learn that it happened.

### Building it

`.github/workflows/webview.yml` runs `webview/build.sh` on a Linux runner: it
fetches the pinned upstream tree, drops `webview/crate/` into it as
`crates/skyward-browser`, cross-compiles with `cargo ndk`, strips the binary,
packs the image with `mkfs.erofs`, and writes the real digest and size back into
`webview/plugin.json`.

Publishing follows the version, not a button: a push to `main` builds, and when
`webview/plugin.json` names a version that has no Release yet, it publishes it —
the image and `plugin.json` to a release tagged `webview-<version>`, and
`plugins.json` to the `latest` release the URL above points at. Bumping the
version is the release. Re-running a version that is already out only rebuilds,
which is what reviewing a build wants; `gh workflow run webview.yml -f
publish=true` forces a publish of the current version.

The runner is x86_64, deliberately: the payload is cross-compiled, so nothing
needs an arm64 machine, and the NDK's Linux package is x86_64-only.

### What is known not to work yet

This version is the basic browser: text, pictures, links, basic CSS, forms,
cookies, downloads, tabs and the on-screen keyboard. It does not run scripts,
and it does not play video.

The full Chromium mode the interface still offers a page for is not in this
build. That page says so and comes back; a later version of the plugin can wire
it up without the recovery changing, since starting Chromium is the plugin's
own business. When it does, the limits below apply to it:

- **Audio.** The codec needs the vendor's audio HAL, which a plugin does not
  have. Video plays silently.
- **Hardware video decoding.** Qualcomm's Venus decoder is stateless V4L2 and
  needs an Android component in front of it; decoding happens in software.
- **GPU.** If freedreno cannot drive the Adreno from inside the Chromium
  rootfs, Chromium falls back to SwiftShader and the frame rate shows it.

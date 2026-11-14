# The browser plugin

What this folder publishes: one plugin, `webview` — a program that puts a
browser on the recovery's panel. It is a plugin, not a release of Skyward, so
installing it does not replace the recovery.

## What is in it

```
plugin.json      the manifest Skyward reads: title, version, needs, payload
payload.erofs    the image this repository builds (a release asset, not in git)
```

The manifest is the thing to read first; the image is what it points at.

```json
{
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
```

`url`, `sha256` and `size` belong to a build, not to a person: `build.sh` writes
them from the image it just packed. **The copy in git is therefore a template,
not an installable manifest** — its `sha256` is zeros and its `size` is `0`
because nothing has been built yet, and the plugin page will refuse it
(`payload.size: 0 is not a size an image can be`). That refusal is the point: a
manifest that was never backfilled must not be offered as a plugin nobody can
install. `tools/index.py` applies the same rule, so the index cannot publish a
template either.

## Installing it

The normal way is Skyward's own plugin page, which reads
`https://github.com/Rinrroy/skyward-plugins/releases/latest/download/plugins.json`,
downloads the image, checks its digest, and installs it as
`/data/skyward/plugins/webview/`.

By hand, on a phone where `/data` is available: put `plugin.json` and the image
in `/data/skyward/plugins/webview/`, with the image named `payload.erofs`, then
restart the recovery. Creating that folder is the whole installation; removing it
is the whole uninstallation.

## How it runs

The recovery mounts the image read-only at `img/`, `exec`s `payload.program`
(`/opt/skyward/bin/skyward-browser`, i.e. `img/opt/skyward/bin/…`), and talks to
it through two files it names in the environment:

| | |
|---|---|
| `SKYWARD_PLUGIN_FRAME` | 4096-byte header + RGBA8888 (straight alpha) pixels; the program draws, the recovery shows |
| `SKYWARD_PLUGIN_INPUT` | one command per line. v1 sends `down`, `move`, `up`, `key`, `stop`; the rest are reserved and must be ignored |
| `SKYWARD_PLUGIN_ROOT` | `img/`, the image's root |
| `SKYWARD_HOME` | writable home for caches and settings |
| `SKYWARD_DNS` | the name servers the host knows, comma-separated IPv4 (may be empty) |
| `SKYWARD_LOG` | where its stdout and stderr go |

The program is not chrooted: it runs as an ordinary `aarch64-linux-android`
binary in the recovery's process space and links against the bionic that is
already loaded. It draws the browser itself; the full Chromium mode it offers is
its own business, started and chrooted from inside the plugin.

There is no soft keyboard to inherit: the recovery's input is a panel and four
hardware keys. Typing is the plugin's own — it draws its own keyboard and turns
the taps it receives into characters, which is also why the `text` command is
reserved rather than used.

The protocol in full — every field, every command, the write order that keeps
the panel from tearing — is [`PROTOCOL.md`](PROTOCOL.md). That document is the
contract between this plugin and the host; neither side changes it alone.

## Building it

Needs a Linux machine (or CI), Rust, the Android NDK, `erofs-utils` and
`python3`:

```
ANDROID_NDK_HOME=/path/to/android-ndk webview/build.sh
```

It writes `webview-<version>-arm64.erofs` at the repository root and backfills
`webview/plugin.json`. What it builds against is pinned — the upstream commit is
in `build.sh`, so a rebuild months later is the same program.

The image holds a binary, two fonts and a launcher. There is no Debian, no
Weston, no Xvfb, and no second libc in it.

CI is easier than doing that by hand: `.github/workflows/webview.yml`, dispatched
with a version and `publish`, builds the image, attaches it to a
`webview-<version>` release, and republishes `plugins.json` on the `latest`
release. The order matters and the workflow keeps it: `build.sh` first (so the
manifest carries a real `sha256` and `size`), `tools/index.py` second (so the
index never describes an image that does not exist).

## What is known not to work yet

- **Audio.** No vendor HAL in a plugin; video is silent.
- **Hardware video decoding.** Software decoding only, so large frames are slow.
- **GPU in full mode.** Chromium may fall back to SwiftShader inside its rootfs.

## Files here

```
plugin.json    the manifest (url/sha256/size written by build.sh)
build.sh       cross-compile, pack the payload, backfill the manifest
run.sh         optional launcher shipped in the image; sets HOME, execs the program
PROTOCOL.md    the plugin protocol, v1
crate/         the program's Rust source
```

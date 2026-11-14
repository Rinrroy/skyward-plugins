#!/usr/bin/env bash
# Build the browser plugin's payload: one program cross-compiled for Android's
# arm64 ABI, the fonts it draws with, and a launcher, packed into an erofs
# image that Skyward mounts read-only and execs without a chroot.
#
# Nothing of upstream is taken on trust. The crate this repository owns is put
# into a checkout of Jamvii/skyward-for-aurora at one commit, because it builds
# against that workspace's profile, resolves into its lockfile and ships its
# fonts; a payload that drifts with someone else's `main` is not a payload that
# can be built twice the same way.
#
# The image is erofs, not squashfs, and that is not a preference: the recovery
# mounts the phone's own system partitions with erofs, so the kernel in the
# ramdisk is certain to read it. lz4 is the compression it can decode fastest.
#
# Usage:  webview/build.sh
#   VERSION=2.1        override the version read from webview/plugin.json
#   UPSTREAM_REV=…     build against another commit (the pin is below)
#   API=30             the Android API level the program links against
#   REPO_SLUG=…        owner/name the payload is published under
# Writes: webview-<version>-arm64.erofs and the backfilled webview/plugin.json.
set -euo pipefail

step() { printf '\n== %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WEBVIEW="$REPO/webview"
MANIFEST="$WEBVIEW/plugin.json"
CRATE_SRC="$WEBVIEW/crate"

# What is pinned, and what may be talked out of being pinned.
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/Jamvii/skyward-for-aurora}"
UPSTREAM_REV="${UPSTREAM_REV:-f80c3dd872d5ee05218e716525607492f01eaf40}"
REPO_SLUG="${REPO_SLUG:-Rinrroy/skyward-plugins}"
VENDOR="${VENDOR:-$REPO/.vendor/skyward}"
STAGE="${STAGE:-$REPO/.build/payload}"
API="${API:-30}"
# cargo-ndk names ABIs the way the NDK does; aarch64-linux-android is arm64-v8a.
ABI="arm64-v8a"

command -v python3 >/dev/null || die "需要 python3（回填清单、改 workspace 列表都用它）"
[ -f "$MANIFEST" ] || die "$MANIFEST 不存在"

if [ -z "${VERSION:-}" ]; then
    VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$MANIFEST")"
fi
[ -n "$VERSION" ] || die "plugin.json 里没有 version"
IMAGE="$REPO/webview-$VERSION-arm64.erofs"

# ---------------------------------------------------------------- 0. the crate
# The program itself is written in this repository, in webview/crate. It is a
# plain crate: it joins the upstream workspace, so it cannot bring a [workspace]
# of its own, and its package name is what the build asks cargo for.
step "0/6 检查 webview/crate/"
[ -f "$CRATE_SRC/Cargo.toml" ] || die "缺少 $CRATE_SRC/Cargo.toml：插件程序的源码应该在这里"
if grep -qE '^[[:space:]]*\[workspace\]' "$CRATE_SRC/Cargo.toml"; then
    die "webview/crate/Cargo.toml 有 [workspace] 表：它要作为 .vendor/skyward 的 member 编译"
fi
grep -qE '^[[:space:]]*name[[:space:]]*=[[:space:]]*"skyward-browser"' "$CRATE_SRC/Cargo.toml" ||
    die "webview/crate/Cargo.toml 的 [package] name 不是 skyward-browser"

# ---------------------------------------------------------------------- the NDK
# The program runs in the recovery's own process space under bionic, so it is a
# normal dynamically linked Android binary: link it against API 30's libc and
# leave the dynamic section alone. Nothing about it is made static, and its
# rpath is not touched — the libc it needs is the one already loaded.
step "1/6 找 NDK"
ndk_bin() {
    local ndk="$1" dir
    for dir in "$ndk"/toolchains/llvm/prebuilt/*/bin; do
        if [ -x "$dir/aarch64-linux-android${API}-clang" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

NDK=""
for candidate in \
    "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}" \
    "${ANDROID_HOME:-}/ndk/"* "${ANDROID_SDK_ROOT:-}/ndk/"* \
    "$HOME"/android-ndk-r*; do
    [ -n "$candidate" ] && [ -d "$candidate" ] || continue
    if NDK_BIN="$(ndk_bin "$candidate")"; then
        NDK="$candidate"
        break
    fi
done
[ -n "$NDK" ] || die "找不到能编 API $API 的 Android NDK。
  设 ANDROID_NDK_HOME 指向 NDK 根目录，里面应当有
  toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android${API}-clang。
  上游 CI 用 nttld/setup-ndk 装 r29；本地从
  https://developer.android.com/ndk/downloads 下 Linux 包（只有 x86_64 的）。"
export ANDROID_NDK_HOME="$NDK"
export PATH="$NDK_BIN:$PATH"
printf 'NDK   %s\n' "$NDK"
printf 'clang %s\n' "$NDK_BIN/aarch64-linux-android${API}-clang"

command -v cargo >/dev/null || die "没有 cargo"
if ! command -v cargo-ndk >/dev/null; then
    step "装 cargo-ndk"
    cargo install cargo-ndk --version 4.1.2 --locked
fi

# ----------------------------------------------------------- 2. the upstream tree
# One commit, shallow. Re-cloning on every run would be honest but slow, so the
# checkout is kept and only thrown away when it is not the pinned commit.
step "2/6 上游源码 $UPSTREAM_REV"
if [ -d "$VENDOR/.git" ] && [ "$(git -C "$VENDOR" rev-parse HEAD 2>/dev/null || true)" = "$UPSTREAM_REV" ]; then
    printf '%s 已经是 %s\n' "$VENDOR" "$UPSTREAM_REV"
else
    rm -rf "$VENDOR"
    mkdir -p "$(dirname -- "$VENDOR")"
    git init -q "$VENDOR"
    git -C "$VENDOR" remote add origin "$UPSTREAM_URL"
    # Ask for the one commit. A server that will not hand out a commit by id
    # gets asked for everything instead; either way the checkout is verified.
    if ! git -C "$VENDOR" fetch -q --depth 1 origin "$UPSTREAM_REV" 2>/dev/null; then
        printf '按 sha 取不到，改成取分支\n'
        git -C "$VENDOR" fetch -q origin
    fi
    git -C "$VENDOR" checkout -q --detach "$UPSTREAM_REV" ||
        die "上游 checkout 不到 $UPSTREAM_REV"
fi
[ "$(git -C "$VENDOR" rev-parse HEAD)" = "$UPSTREAM_REV" ] ||
    die "$VENDOR 的 HEAD 不是 $UPSTREAM_REV，上游被别的东西动过"

# Put the crate where the workspace expects it, and say so in members. Both
# halves are idempotent: a second run finds the copy already there and the
# member already listed.
step "2/6 上游源码：放入 webview/crate"
CRATE_DEST="$VENDOR/crates/skyward-browser"
rm -rf "$CRATE_DEST"
mkdir -p "$(dirname -- "$CRATE_DEST")"
cp -a "$CRATE_SRC" "$CRATE_DEST"
rm -rf "$CRATE_DEST/target" # a local build must not travel into the payload
python3 - "$VENDOR/Cargo.toml" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
member = "crates/skyward-browser"
if f'"{member}"' in text:
    print(f"{path}: {member} 已经在 members 里")
    raise SystemExit(0)
opening = re.search(r"^members\s*=\s*\[", text, re.M)
if opening is None:
    sys.exit(f"{path}: 没有 members = [ … ]，上游布局变了")
path.write_text(
    text[: opening.end()] + f'\n    "{member}",' + text[opening.end() :],
    encoding="utf-8",
)
print(f"{path}: 加了 {member}")
PY

# ------------------------------------------------------------------- 3. compile
step "3/6 交叉编译 skyward-browser（$ABI, API $API）"
# A caller that set CARGO_TARGET_DIR keeps its cache there, and the binary is
# then under that directory rather than under the checkout.
TARGET_DIR="${CARGO_TARGET_DIR:-$VENDOR/target}"
case "$TARGET_DIR" in
    /*) ;;
    *) TARGET_DIR="$VENDOR/$TARGET_DIR" ;;
esac
( cd "$VENDOR" && cargo ndk -t "$ABI" --platform "$API" build --release -p skyward-browser )
BUILT="$TARGET_DIR/aarch64-linux-android/release/skyward-browser"
[ -f "$BUILT" ] || die "编完了却没有 $BUILT"

# ------------------------------------------------------------------- 4. payload
# The layout the manifest names: one binary, the fonts it reads, a launcher.
step "4/6 组 payload"
rm -rf "$STAGE"
mkdir -p "$STAGE/opt/skyward/bin" "$STAGE/opt/skyward/share/fonts"
install -m 0755 "$BUILT" "$STAGE/opt/skyward/bin/skyward-browser"
"$NDK_BIN/llvm-strip" --strip-unneeded "$STAGE/opt/skyward/bin/skyward-browser"

# A build machine that quietly produced a host binary is the one failure this
# script can catch without a phone: read the ELF header back.
python3 - "$STAGE/opt/skyward/bin/skyward-browser" <<'PY'
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as program:
    head = program.read(20)
if head[:4] != b"\x7fELF":
    sys.exit(f"{path}: 不是 ELF")
machine = struct.unpack_from("<H", head, 18)[0]
if machine != 0xB7:
    sys.exit(f"{path}: e_machine=0x{machine:04x}，不是 AArch64（0x00b7）")
print(f"{path}: ELF AArch64")
PY

FONTS=""
for candidate in "$VENDOR/resources/fonts" "$REPO/resources/fonts"; do
    if [ -d "$candidate" ]; then
        FONTS="$candidate"
        break
    fi
done
[ -n "$FONTS" ] || die "找不到字体目录"
for font in MiSansVF.ttf KirkMono-Regular.ttf; do
    [ -f "$FONTS/$font" ] || die "$FONTS 里没有 $font"
    install -m 0644 "$FONTS/$font" "$STAGE/opt/skyward/share/fonts/$font"
done
install -m 0755 "$WEBVIEW/run.sh" "$STAGE/opt/skyward/run.sh"

printf 'payload %s\n' "$STAGE"
du -sh "$STAGE/opt/skyward/bin/skyward-browser" "$STAGE/opt/skyward/share/fonts" 2>/dev/null || true

# ----------------------------------------------------------------- 5. the image
step "5/6 打 erofs $IMAGE"
command -v mkfs.erofs >/dev/null || die "没有 mkfs.erofs（apt install erofs-utils）"
rm -f "$IMAGE"
# -T 1: every file stamped with the same second, so the same tree packs to the
# same image and a rebuild that changed nothing shows up as nothing.
if mkfs.erofs -zlz4 -T 1 "$IMAGE" "$STAGE"; then
    :
elif mkfs.erofs -zlz4hc,9 -T 1 "$IMAGE" "$STAGE"; then
    printf 'build.sh: 这个 erofs-utils 不认 -zlz4，用了 lz4hc\n' >&2
elif mkfs.erofs -T 1 "$IMAGE" "$STAGE"; then
    printf 'build.sh: 这个 erofs-utils 没有 lz4，打成了不压缩的镜像\n' >&2
else
    die "mkfs.erofs 失败"
fi

# -------------------------------------------------------- 6. the manifest's digits
# plugin.json is committed with the real URL and a placeholder digest; the
# digest and the size are whatever this run produced, because they cannot be
# known before it runs.
step "6/6 回填 plugin.json"
SHA="$(sha256sum "$IMAGE" | cut -d' ' -f1)"
SIZE="$(stat -c%s "$IMAGE" 2>/dev/null || wc -c <"$IMAGE")"
URL="https://github.com/$REPO_SLUG/releases/download/webview-$VERSION/$(basename -- "$IMAGE")"
python3 - "$MANIFEST" "$URL" "$SHA" "$SIZE" "$VERSION" <<'PY'
import json
import sys

path, url, sha, size, version = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
with open(path, encoding="utf-8") as manifest_file:
    manifest = json.load(manifest_file)
# The version is written back too: a build may be asked for one that the
# manifest has not been bumped to yet, and an image named 2.1 that says 2.0 is
# a plugin that updates itself forever.
manifest["version"] = version
payload = manifest.setdefault("payload", {})
payload["url"] = url
payload["sha256"] = sha
payload["size"] = size
with open(path, "w", encoding="utf-8", newline="\n") as manifest_file:
    json.dump(manifest, manifest_file, ensure_ascii=False, indent=2)
    manifest_file.write("\n")
print(f"{path}: payload.url/sha256/size 已回填")
PY

printf '\nimage    %s\nsha256   %s\nsize     %s\n' "$IMAGE" "$SHA" "$SIZE"
printf '清单     %s\n' "$MANIFEST"

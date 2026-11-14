#!/usr/bin/env python3
"""Write the index of the plugins in this repository: `plugins.json`.

Skyward fetches one file and reads the plugins it offers from it:

    https://github.com/Rinrroy/skyward-plugins/releases/latest/download/plugins.json

An entry is a plugin's own `plugin.json` with one key added, `name`, which is the
folder it is installed into. The host reads each entry with the same parser it
reads an installed manifest with, so everything an entry says must survive being
written back out as one — which is why this script does not invent fields, only
checks them.

Everything here is checked, not assumed: a manifest that was never backfilled by
a build (`sha256` of zeros, `size` of zero) fails the index rather than being
published as a plugin nobody can install.

Usage:
    tools/index.py                 # writes ./plugins.json
    tools/index.py --output -      # prints it instead
    tools/index.py --root /elsewhere
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# What the host calls the shape of this file. Bump it only with the host.
INDEX_VERSION = 1

# A payload digest: lowercase hex, 32 bytes of it.
SHA256 = re.compile(r"\A[0-9a-f]{64}\Z")

# The readers the protocol names. Anything else the host rejects.
FORMATS = ("erofs", "squashfs", "ext4", "img")

# The manifest keys an entry in this index keeps. `payload` is checked below;
# `protocol` is carried because it is what tells a reader how to run the plugin.
KEYS = ("title", "version", "author", "about", "needs", "protocol", "payload")

# The order this index writes an entry's keys in. `name` first, then the
# manifest's own order, so a diff of this file reads as the change it is.
ORDER = ("name",) + KEYS


class Bad(Exception):
    """A manifest this index will not publish, and why."""


def manifest_of(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise Bad(f"{path}: 读不出来：{error}") from error
    try:
        manifest = json.loads(text)
    except json.JSONDecodeError as error:
        raise Bad(f"{path}: 不是 JSON：{error}") from error
    if not isinstance(manifest, dict):
        raise Bad(f"{path}: 清单是一个 JSON 对象")
    return manifest


def payload_of(manifest: dict, path: Path) -> dict:
    payload = manifest.get("payload")
    if not isinstance(payload, dict):
        raise Bad(f"{path}: 没有 payload —— 索引里的插件必须带一个镜像")

    url = payload.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise Bad(f"{path}: payload.url 必须是 https:// 开头")

    sha256 = payload.get("sha256")
    if not isinstance(sha256, str) or not SHA256.match(sha256):
        raise Bad(f"{path}: payload.sha256 不是 64 位小写十六进制（清单回填过了吗？）")

    size = payload.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise Bad(f"{path}: payload.size 不是正数（清单回填过了吗？）")

    fmt = payload.get("format")
    if not isinstance(fmt, str) or fmt.strip().lower() not in FORMATS:
        raise Bad(f"{path}: payload.format 应当是 {', '.join(FORMATS)} 之一")

    program = payload.get("program")
    if not isinstance(program, str) or not program.startswith("/"):
        raise Bad(f"{path}: payload.program 是镜像里的绝对路径")
    if ".." in program.split("/"):
        raise Bad(f"{path}: payload.program 不该有 ..")
    return payload


def protocol_of(manifest: dict, path: Path) -> None:
    protocol = manifest.get("protocol")
    if protocol is None:
        return
    if not isinstance(protocol, int) or isinstance(protocol, bool) or protocol < 1:
        raise Bad(f"{path}: protocol 是正整数（帧协议是 1）")


def entries(root: Path) -> list[dict]:
    """Every plugin in the repository, in the order they are installed."""
    found = []
    for path in sorted(root.glob("*/plugin.json")):
        name = path.parent.name
        if name.startswith("."):
            continue
        manifest = manifest_of(path)
        payload_of(manifest, path)
        protocol_of(manifest, path)
        entry = {"name": name}
        for key in KEYS:
            if key in manifest:
                entry[key] = manifest[key]
        found.append(entry)

    # A folder name is one path part: a slash would install into a folder that
    # is not this plugin's, and `..` would install outside the store.
    seen = set()
    for entry in found:
        name = entry["name"]
        if "/" in name or "\\" in name or name in (".", ".."):
            raise Bad(f"{name!r}: 这不是一个文件夹名")
        if name in seen:
            raise Bad(f"{name}: 出现在两个地方")
        seen.add(name)
    return found


def render(plugins: list[dict]) -> str:
    """The file's text: stable, sorted, and free of anything that is not a
    plugin — a timestamp here would make every build a diff."""
    ordered = [
        {key: entry[key] for key in ORDER if key in entry} for entry in plugins
    ]
    index = {"version": INDEX_VERSION, "plugins": ordered}
    return json.dumps(index, ensure_ascii=False, indent=2) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Write the index of the plugins in this repository."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="where the plugins are (default: this repository)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="where to write it, or - for stdout (default: <root>/plugins.json)",
    )
    arguments = parser.parse_args(argv)

    root = arguments.root.resolve()
    try:
        plugins = entries(root)
    except Bad as error:
        print(f"index.py: {error}", file=sys.stderr)
        return 1

    if not plugins:
        print(f"index.py: {root} 里没有插件", file=sys.stderr)
        return 1

    text = render(plugins)
    output = arguments.output
    if output == "-":
        sys.stdout.write(text)
    else:
        path = Path(output) if output else root / "plugins.json"
        path.write_text(text, encoding="utf-8")
        for entry in plugins:
            print(
                f"index.py: {entry['name']} {entry.get('version', '?')} "
                f"({entry['payload']['format']}, {entry['payload']['size']} bytes)",
                file=sys.stderr,
            )
        print(f"index.py: 写了 {path}（{len(plugins)} 个插件）", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

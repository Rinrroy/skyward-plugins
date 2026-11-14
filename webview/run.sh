#!/system/bin/sh
# The launcher the payload ships beside the program.
#
# The manifest points `program` straight at bin/skyward-browser: the host execs
# it with the recovery's own libc, which is all an Android binary needs, so the
# common path is one exec and no shell. This script is the other path — a start
# by hand inside the image, a debugger wrapper, or a future host that would
# rather exec something it can also read.
#
# It is a script for bionic's shell (toybox /system/bin/sh), not bash: the
# recovery's ramdisk has no other one.
set -u

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) # …/img/opt/skyward
bin="$here/bin/skyward-browser"
[ -x "$bin" ] || {
    echo "run.sh: no program at $bin" >&2
    exit 1
}

# The host names the plugin's writable home; a run by hand has only its cwd.
: "${SKYWARD_HOME:=${PWD}/home}"
mkdir -p "$SKYWARD_HOME" 2>/dev/null || true
HOME="$SKYWARD_HOME"
export HOME

exec "$bin" "$@"

#!/bin/sh
# Runs a list of collector commands and stores each one's output in a directory.
#
# Usage: collect.sh <list file> <output dir>
#
# The list has one collector per line: "<output file name> | <shell command>". Blank lines
# and lines starting with # are ignored. Adding something to collect is a one-line change
# in the list. A collector that fails never stops the others: its output (whatever it
# printed) is kept and its name and exit status go to collector-errors.txt.
# POSIX sh, so it also runs on the device's BusyBox. $SD is the SD card
# ($SDCARD_PATH, default /mnt/SDCARD) for commands that need it.

list="$1"
out="$2"
[ -f "$list" ] || {
    echo "collect.sh: no such list: $list" >&2
    exit 2
}
mkdir -p "$out" || exit 2
SD="${SDCARD_PATH:-/mnt/SDCARD}"
export SD

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "" | "#"*) continue ;; esac
    name="${line%%|*}"
    cmd="${line#*|}"
    name="$(printf '%s' "$name" | tr -d ' \t')"
    [ -n "$name" ] || continue
    sh -c "$cmd" >"$out/$name" 2>&1 </dev/null
    rc=$?
    [ "$rc" -eq 0 ] || echo "$name: exit status $rc" >>"$out/collector-errors.txt"
done <"$list"
exit 0

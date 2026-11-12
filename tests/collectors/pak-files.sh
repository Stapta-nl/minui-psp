#!/bin/sh
# Lists what is installed in a pak, for tests/pakcheck.sh (which compares it with the checkout or
# the release under test). Runs on the device, POSIX sh + BusyBox, changes nothing and never runs
# the emulator.
#
# Usage: pak-files.sh <pak dir> <platform>
# Output: "# key: value" header lines (checksum algorithm, pak.json version, the PPSSPP build text
# found in the binary), then one "<checksum>  <path relative to the pak>" line per file, sorted.
# PPSSPP/.config (the user's settings, saves and states) is left out: it is not part of the pak.

pak="${1:-}"
platform="${2:-}"
[ -d "$pak" ] || {
    echo "# error: no pak at $pak"
    exit 1
}
cd "$pak" || exit 1

if command -v md5sum >/dev/null 2>&1; then
    algo=md5sum
elif command -v sha1sum >/dev/null 2>&1; then
    algo=sha1sum
elif command -v cksum >/dev/null 2>&1; then
    algo="cksum"
else
    algo=size
fi
echo "# algo: $algo"
echo "# pak.json version: $(sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' pak.json 2>/dev/null | head -n 1)"
bin="PPSSPP/PPSSPPSDL_$platform"
if [ -f "$bin" ]; then
    # Text only: the binary is read, never executed (--version could start the emulator).
    build="$(grep -a -o -E -m 1 'v1\.[0-9]+(\.[0-9]+)*(-[0-9]+-g[0-9a-f]+)?' "$bin" 2>/dev/null | head -n 1)"
    echo "# ppsspp build: ${build:-no version text found in $bin}"
else
    echo "# ppsspp build: $bin is not installed"
fi

sum_of() {
    case "$algo" in
    md5sum | sha1sum) "$algo" "$1" | cut -d ' ' -f 1 ;;
    cksum) cksum "$1" | awk '{ print $1 "-" $2 }' ;;
    *) wc -c <"$1" | tr -d ' ' ;;
    esac
}

find . -type f ! -path './PPSSPP/.config/*' | sed 's|^\./||' | sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(sum_of "$f")" "$f"
done

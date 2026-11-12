#!/bin/sh
# Lists what is installed in a pak, for tests/pakcheck.sh (which compares it with the checkout or
# the release under test). Runs on the device, POSIX sh + BusyBox, changes nothing and never runs
# the emulator.
#
# Usage: pak-files.sh <pak dir> <platform>
#        pak-files.sh --build <binary>     prints only that binary's PPSSPP version text
# Output: "# key: value" header lines (checksum algorithm, pak.json version, the PPSSPP build text
# found in the binary), then one "<checksum>  <path relative to the pak>" line per file, sorted.
# PPSSPP/.config (the user's settings, saves and states) is left out: it is not part of the pak.

# ppsspp_build <binary>: PPSSPP's own version text, or "unknown". PPSSPP builds PPSSPP_GIT_VERSION from
# `git describe --always` (git-version.cmake): "v1.20.3", "v1.20.3-5-gabcdef0", and a build of a fork or
# of a modified tree can carry more ("v1.20.3-5-gabcdef0-dirty", "v1.20.3-saveonexit"). It is a string of
# its own in the binary, NUL-delimited, so only WHOLE strings "vN.N.N" with an optional "-suffix" count;
# text in another library (a "v1.1", zlib's "v1.2.11" inside a longer string) does not. A string WITH a
# suffix wins over a bare tag; among equals the highest version, the others listed ("also found"), so the
# ambiguity is visible. If no whole string matches, a describe-style vN.N.N-N-gHASH found anywhere in the
# file is reported with a "~" in front (approximate); a bare tag inside other text is never trusted (it is
# often another library's): "unknown". The binary is
# read as text and never executed.
ppsspp_build() {
    found="$(tr '\000' '\n' <"$1" 2>/dev/null | grep -a -E '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]{1,40})?$' | awk '!seen[$0]++')"
    approx=""
    if [ -z "$found" ]; then
        found="$(grep -a -o -E 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g[0-9a-f]+(-dirty)?' "$1" 2>/dev/null | awk '!seen[$0]++' | head -n 20)"
        [ -n "$found" ] || { echo unknown; return; }
        approx="~"
    fi
    best="$(printf '%s\n' "$found" | grep -E -- '^v[0-9.]+-' | head -n 1)"
    if [ -z "$best" ]; then
        best="$(printf '%s\n' "$found" | awk -F '[v.]' '{ printf "%05d%05d%05d %s\n", $2, $3, $4, $0 }' | sort | tail -n 1 | cut -d ' ' -f 2)"
    fi
    n="$(printf '%s\n' "$found" | grep -vxF -- "$best" | head -n 6 | tr '\n' ' ' | sed 's/ $//')"
    echo "$approx$best${n:+ (also found: $n)}"
}
if [ "${1:-}" = "--build" ]; then
    [ -f "${2:-}" ] || { echo unknown; exit 1; }
    ppsspp_build "$2"
    exit 0
fi

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
    echo "# ppsspp build: $(ppsspp_build "$bin")"
else
    echo "# ppsspp build: $bin is not installed"
fi
# every PPSSPP binary in the pak (a tg5050 one on a tg5040 device, ...), for the comparison notes
for b in PPSSPP/PPSSPPSDL_*; do
    [ -f "$b" ] || continue
    echo "# ppsspp build of $b: $(ppsspp_build "$b")"
done

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

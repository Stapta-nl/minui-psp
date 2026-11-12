#!/usr/bin/env bash
# Compares the pak installed on a device (the output of tests/collectors/pak-files.sh) with the
# pak under test: the checkout, or the unpacked release in SRC_PAK. Needs jq; git for a checkout.
#
# Usage: pakcheck.sh <device list> [<reference dir>]      (reference: $SRC_PAK, else this checkout)
# Prints the report: a first line "Pak under test: matches ..." (status 0), or "WARNING: ..." with
# one line per differing, missing or extra file (status 1). Status 2: the list is unusable.
# A mismatch is only a warning for the caller (PAK_MISMATCH=fail makes it fatal in run-device.sh).
#
# What counts: every file the release ships, except the user's settings (pak.json "update_ignore",
# and everything under PPSSPP/.config, which is the user's data). A file the release gets from a
# download (.gitarchiveinclude: the PPSSPP binaries, bin/jpg2bmp, ...) is compared when it is
# present in the reference and otherwise listed as "not compared". Nothing is downloaded.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
list="${1:-}"
ref="${2:-${SRC_PAK:-$ROOT}}"
[ -s "$list" ] || { echo "pakcheck.sh: no device list: $list" >&2; exit 2; }
[ -d "$ref" ] || { echo "pakcheck.sh: no such directory: $ref" >&2; exit 2; }
ref="$(cd "$ref" && pwd)"
if [ "$ref" = "$ROOT" ]; then label="this checkout"; else label="the release in $ref"; fi

algo="$(sed -n 's/^# algo: //p' "$list" | head -n 1)"
case "$algo" in md5sum | sha1sum | cksum | size) ;; *) echo "pakcheck.sh: unknown checksum algorithm in $list" >&2; exit 2 ;; esac
dev_version="$(sed -n 's/^# pak.json version: //p' "$list" | head -n 1)"
dev_build="$(sed -n 's/^# ppsspp build: //p' "$list" | head -n 1)"

sum_of() {
    case "$algo" in
    md5sum | sha1sum) "$algo" "$1" | cut -d ' ' -f 1 ;;
    cksum) cksum "$1" | awk '{ print $1 "-" $2 }' ;;
    size) wc -c <"$1" | tr -d ' ' ;;
    esac
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/pakcheck.XXXXXX")" || exit 2
trap 'rm -rf "$tmp"' EXIT

# Paths that are not compared: the user's settings.
{
    jq -r '.update_ignore[]? // empty' "$ref/pak.json" 2>/dev/null
} >"$tmp/ignore"
ignored() {
    case "$1" in PPSSPP/.config/*) return 0 ;; esac
    grep -qxF -- "$1" "$tmp/ignore"
}

# The reference: what the release contains.
: >"$tmp/downloaded"
: >"$tmp/built"
if [ -e "$ref/.git" ]; then
    # a checkout: git archive's content = tracked files minus export-ignore (.gitattributes) ...
    git -C "$ref" ls-files | grep -v -E '^(\.github/|\.git[a-z]*$|Makefile$|src/|tests/|dist/)' >"$tmp/ref"
    # ... plus the files .gitarchiveinclude adds (build outputs): compared when present
    if [ -f "$ref/.gitarchiveinclude" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ -f "$ref/$f" ]; then echo "$f" >>"$tmp/ref"; echo "$f" >>"$tmp/built"; else echo "$f" >>"$tmp/downloaded"; fi
        done <"$ref/.gitarchiveinclude"
    fi
else
    (cd "$ref" && find . -type f | sed 's|^\./||') >"$tmp/ref"
fi
sort -u "$tmp/ref" -o "$tmp/ref"

grep -v '^#' "$list" | sed 's/^\([^ ]*\)  /\1\t/' >"$tmp/dev"
cut -f 2- "$tmp/dev" | sort -u >"$tmp/devfiles"

differs=() builtdiff=() missing=() extra=() notcmp=() compared=0
while IFS= read -r f; do
    ignored "$f" && continue
    [ -f "$ref/$f" ] || continue # tracked but deleted in the working tree
    d="$(awk -F '\t' -v f="$f" '$2 == f { print $1; exit }' "$tmp/dev")"
    if [ -z "$d" ]; then
        missing+=("$f")
    else
        compared=$((compared + 1))
        if [ "$(sum_of "$ref/$f")" != "$d" ]; then
            # a build output (binary) of this machine or of the release download: another build
            # of the same source differs, so this is a note, not a warning
            if grep -qxF -- "$f" "$tmp/built"; then builtdiff+=("$f"); else differs+=("$f"); fi
        fi
    fi
done <"$tmp/ref"
while IFS= read -r f; do
    ignored "$f" && continue
    grep -qxF -- "$f" "$tmp/ref" && continue
    if grep -qxF -- "$f" "$tmp/downloaded"; then
        notcmp+=("$f")
    else
        extra+=("$f")
    fi
done <"$tmp/devfiles"
# a download-only file that the device lacks is missing too, but only worth a note
while IFS= read -r f; do
    grep -qxF -- "$f" "$tmp/devfiles" || missing+=("$f (not compared: comes from a release download)")
done <"$tmp/downloaded"

ref_version="$(jq -r '.version // empty' "$ref/pak.json" 2>/dev/null)"
if [ "${#differs[@]}" = 0 ] && [ "${#missing[@]}" = 0 ] && [ "${#extra[@]}" = 0 ]; then
    echo "Pak under test: matches $label (all $((compared - ${#builtdiff[@]})) shipped files compared are identical${builtdiff[0]:+; ${#builtdiff[@]} build outputs differ, see below}${notcmp[0]:+; ${#notcmp[@]} not compared: they come from a release download}; user settings ignored)"
    echo "  pak.json version: $dev_version; PPSSPP build text in the binary: ${dev_build:-unknown}"
    for f in ${builtdiff[@]+"${builtdiff[@]}"}; do echo "  note: differs from $label; build output, may be a different build: $f"; done
    for f in ${notcmp[@]+"${notcmp[@]}"}; do echo "  not compared (binary comes from a release download): $f"; done
    exit 0
fi
echo "WARNING: the pak installed on the device is NOT the one under test ($label). The results may be about an older pak."
for f in ${differs[@]+"${differs[@]}"}; do echo "  differs from $label: $f"; done
for f in ${missing[@]+"${missing[@]}"}; do echo "  missing on the device: $f"; done
for f in ${extra[@]+"${extra[@]}"}; do echo "  extra on the device (not in the release): $f"; done
for f in ${builtdiff[@]+"${builtdiff[@]}"}; do echo "  note: differs from $label; build output, may be a different build: $f"; done
for f in ${notcmp[@]+"${notcmp[@]}"}; do echo "  not compared (binary comes from a release download): $f"; done
echo "  pak.json version on the device: ${dev_version:-unknown} (under test: ${ref_version:-unknown}); PPSSPP build text on the device: ${dev_build:-unknown}"
echo "  Update the pak on the device (README, Updating: keep your ppsspp.ini and controls.ini) and run again."
exit 1

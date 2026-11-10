#!/bin/sh
# Read-only diagnosis of the Game Switcher preview for PSP games. Changes nothing.
#
# Checks whether PPSSPP's save-state thumbnails are complete JPEGs (a complete JPEG ends
# with the bytes ff d9), and what the pak converted into NextUI's preview.
#
# Usage (on the device, over ssh):
#   sh /mnt/SDCARD/Emus/tg5040/PSP.pak/tests/device/diagnose-preview.sh
# or without copying it first:
#   ssh root@<device> sh -s < tests/device/diagnose-preview.sh

SD="${SDCARD_PATH:-/mnt/SDCARD}"
SHARED="${SHARED_USERDATA_PATH:-$SD/.userdata/shared}"
STATES="$SHARED/PSP-ppsspp"
MINUI="$SHARED/.minui"

hexbytes() { # hexbytes <file> <offset-from-end or "head"> -> two bytes as "xx xx"
    if [ "$2" = head ]; then
        head -c 2 "$1"
    else
        tail -c 2 "$1"
    fi | od -An -tx1 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}

echo "== device"
uname -a
echo "date: $(date)"
mount | grep -i sdcard

echo
echo "== save states and thumbnails in $STATES (newest first)"
ls -lte "$STATES" 2>/dev/null || ls -lt "$STATES"

echo
echo "== thumbnail completeness (complete JPEG: starts 'ff d8', ends 'ff d9')"
for jpg in "$STATES"/*.jpg; do
    [ -f "$jpg" ] || continue
    size=$(wc -c <"$jpg")
    start=$(hexbytes "$jpg" head)
    end=$(hexbytes "$jpg" tail)
    if [ "$start" = "ff d8" ] && [ "$end" = "ff d9" ]; then verdict=complete; else verdict="TRUNCATED/INVALID"; fi
    echo "$verdict  size=$size start=[$start] end=[$end]  $(basename "$jpg")"
done

echo
echo "== Game switcher files in $MINUI/PSP*"
for d in "$MINUI"/PSP*; do
    [ -d "$d" ] || continue
    echo "-- $d"
    ls -lte "$d" 2>/dev/null || ls -lt "$d"
    for txt in "$d"/*.txt; do
        [ -f "$txt" ] || continue
        echo "slot file $(basename "$txt") = $(cat "$txt")"
    done
    for bmp in "$d"/*.bmp; do
        [ -f "$bmp" ] || continue
        echo "image $(basename "$bmp"): $(wc -c <"$bmp") bytes, starts [$(hexbytes "$bmp" head)] (42 4d = BMP, 89 50 = PNG)"
    done
done

echo
echo "== jpg2bmp check of each thumbnail"
J2B=""
for p in "$SD"/Emus/*/PSP.pak/bin/jpg2bmp; do [ -x "$p" ] && J2B="$p" && break; done
if [ -n "$J2B" ]; then
    echo "using $J2B"
    for jpg in "$STATES"/*.jpg; do
        [ -f "$jpg" ] || continue
        if out=$("$J2B" "$jpg" /tmp/diag-preview.bmp 2>&1); then
            echo "converts  $(basename "$jpg")"
        else
            echo "rejected  $(basename "$jpg"): $out"
        fi
        rm -f /tmp/diag-preview.bmp
    done
else
    echo "jpg2bmp not found under $SD/Emus/*/PSP.pak/bin"
fi

echo
echo "== PPSSPP settings that matter"
for ini in "$SD"/Emus/*/PSP.pak/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini; do
    [ -f "$ini" ] || continue
    echo "-- $ini"
    grep -iE '^(StateSlot|AutoLoadSaveState|EnableStateUndo|ScreenshotsAsPNG|GraphicsBackend) *=' "$ini"
done
for ini in "$SD"/Emus/*/PSP.pak/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini; do
    [ -f "$ini" ] || continue
    echo "-- $ini"
    grep -iE '^(Save State|Load State|Exit App|Pause|Rewind|Previous Slot|Next Slot) *=' "$ini"
done

echo
echo "== last pak log (preview lines and tail)"
for log in "$SD"/.userdata/*/logs/PSP.txt; do
    [ -f "$log" ] || continue
    echo "-- $log"
    grep -iE 'preview|jpg2bmp' "$log" | grep -v '^+' | tail -n 20
    echo "..."
    tail -n 15 "$log"
done

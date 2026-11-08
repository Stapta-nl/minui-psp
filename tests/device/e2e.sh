#!/bin/sh
# End-to-end test of the Game Switcher preview on a real TrimUI device (PR #9).
#
# Unlike run.sh (stub emulator, throw-away SD tree), this drives the REAL NextUI, the REAL
# PPSSPP pak and the real SD card, with no human at the buttons:
#   - buttons are injected by writing evdev events to the "TRIMUI Player1" pad,
#   - games are launched through NextUI's own /tmp/next hand-off,
#   - screenshots are taken with the "Screenshot Monitor" pak's bin/screenshot,
#   - screenshots are judged by the bundled pngcolor (average colour of the screen centre).
#
# Requirements on the device: root, NextUI, this PSP pak installed in Emus/<platform>/PSP.pak,
# the Screenshot Monitor pak installed in Tools/<platform>/Screenshot Monitor.pak, and at
# least one file in a "...(PSP)" folder under Roms/. The test uses the FIRST file there.
#
# Usage (from a phone or computer):
#   ssh root@<device> 'sh /path/to/tests/device/e2e.sh'
#
# It temporarily changes recents / resume files of the test game and restores them on exit.
# Do not touch the device while it runs. Results and screenshots: $OUT_DIR.
#
# Env overrides:
#   SDCARD_PATH (/mnt/SDCARD)  PLATFORM (tg5040)  ROM_DIR  ROM  OUT_DIR (/tmp/psp-e2e-out)
#   PSP_KEYS   space separated steps run inside PPSSPP after boot, to make a save state.
#              Steps: up down left right a b x y l1 r1 select start | sleep<sec> | shot
#              Default empty (no save state; the preview then comes from box art / placeholder).
#              Tip: first run with PSP_KEYS="select sleep1 shot" and look at $OUT_DIR/e2e-*.png
#              to see the PPSSPP pause menu, then script the clicks that save a state.
#   BOOT_WAIT (20)  UI_WAIT (4)  KEY_GAP (0.5)

HERE="$(cd "$(dirname "$0")" && pwd)"
SD="${SDCARD_PATH:-/mnt/SDCARD}"
PLATFORM="${PLATFORM:-tg5040}"
PAK="$SD/Emus/$PLATFORM/PSP.pak"
MON="$SD/Tools/$PLATFORM/Screenshot Monitor.pak"
SHARED="$SD/.userdata/shared"
LOGS="$SD/.userdata/$PLATFORM/logs"
OUT="${OUT_DIR:-/tmp/psp-e2e-out}"
BOOT_WAIT="${BOOT_WAIT:-20}"
UI_WAIT="${UI_WAIT:-4}"
KEY_GAP="${KEY_GAP:-0.5}"
PSP_KEYS="${PSP_KEYS:-}"
PNGCOLOR="$HERE/bin/pngcolor"
BAK="/tmp/psp-e2e-backup"

PASS=0
FAIL=0
CASE_FAIL=0

say() { echo "$*"; }
die() { echo "e2e: $*" >&2; exit 2; }

# --- preflight -----------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run as root (needed to write to /dev/input)"
[ -d "$PAK" ] || die "PSP pak not found at $PAK"
[ -x "$PAK/bin/jpg2bmp" ] || die "$PAK/bin/jpg2bmp missing (install the pak from the PR's CI artifact)"
[ -f "$MON/bin/screenshot" ] || die "Screenshot Monitor pak not found at $MON"
[ -x "$PNGCOLOR" ] || die "$PNGCOLOR missing (use the psp-device-tests artifact)"
[ -f /tmp/nextui_exec ] || die "NextUI launcher not running (/tmp/nextui_exec missing)"

PAD="$(awk '/^N: Name="TRIMUI Player1"/{f=1} f&&/^H: Handlers=/{for(i=1;i<=NF;i++) if($i ~ /^event/){print "/dev/input/" $i; exit}}' /proc/bus/input/devices)"
[ -c "$PAD" ] || die "TRIMUI Player1 input device not found"

if [ -z "$ROM_DIR" ]; then
    for d in "$SD"/Roms/*"(PSP)"; do
        [ -d "$d" ] && ROM_DIR="$d" && break
    done
fi
[ -d "$ROM_DIR" ] || die "no Roms/*(PSP) folder found (set ROM_DIR)"
if [ -z "$ROM" ]; then
    for f in "$ROM_DIR"/*; do
        [ -f "$f" ] && ROM="$f" && break
    done
fi
[ -f "$ROM" ] || die "no game file in $ROM_DIR (set ROM)"

# Same emu tag NextUI uses: the text in the last (...) of the Roms folder name.
tag="${ROM%/*}"
tag="${tag#"$SD"/Roms/}"
tag="${tag%%/*}"
case "$tag" in *"("*")"*) tag="${tag##*(}"; tag="${tag%%)*}" ;; esac
ROM_FILE="$(basename "$ROM")"
MINUI="$SHARED/.minui/$tag"
SLOT_FILE="$MINUI/$ROM_FILE.txt"
PREVIEW="$MINUI/$ROM_FILE.0.bmp"
RECORD="$MINUI/.ppsspp/$ROM_FILE.txt"
RECENT="$SHARED/.minui/recent.txt"
PERSIST="$SHARED/.minui/game_switcher.txt"
AUTORESUME="$SHARED/.minui/auto_resume.txt"
SHOTDIR="$SD/Screenshots"

mkdir -p "$OUT" "$BAK"
rm -f "$OUT"/*.png "$OUT"/*.log "$BAK/present" "$BAK/absent"
say "device pad: $PAD"
say "game:       $ROM"
say "emu tag:    $tag"

# --- back up everything we will touch, restore on exit ---------------------------------
for f in "$RECENT" "$PERSIST" "$AUTORESUME" "$SLOT_FILE" "$PREVIEW" "$RECORD"; do
    if [ -e "$f" ]; then
        mkdir -p "$BAK$(dirname "$f")"
        cp -p "$f" "$BAK$f"
        echo "$f" >>"$BAK/present"
    else
        echo "$f" >>"$BAK/absent"
    fi
done

restore() {
    pkill -f PPSSPPSDL 2>/dev/null
    rm -f /tmp/next
    while IFS= read -r f; do
        [ -n "$f" ] && cp -p "$BAK$f" "$f"
    done <"$BAK/present" 2>/dev/null
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done <"$BAK/absent" 2>/dev/null
    rm -f "$PERSIST.tmp"
    sync
    killall nextui.elf 2>/dev/null # relaunches NextUI with the restored files
    echo "restored; results in $OUT"
}
trap restore EXIT

# --- helpers ---------------------------------------------------------------------------
wait_for() { # wait_for <seconds> <command...>
    n="$1"
    shift
    while [ "$n" -gt 0 ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
        n=$((n - 1))
    done
    return 1
}
running() { pgrep "$1" >/dev/null 2>&1; }
not_running() { ! pgrep "$1" >/dev/null 2>&1; }

# Write one evdev event (24 bytes: 16 zero timestamp bytes, type, code, value) to the pad.
pad() { # pad <type> <code> <value>
    v=$(($3 & 4294967295))
    b() { printf '\\%03o' $(($1 & 255)); }
    # shellcheck disable=SC2059 # the format is built from octal escapes on purpose
    printf "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0$(b "$1")$(b $(($1 >> 8)))$(b "$2")$(b $(($2 >> 8)))$(b "$v")$(b $((v >> 8)))$(b $((v >> 16)))$(b $((v >> 24)))" >"$PAD"
}
syn() { pad 0 0 0; }

press() { # press <button name>
    case "$1" in
    b) t=1 c=304 ;;
    a) t=1 c=305 ;;
    y) t=1 c=307 ;;
    x) t=1 c=308 ;;
    l1) t=1 c=310 ;;
    r1) t=1 c=311 ;;
    select) t=1 c=314 ;;
    start) t=1 c=315 ;;
    left) t=3 c=16 val=-1 ;;
    right) t=3 c=16 val=1 ;;
    up) t=3 c=17 val=-1 ;;
    down) t=3 c=17 val=1 ;;
    *) echo "unknown button: $1" >&2; return 1 ;;
    esac
    val="${val:-1}"
    pad "$t" "$c" "$val"
    syn
    sleep 0.05 # short, or NextUI's key repeat moves the selection more than once
    pad "$t" "$c" 0
    syn
    val=""
}

# shot <label>: takes a screenshot with the Screenshot Monitor pak, keeps it in $OUT.
shot() {
    sleep 1 # the pak names files by the second
    before="$(ls "$SHOTDIR" 2>/dev/null)"
    SDCARD_PATH="$SD" PATH="$MON/bin/$PLATFORM:$MON/bin:$PATH" sh "$MON/bin/screenshot" >"$OUT/$1.shot.log" 2>&1
    # shellcheck disable=SC2012 # names come from the screenshot pak (date based), ls -t is fine
    newest="$(ls -t "$SHOTDIR" 2>/dev/null | head -n 1)"
    SHOT=""
    SHOT_NAME=""
    if [ -n "$newest" ] && ! printf '%s\n' "$before" | grep -qxF "$newest"; then
        SHOT="$OUT/$1.png"
        SHOT_NAME="$newest"
        mv "$SHOTDIR/$newest" "$SHOT"
    fi
}

colour() { "$PNGCOLOR" "$1" 2>/dev/null; } # prints "R G B"
# shellcheck disable=SC2046,SC2086 # word splitting of "R G B" is intended
is_red() { set -- $(colour "$1"); [ -n "$3" ] && [ "$1" -gt $(($2 + 60)) ] && [ "$1" -gt $(($3 + 60)) ]; }
# shellcheck disable=SC2046,SC2086
is_blue() { set -- $(colour "$1"); [ -n "$3" ] && [ "$3" -gt $(($1 + 60)) ] && [ "$3" -gt $(($2 + 60)) ]; }
not_fixture() { ! is_red "$1" && ! is_blue "$1"; }

begin() { CASE="$1"; CASE_FAIL=0; say "[$CASE]"; }
check() {
    d="$1"
    shift
    if "$@"; then say "  ok   $d"; else say "  FAIL $d"; CASE_FAIL=1; fi
}
end() {
    if [ "$CASE_FAIL" = 0 ]; then PASS=$((PASS + 1)); say "PASS $CASE"; else FAIL=$((FAIL + 1)); say "FAIL $CASE"; fi
}

seed_recent() { mkdir -p "$(dirname "$RECENT")" && printf '%s\n' "$ROM" >"$RECENT"; }

restart_ui() {
    killall nextui.elf 2>/dev/null
    sleep 1
    wait_for 40 running nextui.elf && sleep "$UI_WAIT"
}

open_switcher() { # restarts NextUI directly into the Game Switcher
    printf unused >"$PERSIST"
    restart_ui
}

have_shot() { [ -n "$SHOT" ] && [ -s "$SHOT" ]; }
is_image() { head -c 2 "$1" | grep -q BM || head -c 4 "$1" | tail -c 3 | grep -q PNG; }

# --- E1: NextUI renders the BMP that jpg2bmp makes -------------------------------------
begin "E1 NextUI shows converted thumbnails in the Game Switcher"
mkdir -p "$MINUI/.ppsspp"
seed_recent
printf 0 >"$SLOT_FILE"

"$PAK/bin/jpg2bmp" "$HERE/fixtures/thumb1.jpg" "$PREVIEW"
open_switcher
shot e1-red
check "screenshot taken" have_shot
check "switcher shows the red thumbnail" is_red "$SHOT"

"$PAK/bin/jpg2bmp" "$HERE/fixtures/thumb2.jpg" "$PREVIEW"
open_switcher
shot e1-blue
check "screenshot taken" have_shot
check "switcher shows the blue thumbnail" is_blue "$SHOT"

rm -f "$PREVIEW"
open_switcher
shot e1-nopreview
check "no preview file: switcher shows neither fixture colour" not_fixture "$SHOT"
end

# --- E2: real PPSSPP run, exit, preview written, switcher shows it ----------------------
begin "E2 real PPSSPP launch, exit, preview, switcher"
rm -f "$SLOT_FILE" "$PREVIEW" "$RECORD" "$PERSIST"
seed_recent
printf "'%s/launch.sh' '%s'\n" "$PAK" "$ROM" >/tmp/next
killall nextui.elf 2>/dev/null
check "PPSSPP started" wait_for 60 running PPSSPPSDL
sleep "$BOOT_WAIT"

shot e2-game
check "screenshot of the running game taken" have_shot
case "$SHOT_NAME" in Screenshot.*) named=0 ;; *) named=1 ;; esac
check "game screenshot is named after the game ($SHOT_NAME)" test "$named" = 1

i=0
for k in $PSP_KEYS; do
    i=$((i + 1))
    case "$k" in
    sleep*) sleep "${k#sleep}" ;;
    shot) shot "e2-step$i" ;;
    *) press "$k"; sleep "$KEY_GAP" ;;
    esac
done

killall PPSSPPSDL_"$PLATFORM" 2>/dev/null || pkill -f PPSSPPSDL
check "PPSSPP exited" wait_for 30 not_running PPSSPPSDL
check "NextUI is back" wait_for 90 running nextui.elf
sleep "$UI_WAIT"
cp "$LOGS/PSP.txt" "$OUT/e2-PSP.log" 2>/dev/null

check "slot file written" grep -q '^[0-9][0-9]*$' "$SLOT_FILE"
check "preview file written" test -s "$PREVIEW"
check "preview is a BMP/PNG" is_image "$PREVIEW"
check "record file has a source" grep -q '^source=' "$RECORD"
if [ -n "$PSP_KEYS" ]; then
    check "record: source=thumbnail (state was saved)" grep -q '^source=thumbnail$' "$RECORD"
    check "log: preview from save state" sh -c "grep -v '^+' '$OUT/e2-PSP.log' | grep -q 'Game switcher preview from save state'"
fi
say "  info: $(tr '\n' ' ' <"$RECORD" 2>/dev/null)"

open_switcher
shot e2-switcher
check "switcher screenshot taken" have_shot
with_preview="$SHOT"
mv "$PREVIEW" "$PREVIEW.off"
open_switcher
shot e2-switcher-nopreview
check "switcher screenshot without preview taken" have_shot
mv "$PREVIEW.off" "$PREVIEW"
check "preview changes what the switcher shows" test "$(cksum <"$with_preview")" != "$(cksum <"$SHOT")"
end

say
say "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

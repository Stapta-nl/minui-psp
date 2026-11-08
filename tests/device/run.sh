#!/bin/sh
# On-device (or host) test of the Game Switcher preview logic in launch.sh (PR #9).
#
# It runs the *real* launch.sh and the *real* bin/jpg2bmp inside a throw-away SD card
# tree, with a stub standing in for PPSSPP and minui-power-control. So it checks what the
# PR's on-device table is really about (BusyBox cksum/cmp/sed, the aarch64 converter, the
# NextUI file layout, SIGTERM handling) without needing a screen or button presses.
# Nothing under the real SD card is touched; the sandbox is deleted afterwards.
#
# Usage (on the device, over ssh):
#   scp -r tests root@device:/mnt/SDCARD/Emus/tg5040/PSP.pak/
#   ssh root@device 'sh /mnt/SDCARD/Emus/tg5040/PSP.pak/tests/device/run.sh'
# Output: PASS/FAIL per test, exit code 0 only if all pass. Logs are kept in $OUT_DIR.
#
# Env overrides:
#   SRC_PAK    pak to test (default: two directories above this script)
#   JPG2BMP    jpg2bmp binary to use instead of $SRC_PAK/bin/jpg2bmp (host runs)
#   PLATFORM   tg5040 (default) or tg5050
#   OUT_DIR    where to keep logs and sandbox files on failure (default /tmp/psp-preview-test-out)
#   KEEP=1     keep the sandbox

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_PAK="${SRC_PAK:-$(cd "$HERE/../.." && pwd)}"
FIX="$HERE/fixtures"
PLATFORM="${PLATFORM:-tg5040}"
OUT_DIR="${OUT_DIR:-/tmp/psp-preview-test-out}"
T="$(mktemp -d /tmp/psp-preview-test.XXXXXX)" || exit 2

SD="$T/sd"
PAK="$SD/Emus/$PLATFORM/PSP.pak"
USERDATA="$SD/.userdata/$PLATFORM"
SHARED="$SD/.userdata/shared"
LOGS="$USERDATA/logs"
ROMS="$SD/Roms"
ROMDIR="$ROMS/PlayStation Portable (PSP)"
MINUI="$SHARED/.minui/PSP"
STATES="$SHARED/PSP-ppsspp"
STUB="$T/stub"
INI="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"

PASS=0
FAIL=0
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

finish() {
    if [ -n "$KEEP" ] || [ "$FAIL" -gt 0 ]; then
        cp -R "$MINUI" "$OUT_DIR/minui-PSP" 2>/dev/null
        ls -l "$STATES" >"$OUT_DIR/states-listing.txt" 2>/dev/null
        echo "Logs and files kept in $OUT_DIR"
    fi
    [ -n "$KEEP" ] || rm -rf "$T"
}
trap finish EXIT

check() { # check <description> <command...>
    desc="$1"
    shift
    if "$@"; then
        echo "  ok   $desc"
    else
        echo "  FAIL $desc"
        CASE_FAIL=1
    fi
}

begin() {
    CASE="$1"
    CASE_FAIL=0
    echo "[$CASE]"
}

end() {
    if [ "$CASE_FAIL" = 0 ]; then
        PASS=$((PASS + 1))
        echo "PASS $CASE"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL $CASE"
    fi
}

contains() { grep -q -- "$2" "$1"; }
lacks() { ! grep -q -- "$2" "$1"; }
same() { cmp -s "$1" "$2"; }

# --- sandbox -------------------------------------------------------------------------
mkdir -p "$PAK/bin" "$PAK/res" "$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM" "$LOGS" "$ROMDIR/.media" "$MINUI" "$STATES" "$STUB"
cp "$SRC_PAK/launch.sh" "$SRC_PAK/pak.json" "$PAK/"
cp "$SRC_PAK"/res/* "$PAK/res/"
cp "$SRC_PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" "$INI"
cp "${JPG2BMP:-$SRC_PAK/bin/jpg2bmp}" "$PAK/bin/jpg2bmp" || { echo "no jpg2bmp found (set JPG2BMP)"; exit 2; }
chmod +x "$PAK/bin/jpg2bmp"

# Stubs for hardware helpers so nothing touches the screen or the real power control.
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/minui-power-control"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/setalpha"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/show_message"

# Fake PPSSPP: records its args, then runs $STUB/actions:
#   save <fixture> <prefix> <slot>   write <prefix>_<slot>.jpg (+ .ppst) into the state dir
#   sleep <n>                         wait n seconds (lets mtimes differ)
#   hang                              wait until killed (like a running emulator)
cat >"$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$STUB/args"
echo $$ >"$STUB/pid"
while read -r action a b c; do
    case "$action" in
    save)
        cp "$FIX/$a.jpg" "$STATES/${b}_${c}.jpg"
        printf 'state' >"$STATES/${b}_${c}.ppst"
        touch "$STUB/saved"
        ;;
    sleep) sleep "$a" ;;
    hang) exec sleep 300 ;;
    esac
done <"$STUB/actions"
EOF
chmod +x "$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" "$PAK/bin/"*

printf 'a' >"$ROMDIR/Game A.iso"
printf 'b' >"$ROMDIR/Game B.iso"
printf 'c' >"$ROMDIR/Game C.iso"
cp "$FIX/boxart.png" "$ROMDIR/.media/Game A.png"

export PLATFORM DEVICE=brick SDCARD_PATH="$SD" USERDATA_PATH="$USERDATA" LOGS_PATH="$LOGS" \
    SHARED_USERDATA_PATH="$SHARED" ROMS_PATH="$ROMS" STUB FIX STATES
mkdir -p "$USERDATA/PSP-ppsspp"
touch "$USERDATA/PSP-ppsspp/debug" # trace logging, like the PR's setup step

PLACEHOLDER="$PAK/res/game-switcher-placeholder.png"
conv() { "$PAK/bin/jpg2bmp" "$FIX/$1.jpg" "$T/expected-$1.bmp" && echo "$T/expected-$1.bmp"; }

# run_game <rom file> [action lines...]: runs launch.sh to completion and saves its log.
run_game() {
    rom="$1"
    shift
    rm -f "$STUB/args" "$STUB/pid" "$STUB/saved"
    printf '%s\n' "$@" >"$STUB/actions"
    sh "$PAK/launch.sh" "$ROMDIR/$rom" >"$T/launch.out" 2>&1
    cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
}

preview() { echo "$MINUI/$1.0.bmp"; }
record() { echo "$MINUI/.ppsspp/$1.txt"; }

# --- tests (numbering follows the PR description) ------------------------------------
begin "1 no art, no states -> placeholder"
run_game "Game B.iso" "sleep 0"
check "slot file holds 0" contains "$MINUI/Game B.iso.txt" '^0$'
check "preview is the placeholder" same "$(preview "Game B.iso")" "$PLACEHOLDER"
check "record: source=placeholder" contains "$(record "Game B.iso")" '^source=placeholder$'
end

begin "2 boxart, no states -> boxart"
run_game "Game A.iso" "sleep 0"
check "preview is the boxart" same "$(preview "Game A.iso")" "$ROMDIR/.media/Game A.png"
check "record: source=boxart" contains "$(record "Game A.iso")" '^source=boxart$'
end

begin "3 save state -> thumbnail"
run_game "Game C.iso" "save thumb1 ULUS10041_1.00 0"
check "preview is converted thumb1" same "$(preview "Game C.iso")" "$(conv thumb1)"
check "preview is a real BMP" sh -c "head -c 2 '$(preview "Game C.iso")' | grep -q BM"
check "log says from save state" contains "$OUT_DIR/$CASE.log" 'Game switcher preview from save state'
check "record: source=thumbnail" contains "$(record "Game C.iso")" '^source=thumbnail$'
check "record: prefix=ULUS10041_1.00" contains "$(record "Game C.iso")" '^prefix=ULUS10041_1.00$'
end

begin "4 two saves -> the second wins"
run_game "Game C.iso" "save thumb1 ULUS10041_1.00 1" "sleep 2" "save thumb2 ULUS10041_1.00 2"
check "preview is converted thumb2" same "$(preview "Game C.iso")" "$(conv thumb2)"
end

begin "5 other game without saving keeps its placeholder"
run_game "Game B.iso" "sleep 0"
check "B still placeholder, not C's screenshot" same "$(preview "Game B.iso")" "$PLACEHOLDER"
check "B record: source=placeholder" contains "$(record "Game B.iso")" '^source=placeholder$'
end

begin "6 boxart added later replaces placeholder"
cp "$FIX/boxart.png" "$ROMDIR/.media/Game B.png"
run_game "Game B.iso" "sleep 0"
check "B preview is boxart" same "$(preview "Game B.iso")" "$ROMDIR/.media/Game B.png"
check "B record: source=boxart" contains "$(record "Game B.iso")" '^source=boxart$'
end

begin "6b boxart never downgrades a thumbnail"
run_game "Game C.iso" "sleep 0"
check "C preview still thumb2" same "$(preview "Game C.iso")" "$(conv thumb2)"
end

begin "7a resume with auto-load on: no --state argument"
printf '2' >/tmp/resume_slot.txt
run_game "Game C.iso" "sleep 0"
check "resume_slot.txt consumed" test ! -f /tmp/resume_slot.txt
check "no --state passed" lacks "$STUB/args" '^--state='
end

begin "7b resume with auto-load off: newest .ppst passed"
sed -i 's/^AutoLoadSaveState *=.*/AutoLoadSaveState = 0/' "$INI"
printf '2' >/tmp/resume_slot.txt
run_game "Game C.iso" "sleep 0"
check "--state points at newest state (slot 2)" contains "$STUB/args" "^--state=.*ULUS10041_1.00_2.ppst$"
sed -i 's/^AutoLoadSaveState *=.*/AutoLoadSaveState = 2/' "$INI"
end

begin "8 SIGTERM (power off) still writes the preview, once"
rm -f "$STUB/args" "$STUB/pid" "$STUB/saved"
printf '%s\n' "save thumb1 ULUS10041_1.00 3" "hang" >"$STUB/actions"
sh "$PAK/launch.sh" "$ROMDIR/Game C.iso" >"$T/launch.out" 2>&1 &
LAUNCH_PID=$!
i=0
while [ ! -f "$STUB/saved" ] && [ "$i" -lt 100 ]; do sleep 0.1 2>/dev/null || sleep 1; i=$((i + 1)); done
sleep 1
kill -TERM "$LAUNCH_PID" 2>/dev/null
kill -TERM "$(cat "$STUB/pid" 2>/dev/null)" 2>/dev/null
wait "$LAUNCH_PID" 2>/dev/null
cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
check "preview is converted thumb1 (slot 3 is newest)" same "$(preview "Game C.iso")" "$(conv thumb1)"
check "log says from save state" contains "$OUT_DIR/$CASE.log" 'Game switcher preview from save state'
check "preview written exactly once" test "$(grep -v '^+' "$OUT_DIR/$CASE.log" | grep -c 'Game switcher preview from save state')" = 1
end

begin "9 jpg2bmp works on this CPU and rejects junk"
echo "  info: $(uname -m)"
printf 'not an image' >"$T/junk.jpg"
check "converts a JPEG" "$PAK/bin/jpg2bmp" "$FIX/thumb1.jpg" "$T/out.bmp"
check "rejects junk with non-zero exit" sh -c "! '$PAK/bin/jpg2bmp' '$T/junk.jpg' '$T/junk.bmp' 2>/dev/null"
check "no tmp files left behind" sh -c "[ -z \"\$(find '$MINUI' -name '*.tmp')\" ]"
end

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

#!/bin/sh
# Test of the auto-resume-at-power-off logic in launch.sh and of the poweroff handshake.
#
# Runs the *real* launch.sh in a throw-away SD card tree against a stub PPSSPP
# (with and without the PPSSPP_AUTORESUME_STATE capability string). The stub plays
# the part of the power button: it creates /tmp/psp-poweroff-req like bin/poweroff
# does. Nothing under the real SD card is touched. It does use the fixed /tmp paths
# launch.sh uses (/tmp/psp-*, /tmp/resume_slot.txt, /tmp/stay_awake).
#
# Usage: sh tests/device/autoresume.sh      (env: SRC_PAK, PLATFORM, OUT_DIR, KEEP=1)

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_PAK="${SRC_PAK:-$(cd "$HERE/../.." && pwd)}"
PLATFORM="${PLATFORM:-tg5040}"
OUT_DIR="${OUT_DIR:-/tmp/psp-autoresume-test-out}"
T="$(mktemp -d /tmp/psp-autoresume-test.XXXXXX)" || exit 2

SD="$T/sd"
PAK="$SD/Emus/$PLATFORM/PSP.pak"
USERDATA="$SD/.userdata/$PLATFORM"
SHARED="$SD/.userdata/shared"
LOGS="$USERDATA/logs"
ROMDIR="$SD/Roms/PlayStation Portable (PSP)"
STATES="$SHARED/PSP-ppsspp"
STUB="$T/stub"
MARKER="$SHARED/.minui/auto_resume.txt"
STATEFILE="$STATES/autoresume/Game B.iso.ppst"
EMU="$PAK/PPSSPP/PPSSPPSDL_$PLATFORM"
REQ=/tmp/psp-poweroff-req
OK=/tmp/psp-poweroff-ok
PIDFILE=/tmp/psp-pak.pid

PASS=0
FAIL=0
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
LAUNCH_PID=""

finish() {
    [ -n "$LAUNCH_PID" ] && kill -KILL "$LAUNCH_PID" 2>/dev/null
    rm -f "$REQ" "$OK" "$PIDFILE" /tmp/resume_slot.txt
    [ -n "$KEEP" ] || [ "$FAIL" -gt 0 ] && echo "Logs kept in $OUT_DIR"
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
absent() { [ ! -e "$1" ]; }
present() { [ -e "$1" ]; }

mkdir -p "$PAK/bin" "$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM" "$LOGS" "$ROMDIR" "$STATES" "$STUB"
cp "$SRC_PAK/launch.sh" "$SRC_PAK/pak.json" "$PAK/"
cp -R "$SRC_PAK/scripts" "$PAK/"
cp "$SRC_PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" "$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/minui-power-control"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/setalpha"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/show_message"
printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/jpg2bmp"
chmod +x "$PAK/bin/"*
printf 'b' >"$ROMDIR/Game B.iso"

# Fake PPSSPP. $1 of the actions file lines:
#   poweroff   like the power button: create the request file (bin/poweroff does it)
#   save       like the patched PPSSPP on SIGTERM: <state>.tmp -> <state>, then <state>.done
#   savefail   write <state>.fail only
write_stub() { # write_stub with|without
    {
        echo '#!/bin/sh'
        [ "$1" = with ] && echo '# PPSSPP_AUTORESUME_STATE capability string'
        cat <<'STUB_BODY'
printf '%s\n' "$@" >"$STUB/args"
# The name is split so this stub only carries the capability string when asked to.
eval "S=\${PPSSPP_AUTORESUME_ST""ATE-unset}"
echo "$S" >"$STUB/env"
cat /tmp/psp-pak.pid >"$STUB/pakpid" 2>/dev/null
while read -r action; do
    case "$action" in
    poweroff) : >/tmp/psp-poweroff-req ;;
    save)
        printf 'state' >"$S.tmp"
        mv "$S.tmp" "$S"
        : >"$S.done"
        ;;
    savefail) : >"$S.fail" ;;
    esac
done <"$STUB/actions"
STUB_BODY
    } >"$EMU"
    chmod +x "$EMU"
}

export PLATFORM DEVICE=brick SDCARD_PATH="$SD" USERDATA_PATH="$USERDATA" LOGS_PATH="$LOGS" \
    SHARED_USERDATA_PATH="$SHARED" ROMS_PATH="$SD/Roms" STUB
mkdir -p "$USERDATA/PSP-ppsspp"
touch "$USERDATA/PSP-ppsspp/debug"

wait_for() { # wait_for <file> : up to ~15 s
    i=0
    while [ ! -e "$1" ] && [ "$i" -lt 150 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    [ -e "$1" ]
}

# run_game <stub: with|without> <resume slot or ""> <actions...>: runs launch.sh. A
# power-off ends with launch.sh waiting for the device to die (poweroff would SIGKILL
# it): wait for the "ok" file, check what the test wants, then SIGKILL it.
run_game() {
    write_stub "$1"
    slot="$2"
    shift 2
    rm -f "$STUB/args" "$STUB/env" "$STUB/pakpid" "$REQ" "$OK" "$MARKER" /tmp/resume_slot.txt
    printf '%s\n' "$@" >"$STUB/actions"
    [ -n "$slot" ] && printf '%s' "$slot" >/tmp/resume_slot.txt
    sh "$PAK/launch.sh" "$ROMDIR/Game B.iso" >"$T/launch.out" 2>&1 &
    LAUNCH_PID=$!
    case " $* " in
    *" poweroff "*)
        wait_for "$OK"
        MARKER_AT_OK="$(cat "$MARKER" 2>/dev/null)"
        kill -KILL "$LAUNCH_PID" 2>/dev/null
        ;;
    esac
    wait "$LAUNCH_PID" 2>/dev/null
    LAUNCH_PID=""
    cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
}

LOG="$OUT_DIR/current.log"
use_log() { LOG="$OUT_DIR/$CASE.log"; }
EXPECT_MARKER="/Roms/PlayStation Portable (PSP)/Game B.iso"

begin "1 old PPSSPP (no capability): power-off arms the marker, then answers the shim"
run_game without "" poweroff
use_log
check "marker holds the ROM path when ok is given" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "pid file held launch.sh pid while PPSSPP ran" test -s "$STUB/pakpid"
check "no state env var passed" contains "$STUB/env" '^unset$'
check "no --state argument" lacks "$STUB/args" '^--state='
check "no autoresume dir created" absent "$STATES/autoresume"
check "log says power-off detected" contains "$LOG" 'Power-off detected: .*psp-poweroff-req'
end

begin "2 patched PPSSPP saved the state: marker armed, state kept"
run_game with "" save poweroff
use_log
check "marker armed at ok time" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "env var points at the state file" contains "$STUB/env" "^$STATEFILE\$"
check "state file kept" present "$STATEFILE"
check "done file present" present "$STATEFILE.done"
check "log says state saved" contains "$LOG" 'Power-off state saved'
end

begin "3 patched PPSSPP failed to save: marker armed anyway, stale state dropped"
mkdir -p "$STATES/autoresume"
printf 'old' >"$STATEFILE"
run_game with "" savefail poweroff
use_log
check "marker armed at ok time" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "state file removed" absent "$STATEFILE"
check "log says not saved" contains "$LOG" 'Power-off state NOT saved'
end

begin "4 patched PPSSPP, no .done file at all: same fallback"
run_game with "" poweroff
use_log
check "marker armed at ok time" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "no state file" absent "$STATEFILE"
check "log says not saved" contains "$LOG" 'Power-off state NOT saved'
end

begin "5 resume (slot 9) with a state file starts PPSSPP from it"
mkdir -p "$STATES/autoresume"
printf 'state' >"$STATEFILE"
run_game with 9 "sleep"
use_log
check "--state passed" contains "$STUB/args" "^--state=$STATEFILE\$"
check "slot file consumed" absent /tmp/resume_slot.txt
check "no marker on a normal quit" absent "$MARKER"
check "state removed after a normal quit" absent "$STATEFILE"
end

begin "6 normal open (slot 8) never uses the state file and drops it"
mkdir -p "$STATES/autoresume"
printf 'state' >"$STATEFILE"
run_game with 8 "sleep"
use_log
check "no --state argument" lacks "$STUB/args" '^--state='
check "state removed" absent "$STATEFILE"
check "no marker" absent "$MARKER"
check "shim files absent" absent "$OK"
end

begin "7 resume (slot 9) without a state file: plain launch"
rm -f "$STATEFILE"
run_game with 9 "sleep"
check "no --state argument" lacks "$STUB/args" '^--state='
end

begin "8 old PPSSPP never uses a leftover state file"
mkdir -p "$STATES/autoresume"
printf 'state' >"$STATEFILE"
run_game without 9 "sleep"
check "no --state argument" lacks "$STUB/args" '^--state='
check "user save-state dir untouched" present "$STATEFILE"
end

begin "9 stale request/ok files from an earlier boot are ignored"
: >"$REQ"
: >"$OK"
write_stub without
printf 'sleep\n' >"$STUB/actions"
sh "$PAK/launch.sh" "$ROMDIR/Game B.iso" >"$T/launch.out" 2>&1
check "treated as a normal quit: no marker" absent "$MARKER"
check "stale request removed" absent "$REQ"
check "stale ok removed" absent "$OK"
check "pid file removed on exit" absent "$PIDFILE"
end

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

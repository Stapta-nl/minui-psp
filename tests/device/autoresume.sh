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

# launch.sh uses fixed /tmp paths (/tmp/psp-*, /tmp/resume_slot.txt, /tmp/stay_awake) and the
# power-off handshake is device-wide: never run on a real device or next to a running pak.
if [ -d /mnt/SDCARD/.system ] && [ -z "$PSP_TEST_ALLOW_DEVICE" ]; then
    echo "autoresume.sh: this looks like a real device; refusing (set PSP_TEST_ALLOW_DEVICE=1 to override)" >&2
    exit 2
fi
other_pid="$(cat /tmp/psp-pak.pid 2>/dev/null)"
if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null; then
    echo "autoresume.sh: a PSP pak is running (pid $other_pid); refusing" >&2
    exit 2
fi
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
ROMFILE="$ROMDIR/Game B.iso"
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
    # launch.sh bind-mounts into the sandbox; a SIGKILL can leave them behind.
    for m in "$PAK/PPSSPP/.config/ppsspp/PSP/SAVEDATA" "$PAK/PPSSPP/.config/ppsspp/PSP/PPSSPP_STATE"; do
        umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
    done
    rm -f "$REQ" "$OK" "$PIDFILE" /tmp/resume_slot.txt
    if [ -n "$KEEP" ] || [ "$FAIL" -gt 0 ]; then echo "Logs kept in $OUT_DIR"; fi
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
# A missing file is a failure, not "lacks": it would hide a stub that never ran.
lacks() { [ -f "$1" ] && ! grep -q -- "$2" "$1"; }
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
# The real shim, deliberately without the exec bit: launch.sh must set it.
cp "$SRC_PAK/bin/poweroff" "$PAK/bin/poweroff"
chmod -x "$PAK/bin/poweroff"
# Fake system poweroff for the shim: records the marker as it is when poweroff runs.
cat >"$T/fake-poweroff" <<FAKE
#!/bin/sh
cat "$MARKER" >"$STUB/marker_at_poweroff" 2>/dev/null
echo "\$*" >"$STUB/real-called"
FAKE
chmod +x "$T/fake-poweroff"
export PSP_POWEROFF_REAL="$T/fake-poweroff"
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
    shim)
        # the real bin/poweroff, found through PATH like the shutdown script does
        poweroff -f &
        i=0
        while [ ! -e /tmp/psp-poweroff-req ] && [ "$i" -lt 100 ]; do
            sleep 0.1 2>/dev/null || sleep 1
            i=$((i + 1))
        done
        ;;
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
    rm -f "$STUB/real-called" "$STUB/marker_at_poweroff"
    LAUNCH_HUNG=""
    sh "$PAK/launch.sh" "$ROMFILE" >"$T/launch.out" 2>&1 &
    LAUNCH_PID=$!
    case " $* " in
    *" poweroff "* | *" shim "*)
        if [ -n "$NOKILL" ]; then
            # launch.sh must return by itself (nothing armed, or the give-up path)
            i=0
            while kill -0 "$LAUNCH_PID" 2>/dev/null && [ "$i" -lt 20 ]; do
                sleep 1
                i=$((i + 1))
            done
            if kill -0 "$LAUNCH_PID" 2>/dev/null; then LAUNCH_HUNG=1; fi
            kill -KILL "$LAUNCH_PID" 2>/dev/null
        else
            wait_for "$OK"
            MARKER_AT_OK="$(cat "$MARKER" 2>/dev/null)"
            sleep 1 # let cleanup() unmount before the "power cut"
            kill -KILL "$LAUNCH_PID" 2>/dev/null
        fi
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

begin "10 give-up path: device does not power off, marker removed, back to the menu"
PSP_AUTORESUME_WAIT=2 NOKILL=1 run_game without "" poweroff
use_log
check "launch.sh returned by itself" test -z "$LAUNCH_HUNG"
check "marker removed again" absent "$MARKER"
check "req/ok removed" absent "$REQ"
check "log says device did not power off" contains "$LOG" 'Device did not power off'
end

begin "11 ROM outside the SD card: nothing armed, no 60 s wait, shim released"
mkdir -p "$T/outside"
printf 'o' >"$T/outside/Game O.iso"
ROMFILE="$T/outside/Game O.iso" NOKILL=1 run_game without "" poweroff
use_log
check "launch.sh returned by itself" test -z "$LAUNCH_HUNG"
check "no marker" absent "$MARKER"
check "shim released anyway" present "$OK"
check "log says not armed" contains "$LOG" 'Auto-resume not armed'
end

begin "12 the real poweroff shim talks to launch.sh, marker is there when poweroff runs"
run_game without "" shim
use_log
check "marker armed at ok time" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "shim reached the real poweroff" wait_for "$STUB/real-called"
check "real poweroff got the args" contains "$STUB/real-called" '^-f$'
check "marker was on disk when poweroff ran" contains "$STUB/marker_at_poweroff" "Game B.iso"
check "log says power-off detected" contains "$LOG" 'Power-off detected: .*psp-poweroff-req'
end

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

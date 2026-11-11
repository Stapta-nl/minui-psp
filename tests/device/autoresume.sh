#!/bin/sh
# Test of the auto-resume-at-power-off logic in launch.sh and of the poweroff handshake.
#
# Runs the *real* launch.sh and the real bin/poweroff shim in a throw-away SD card tree
# against a stub PPSSPP that behaves like PPSSPP with "Save state on exit": on SIGTERM
# (and on a normal quit) it saves a state plus thumbnail to slot 0, taking a moment,
# then exits. With the setting off ("nosave") it exits on SIGTERM without saving.
# The test plays the power button's shutdown script: it starts `poweroff` (the shim,
# through launch.sh's PATH order) and sends SIGTERM to PPSSPP. Nothing under the real
# SD card is touched. It does use the fixed /tmp paths launch.sh uses (/tmp/psp-*,
# /tmp/resume_slot.txt, /tmp/stay_awake).
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
FIX="$HERE/fixtures"
# PPSSPP names states <DISC_ID>_<DISC_VERSION>_<slot>; slot 0 is the shipped StateSlot.
PREFIX="ULUS10041_1.00"
EXIT_STATE="$STATES/${PREFIX}_0.ppst"
EXIT_THUMB="$STATES/${PREFIX}_0.jpg"
PREVIEW="$SHARED/.minui/PSP/Game B.iso.0.bmp"
PREVIEW_SLOT="$SHARED/.minui/PSP/Game B.iso.txt"
EMU="$PAK/PPSSPP/PPSSPPSDL_$PLATFORM"
ROMFILE="$ROMDIR/Game B.iso"
REQ=/tmp/psp-poweroff-req
OK=/tmp/psp-poweroff-ok
PIDFILE=/tmp/psp-pak.pid

# launch.sh bind-mounts into the sandbox, which needs root. Unprivileged (e.g. the GitHub
# runner), go through sudo; without it the mounts would silently fail, launch.sh would
# (correctly) skip its umounts, and the teardown checks would test nothing.
SUDO=""
if [ "$(id -u)" != 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "autoresume.sh: needs root or passwordless sudo for launch.sh's bind mounts" >&2
        exit 2
    fi
    SUDO="sudo -n"
fi

PASS=0
FAIL=0
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
LAUNCH_PID=""

# Mounts of a launch.sh that was SIGKILLed (stacked ones need several umounts).
drop_mounts() {
    for m in "$PAK/PPSSPP/.config/ppsspp/PSP/SAVEDATA" "$PAK/PPSSPP/.config/ppsspp/PSP/PPSSPP_STATE"; do
        n=0
        while grep -q " $m " /proc/self/mountinfo 2>/dev/null && [ "$n" -lt 10 ]; do
            $SUDO umount "$m" 2>/dev/null || $SUDO umount -l "$m" 2>/dev/null
            n=$((n + 1))
        done
    done
}

finish() {
    [ -n "$LAUNCH_PID" ] && kill -KILL "$LAUNCH_PID" 2>/dev/null
    # launch.sh bind-mounts into the sandbox; a SIGKILL can leave them behind.
    drop_mounts
    rm -f "$REQ" "$OK" "$PIDFILE" /tmp/resume_slot.txt /tmp/psp-poweroff-shim.log
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
    drop_mounts
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
# Stand-in converter: the "BMP" is a copy of the thumbnail (run.sh tests the real one).
# shellcheck disable=SC2016 # $1/$2 belong to the generated script
printf '#!/bin/sh\ncp "$1" "$2"\n' >"$PAK/bin/jpg2bmp"
if [ -n "$SUDO" ]; then
    printf '#!/bin/sh\nexec sudo -n /bin/mount "$@"\n' >"$PAK/bin/mount"
    printf '#!/bin/sh\nexec sudo -n /bin/umount "$@"\n' >"$PAK/bin/umount"
fi
chmod +x "$PAK/bin/"*
# The real shim, deliberately without the exec bit: launch.sh must set it.
cp "$SRC_PAK/bin/poweroff" "$PAK/bin/poweroff"
chmod -x "$PAK/bin/poweroff"
# Fake system poweroff for the shim: records what is on disk when poweroff runs.
cat >"$T/fake-poweroff" <<FAKE
#!/bin/sh
cat "$MARKER" >"$STUB/marker_at_poweroff" 2>/dev/null
[ -f "$EXIT_STATE" ] && [ -f "$EXIT_THUMB" ] && : >"$STUB/state_at_poweroff"
[ -f "$PREVIEW" ] && [ -f "$PREVIEW_SLOT" ] && : >"$STUB/preview_at_poweroff"
echo "\$*" >"$STUB/real-called"
FAKE
chmod +x "$T/fake-poweroff"
export PSP_POWEROFF_REAL="$T/fake-poweroff"
printf 'b' >"$ROMDIR/Game B.iso"

# Fake PPSSPP. $STUB/mode is "save" (Save state on exit on) or "nosave" (off).
# Lines of $STUB/actions:
#   save <slot>  the user saves a state to <slot>
#   quit         Exit hotkey / pause-menu Exit: save on exit (mode save), then exit
#   sigdie       die from a SIGTERM (exit status 143), nothing saved
#   crash        exit with an error, nothing saved
#   hang         run until killed; SIGTERM saves on exit (mode save, takes 1 s), then exits
cat >"$EMU" <<'STUB_BODY'
#!/bin/sh
printf '%s\n' "$@" >"$STUB/args"
echo $$ >"$STUB/pid"
cat /tmp/psp-pak.pid >"$STUB/pakpid" 2>/dev/null
mode="$(cat "$STUB/mode")"
sleeper=""
save_state() {
    cp "$FIX/thumb1.jpg" "$STATES/${PREFIX}_$1.jpg"
    printf 'state' >"$STATES/${PREFIX}_$1.ppst"
}
on_term() {
    [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
    [ "$mode" = stuck ] && sleep 20 # PPSSPP hangs after SIGTERM (watchdog test)
    if [ "$mode" = save ] || [ "$mode" = savesig ]; then
        sleep 1 # saving takes a moment; the shim must wait for it
        save_state 0
        : >"$STUB/saved_on_term"
    fi
    if [ "$mode" = savesig ]; then
        trap - TERM # then die from the SIGTERM (status 143)
        kill -TERM $$
        sleep 5
    fi
    exit 0
}
trap on_term TERM
sleep 2 # saves must be newer than launch.sh's launch marker (1 s mtime in BusyBox test)
while read -r action a; do
    case "$action" in
    save) save_state "$a" ;;
    quit)
        [ "$mode" = save ] && save_state 0
        exit 0
        ;;
    crash) exit 139 ;;
    sigdie)
        # killed by the SIGTERM like PPSSPP without a handler: status 143
        trap - TERM
        kill -TERM $$
        sleep 5
        ;;
    hang)
        sleep 300 &
        sleeper=$!
        wait "$sleeper"
        ;;
    esac
done <"$STUB/actions"
STUB_BODY
chmod +x "$EMU"

export PLATFORM DEVICE=brick SDCARD_PATH="$SD" USERDATA_PATH="$USERDATA" LOGS_PATH="$LOGS" \
    SHARED_USERDATA_PATH="$SHARED" ROMS_PATH="$SD/Roms" STUB FIX STATES PREFIX
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

# Plays the power button's shutdown script against the running stub:
#   shim  run `poweroff -f` (the real shim, found through launch.sh's PATH) and SIGTERM PPSSPP
#   req   only create the request file (as the shim does), then SIGTERM PPSSPP
# The request file is waited for before the SIGTERM so the test is deterministic; on
# the device PPSSPP's save on exit gives the shim the same head start.
power_button() {
    wait_for "$STUB/pid" || return 1
    case "$1" in
    shim)
        PATH="$PAK/bin:$PATH" poweroff -f &
        wait_for "$REQ"
        ;;
    req) : >"$REQ" ;;
    late)
        # the shutdown script SIGTERMs PPSSPP first; its `poweroff` (the shim,
        # which creates the request file) comes after syncing and its message
        (sleep 4; date +%s >"$REQ") &
        ;;
    esac
    kill -TERM "$(cat "$STUB/pid")"
}

# run_game <mode> <resume slot or ""> <power button: shim|req|""> <actions...>: runs
# launch.sh. A power-off ends with launch.sh waiting for the device to die (poweroff
# would SIGKILL it): wait for the "ok" file, check what the test wants, then SIGKILL it.
run_game() {
    printf '%s' "$1" >"$STUB/mode"
    slot="$2"
    button="$3"
    shift 3
    rm -f "$STUB/args" "$STUB/pid" "$STUB/pakpid" "$STUB/saved_on_term" "$REQ" "$OK" "$MARKER" \
        /tmp/resume_slot.txt "$STUB/real-called" "$STUB/marker_at_poweroff" \
        "$STUB/state_at_poweroff" "$STUB/preview_at_poweroff" /tmp/psp-poweroff-shim.log
    printf '%s\n' "$@" >"$STUB/actions"
    [ -n "$slot" ] && printf '%s' "$slot" >/tmp/resume_slot.txt
    LAUNCH_HUNG=""
    MARKER_AT_OK=""
    sh "$PAK/launch.sh" "$ROMFILE" >"$T/launch.out" 2>&1 &
    LAUNCH_PID=$!
    if [ -n "$button" ]; then
        power_button "$button"
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
            [ "$button" = shim ] && wait_for "$STUB/real-called"
            sleep 1 # let cleanup() unmount before the "power cut"
            kill -KILL "$LAUNCH_PID" 2>/dev/null
        fi
    fi
    wait "$LAUNCH_PID" 2>/dev/null
    LAUNCH_PID=""
    cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
}

LOG="$OUT_DIR/current.log"
use_log() { LOG="$OUT_DIR/$CASE.log"; }
reset_states() { rm -rf "${STATES:?}"/* "$SHARED/.minui/PSP"; }
EXPECT_MARKER="/Roms/PlayStation Portable (PSP)/Game B.iso"

begin "1 power button with save on exit: shim waits for the save, marker and preview before poweroff"
reset_states
run_game save "" shim hang
use_log
check "PPSSPP saved on SIGTERM" present "$STUB/saved_on_term"
check "marker holds the ROM path when ok is given" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "shim reached the real poweroff" present "$STUB/real-called"
check "real poweroff got the args" contains "$STUB/real-called" '^-f$'
check "state and thumbnail on disk when poweroff ran" present "$STUB/state_at_poweroff"
check "marker on disk when poweroff ran" contains "$STUB/marker_at_poweroff" "Game B.iso"
check "preview on disk when poweroff ran" present "$STUB/preview_at_poweroff"
check "preview is the save-on-exit thumbnail" cmp -s "$PREVIEW" "$FIX/thumb1.jpg"
check "preview slot is 0" contains "$PREVIEW_SLOT" '^0$'
check "shim waited for launch.sh's answer" contains /tmp/psp-poweroff-shim.log 'launch.sh is ready after'
check "pid file held launch.sh pid while PPSSPP ran" test -s "$STUB/pakpid"
check "no --state argument" lacks "$STUB/args" '^--state='
check "pause-menu exit passed" contains "$STUB/args" '^--pause-menu-exit$'
check "log says power-off detected" contains "$LOG" 'Power-off detected: .*psp-poweroff-req'
check "log order: marker, then preview" sh -c "grep -v '^+' '$LOG' | grep -E 'Auto-resume armed|Game switcher preview' | head -1 | grep -q 'Auto-resume armed'"
check "log shows the shipped settings" contains "$LOG" 'SaveStateOnExit=True AutoLoadSaveState=2'
check "no autoresume dir created" absent "$STATES/autoresume"
end

begin "2 save on exit off: marker still armed, no new state, older preview untouched"
reset_states
mkdir -p "$SHARED/.minui/PSP"
printf 'old' >"$STATES/${PREFIX}_2.jpg"
printf 'old' >"$STATES/${PREFIX}_2.ppst"
printf 'oldbmp' >"$SHARED/.minui/PSP/Game B.iso.2.bmp"
printf '2' >"$PREVIEW_SLOT"
run_game nosave "" shim hang
use_log
check "marker armed at ok time" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "marker on disk when poweroff ran" contains "$STUB/marker_at_poweroff" "Game B.iso"
check "no save-on-exit state" absent "$EXIT_STATE"
check "older state kept for auto-load" present "$STATES/${PREFIX}_2.ppst"
check "old preview kept" contains "$SHARED/.minui/PSP/Game B.iso.2.bmp" '^oldbmp$'
check "slot file unchanged" contains "$PREVIEW_SLOT" '^2$'
end

begin "3 normal quit (Exit hotkey/menu) with save on exit: preview, no marker"
reset_states
run_game save 8 "" quit
use_log
check "no marker" absent "$MARKER"
check "ok file never created" absent "$OK"
check "state saved on exit" present "$EXIT_STATE"
check "preview from the save-on-exit state" cmp -s "$PREVIEW" "$FIX/thumb1.jpg"
check "resume_slot.txt removed (minarch would pick it up)" absent /tmp/resume_slot.txt
check "no --state argument" lacks "$STUB/args" '^--state='
end

begin "4 auto-resume launch (slot 9): plain launch, PPSSPP auto-loads"
reset_states
printf 'state' >"$EXIT_STATE"
run_game save 9 "" quit
use_log
check "no --state argument" lacks "$STUB/args" '^--state='
check "slot file consumed" absent /tmp/resume_slot.txt
check "no marker after a normal quit" absent "$MARKER"
check "log says auto-resume launch" contains "$LOG" 'Auto-resume launch'
end

begin "5 crash: no marker"
reset_states
run_game save "" "" crash
check "no marker" absent "$MARKER"
check "no ok file" absent "$OK"
end

begin "6 stale request/ok files and marker from an earlier boot are ignored"
: >"$REQ"
: >"$OK"
mkdir -p "$(dirname "$MARKER")"
printf 'stale' >"$MARKER"
printf 'save' >"$STUB/mode"
printf 'quit\n' >"$STUB/actions"
sh "$PAK/launch.sh" "$ROMFILE" >"$T/launch.out" 2>&1
check "treated as a normal quit: no marker" absent "$MARKER"
check "stale request removed" absent "$REQ"
check "stale ok removed" absent "$OK"
check "pid file removed on exit" absent "$PIDFILE"
end

begin "7 give-up path: device does not power off, marker removed, back to the menu"
PSP_AUTORESUME_WAIT=2 NOKILL=1 run_game save "" req hang
use_log
check "launch.sh returned by itself" test -z "$LAUNCH_HUNG"
check "marker removed again" absent "$MARKER"
check "req/ok removed" absent "$REQ"
check "log says device did not power off" contains "$LOG" 'Device did not power off'
end

begin "8 ROM outside the SD card: nothing armed, no 60 s wait, shim released"
mkdir -p "$T/outside"
printf 'o' >"$T/outside/Game O.iso"
ROMFILE="$T/outside/Game O.iso" NOKILL=1 run_game save "" req hang
use_log
check "launch.sh returned by itself" test -z "$LAUNCH_HUNG"
check "no marker" absent "$MARKER"
check "shim released anyway" present "$OK"
check "log says not armed" contains "$LOG" 'Auto-resume not armed'
end

begin "9 PPSSPP hangs after SIGTERM: watchdog arms the marker and releases the shim"
reset_states
PSP_PPSSPP_WAIT=2 run_game stuck "" shim hang
use_log
check "marker armed when ok is given" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "marker on disk when poweroff ran" contains "$STUB/marker_at_poweroff" "Game B.iso"
check "shim reached the real poweroff" present "$STUB/real-called"
check "PPSSPP had not exited yet (no save on term)" absent "$STUB/saved_on_term"
check "log says the watchdog armed it" contains "$LOG" 'PPSSPP still running 2s'
kill -KILL "$(cat "$STUB/pid")" 2>/dev/null
end

begin "10 late request file: PPSSPP dies on SIGTERM before the shim exists, grace poll finds it"
reset_states
PSP_SHUTDOWN_GRACE=4 run_game savesig "" late hang
use_log
check "marker armed when ok is given" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "log says PPSSPP was stopped by a signal" contains "$LOG" 'PPSSPP stopped by a signal'
check "log says it was found after waiting" contains "$LOG" 'found after waiting'
check "log says power-off detected" contains "$LOG" 'Power-off detected: .*psp-poweroff-req'
end

begin "11 signal exit and no sign of a power-off: detection failure is logged, no marker, no hang"
reset_states
PSP_SHUTDOWN_GRACE=2 NOKILL=1 run_game save "" "" sigdie
use_log
check "launch.sh returned by itself" test -z "$LAUNCH_HUNG"
check "no marker" absent "$MARKER"
check "log says the grace poll ran" contains "$LOG" 'looking for a power-off for up to 2s'
check "log says detection failed" contains "$LOG" 'No power-off detected within 2s'
end

begin "12 normal quit: no grace poll, no delay"
reset_states
run_game save "" "" quit
use_log
check "no grace poll" lacks "$LOG" 'looking for a power-off'
check "no failed-detection message" lacks "$LOG" 'No power-off detected'
end

begin "13 launch.sh teardown runs once: mounts released before the wait, no umount errors"
reset_states
PSP_AUTORESUME_WAIT=3 NOKILL=1 run_game save "" shim hang
use_log
check "give-up path was taken" contains "$LOG" 'Device did not power off'
check "SAVEDATA unmounted exactly once" test "$(grep -c '^+ umount .*SAVEDATA' "$LOG")" = 1
check "PPSSPP_STATE unmounted exactly once" test "$(grep -c '^+ umount .*PPSSPP_STATE' "$LOG")" = 1
check "no umount errors" lacks "$LOG" 'umount: '
check "no unmount failure logged" lacks "$LOG" 'Could not unmount'
check "bind mounts gone" sh -c "! grep -q '$PAK' /proc/self/mountinfo"
end

begin "14 aborted power-off: watchdog withdraws marker and request, a later quit is a normal quit"
reset_states
printf 'stuck' >"$STUB/mode"
printf 'hang\n' >"$STUB/actions"
rm -f "$REQ" "$OK" "$MARKER" "$STUB/pid" "$STUB/real-called" /tmp/psp-poweroff-shim.log
PSP_PPSSPP_WAIT=2 PSP_REQ_MAX_AGE=5 PSP_SHUTDOWN_GRACE=1 sh "$PAK/launch.sh" "$ROMFILE" >"$T/launch.out" 2>&1 &
LAUNCH_PID=$!
power_button shim
wait_for "$OK"
check "marker armed by the watchdog" test "$(cat "$MARKER" 2>/dev/null)" = "$EXPECT_MARKER"
i=0
while [ -e "$MARKER" ] && [ "$i" -lt 150 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
check "marker withdrawn" absent "$MARKER"
check "request file withdrawn" absent "$REQ"
check "ok file withdrawn" absent "$OK"
# The user now quits normally (here: PPSSPP dies without a power-off).
kill -KILL "$(cat "$STUB/pid")" 2>/dev/null
i=0
while kill -0 "$LAUNCH_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
if kill -0 "$LAUNCH_PID" 2>/dev/null; then LAUNCH_HUNG=1; else LAUNCH_HUNG=""; fi
kill -KILL "$LAUNCH_PID" 2>/dev/null
wait "$LAUNCH_PID" 2>/dev/null
LAUNCH_PID=""
cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
use_log
check "launch.sh ended by itself (no 60 s re-arm)" test -z "$LAUNCH_HUNG"
check "no marker after the later quit" absent "$MARKER"
check "log says the power-off did not happen" contains "$LOG" 'power-off did not happen'
end

begin "15 stale request file (old timestamp) is ignored on a normal quit"
reset_states
printf 'save' >"$STUB/mode"
printf 'quit\n' >"$STUB/actions"
rm -f "$REQ" "$OK" "$MARKER" "$STUB/pid"
sh "$PAK/launch.sh" "$ROMFILE" >"$T/launch.out" 2>&1 &
LAUNCH_PID=$!
wait_for "$STUB/pid"
echo $(($(date +%s) - 300)) >"$REQ"
i=0
while kill -0 "$LAUNCH_PID" 2>/dev/null && [ "$i" -lt 150 ]; do
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
done
if kill -0 "$LAUNCH_PID" 2>/dev/null; then LAUNCH_HUNG=1; else LAUNCH_HUNG=""; fi
kill -KILL "$LAUNCH_PID" 2>/dev/null
wait "$LAUNCH_PID" 2>/dev/null
LAUNCH_PID=""
cp "$LOGS/PSP.txt" "$OUT_DIR/$CASE.log" 2>/dev/null
use_log
check "launch.sh ended by itself" test -z "$LAUNCH_HUNG"
check "no marker" absent "$MARKER"
check "stale request removed" absent "$REQ"
check "log says stale" contains "$LOG" 'Ignoring a stale power-off request'
end

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

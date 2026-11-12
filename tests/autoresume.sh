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
# Usage: sh tests/autoresume.sh             (env: SRC_PAK, PLATFORM, OUT_DIR, KEEP=1)

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_PAK="${SRC_PAK:-$(cd "$HERE/.." && pwd)}"
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
# Stand-in for the platform's show_message: records what it was asked to show.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/shown"\n' "$STUB" >"$PAK/bin/show_message"
# Stand-in killall: records instead of killing (launch.sh replaces "Powering off").
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/killall"\n' "$STUB" >"$PAK/bin/killall"
# Stand-in for minui-presenter as started by the shutdown script (NOT on PATH, see the
# "shutdown" power button). Without arguments it behaves like the real one (exit 1 before
# touching the display). Otherwise it logs "start <path run> <args> others=<other live
# presenters>", then shows its message "forever" and logs "term <pid>" on SIGTERM.
# Switches (files in $STUB): preflight-fail (the no-argument run exits 127), qs-dies (a
# "Quicksave" message exits at once), ignore-term (only the original, not the copy).
mkdir -p "$T/selfgz" "$T/proc"
cat >"$T/selfgz/minui-presenter" <<'PRES_BODY'
#!/bin/sh
L="$STUB/presenter.log"
if [ $# -eq 0 ]; then
    echo "preflight $0" >>"$L"
    [ -f "$STUB/preflight-fail" ] && exit 127
    exit 1
fi
others=0
for p in $(pgrep minui-presenter); do
    [ "$p" = "$$" ] && continue
    grep -q '^State:.*Z' "/proc/$p/status" 2>/dev/null || others=$((others + 1))
done
echo "start $0 $* others=$others" >>"$L"
case "$*" in *Quicksave*) [ -f "$STUB/qs-dies" ] && exit 1 ;; esac
if [ -f "$STUB/ignore-term" ] && [ "$0" != /tmp/psp-quicksave/minui-presenter ]; then
    trap 'echo "term-ignored $$" >>"$L"' TERM
else
    trap 'echo "term $$" >>"$L"; exit 0' TERM
fi
while :; do sleep 0.2 2>/dev/null || sleep 1; done
PRES_BODY
chmod +x "$T/selfgz/minui-presenter"
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
    shutdown)
        # The real shutdown script: its minui-presenter ("Powering off") is already up when
        # the shim runs. Its binary is not on PATH (it lives in a temp dir that is deleted
        # when the emulator exits); launch.sh finds it through /proc/<pid>/exe, which the
        # test's PSP_PROC_DIR points at the stub script. ZOMBIE_OLD=1 adds a second one that
        # the fake /proc/<pid>/status calls a zombie.
        "$T/selfgz/minui-presenter" --message "Powering off" --timeout -1 &
        PRESENTER_PID=$!
        mkdir -p "$T/proc/$PRESENTER_PID"
        ln -sf "$T/selfgz/minui-presenter" "$T/proc/$PRESENTER_PID/exe"
        wait_for "$STUB/presenter.log"
        if [ -n "$ZOMBIE_OLD" ]; then
            "$T/selfgz/minui-presenter" --message "Zombie" --timeout -1 &
            ZOMBIE_PID=$!
            mkdir -p "$T/proc/$ZOMBIE_PID"
            printf 'State:\tZ (zombie)\n' >"$T/proc/$ZOMBIE_PID/status"
            ln -sf "$T/selfgz/minui-presenter" "$T/proc/$ZOMBIE_PID/exe"
            sleep 1
        fi
        PATH="$PAK/bin:$PATH" poweroff -f &
        wait_for "$REQ"
        ;;
    shutdownlate)
        # like shutdown, but the shim's request comes late (after the sync)
        "$T/selfgz/minui-presenter" --message "Powering off" --timeout -1 &
        PRESENTER_PID=$!
        mkdir -p "$T/proc/$PRESENTER_PID"
        ln -sf "$T/selfgz/minui-presenter" "$T/proc/$PRESENTER_PID/exe"
        wait_for "$STUB/presenter.log"
        (sleep 4; date +%s >"$REQ") &
        ;;
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
        "$STUB/state_at_poweroff" "$STUB/preview_at_poweroff" "$STUB/shown" "$STUB/killall" "$STUB/presenter.log" /tmp/psp-poweroff-shim.log
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
wait_for "$STUB/shown"
check "quicksave message shown after the save" contains "$STUB/shown" '^Quicksave created, powering off 10$'
check "quicksave message replaces the Powering off presenter" contains "$STUB/killall" '^minui-presenter$'
check "log order: marker, message, preview, ok" sh -c "grep -v '^+' '$LOG' | grep -E 'Auto-resume armed|Showing the quicksave message|Game switcher preview|Told the poweroff shim' | cut -c1-14 | tr '\\n' '|' | grep -q 'Auto-resume ar|Showing the qu|Game switcher |Told the power|'"
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
check "no quicksave message (nothing was saved)" absent "$STUB/shown"
check "presenter left alone (nothing was saved)" absent "$STUB/killall"
end

begin "3 normal quit (Exit hotkey/menu) with save on exit: preview, no marker"
reset_states
run_game save 8 "" quit
use_log
check "no marker" absent "$MARKER"
check "ok file never created" absent "$OK"
check "no quicksave message on a normal quit" absent "$STUB/shown"
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

# Helpers for the presenter tests: the log of the stubs as one line, and cleanup.
plog() { tr '\n' '|' <"$STUB/presenter.log" | sed 's/ others=[0-9]*//g'; }
QSBIN=/tmp/psp-quicksave/minui-presenter
presenter_cleanup() {
    # shellcheck disable=SC2046 # a list of pids (the stubs, or none)
    kill -KILL $(pgrep minui-presenter) 2>/dev/null
    wait "$PRESENTER_PID" "$ZOMBIE_PID" 2>/dev/null # reap the stubs (a zombie would show up in pgrep)
    PRESENTER_PID=""
    ZOMBIE_PID=""
    rm -rf /tmp/psp-quicksave "${T:?}/proc"/*
    rm -f "$STUB/preflight-fail" "$STUB/qs-dies" "$STUB/ignore-term"
}

begin "16 power-off found only after the preview budget: preview skipped, quicksave message still shown by the presenter"
reset_states
PSP_PROC_DIR="$T/proc" PSP_PREVIEW_BUDGET=0 PSP_SHUTDOWN_GRACE=6 run_game savesig "" shutdownlate hang
use_log
check "marker armed" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
check "log: preview skipped" contains "$LOG" 'Skipping the Game Switcher preview: '
check "log: quicksave message shown" contains "$LOG" 'Showing the quicksave message'
check "log: it is the presenter branch, not show_message" lacks "$LOG" 'show_message, no usable'
check "show_message not called" absent "$STUB/shown"
presenter_cleanup
end

begin "17 real shutdown order: the Powering off presenter is stopped, then ours (a copy of its binary) is the last one started"
reset_states
PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
use_log
check "presenters: old start, preflight of the copy, old stopped, copy started with the message" test "$(plog)" = "start $T/selfgz/minui-presenter --message Powering off --timeout -1|preflight $QSBIN|term $PRESENTER_PID|start $QSBIN --message Quicksave created, powering off --timeout -1|"
check "no second presenter was alive when ours started" contains "$STUB/presenter.log" "^start $QSBIN --message Quicksave.* others=0\$"
check "our presenter was not stopped again" sh -c "[ \$(grep -c '^term' '$STUB/presenter.log') = 1 ]"
check "log: the copy of the running presenter is used" contains "$LOG" 'using the copy of the running presenter'
check "log: preflight status logged" contains "$LOG" 'preflight of .*: exit status 1'
check "log: the old presenter was seen" contains "$LOG" 'minui-presenter pids: [0-9]'
check "log: the new presenter runs" contains "$LOG" 'Quicksave message: presenter [0-9]* is running (0.3 s after the start)'
check "log: held, then checked again" contains "$LOG" 'held for [0-9]* tenths'
check "hold is at least half a second here (the preview is quick)" contains "$LOG" 'held for \(10\|[5-9]\) tenths'
check "show_message not used when the presenter is there" absent "$STUB/shown"
check "killall not used" absent "$STUB/killall"
check "message shown before the shim was released" sh -c "grep -v '^+' '$LOG' | grep -E 'Showing the quicksave message|Told the poweroff shim' | cut -c1-14 | tr '\\n' '|' | grep -q 'Showing the qu|Told the power|'"
check "shim still reached the real poweroff" present "$STUB/real-called"
check "our copy is still running when poweroff runs" sh -c "pgrep minui-presenter >/dev/null"
presenter_cleanup
end

begin "18 no presenter and no show_message: nothing to show, and it says so"
reset_states
mv "$PAK/bin/show_message" "$T/show_message.off"
run_game save "" shim hang
mv "$T/show_message.off" "$PAK/bin/show_message"
use_log
check "log: not shown" contains "$LOG" 'no usable minui-presenter and no show_message'
check "marker still armed" test "$MARKER_AT_OK" = "$EXPECT_MARKER"
end

begin "19 cp fails: the copy is made with cat"
reset_states
printf '#!/bin/sh\nexit 1\n' >"$PAK/bin/cp"
chmod +x "$PAK/bin/cp"
PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
rm -f "$PAK/bin/cp"
use_log
check "old presenter stopped, copy started" contains "$STUB/presenter.log" "^start $QSBIN --message Quicksave"
check "log: the copy is used" contains "$LOG" 'using the copy of the running presenter'
presenter_cleanup
end

begin "20 the copy fails its preflight: the old presenter is left alone"
reset_states
: >"$STUB/preflight-fail"
PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
use_log
check "log: not usable" contains "$LOG" 'the copy of presenter [0-9]* is not usable'
check "old presenter never stopped" lacks "$STUB/presenter.log" '^term'
check "no second presenter started" test "$(grep -c '^start' "$STUB/presenter.log")" = 1
check "log: preflight status 127" contains "$LOG" 'exit status 127'
presenter_cleanup
end

begin "21 our presenter exits at once: a Powering off presenter is started in its place"
reset_states
: >"$STUB/qs-dies"
PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
use_log
check "presenters: old, stopped, ours died, Powering off restored from the copy" test "$(plog)" = "start $T/selfgz/minui-presenter --message Powering off --timeout -1|preflight $QSBIN|term $PRESENTER_PID|start $QSBIN --message Quicksave created, powering off --timeout -1|start $QSBIN --message Powering off --timeout -1|"
check "log: restoring" contains "$LOG" 'restoring the "Powering off" screen'
check "the restored presenter is running" sh -c "pgrep minui-presenter >/dev/null"
presenter_cleanup
end

begin "22 the old presenter ignores SIGTERM: SIGKILL, and never two presenters at once"
reset_states
: >"$STUB/ignore-term"
PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
use_log
check "log: escalated to SIGKILL" contains "$LOG" 'sending SIGKILL'
check "old presenter saw the SIGTERM" contains "$STUB/presenter.log" '^term-ignored'
check "ours started with no other presenter alive" contains "$STUB/presenter.log" "^start $QSBIN --message Quicksave.* others=0\$"
presenter_cleanup
end

begin "23 a zombie old presenter is ignored, the live one replaced"
reset_states
ZOMBIE_OLD=1 PSP_PROC_DIR="$T/proc" run_game save "" shutdown hang
use_log
check "log: only the live presenter listed" contains "$LOG" 'minui-presenter pids: [0-9]*, pgrep'
check "the zombie-marked one was not sent SIGTERM" sh -c "[ \$(grep -c '^term' '$STUB/presenter.log') = 1 ]"
check "ours started" contains "$STUB/presenter.log" "^start $QSBIN --message Quicksave"
presenter_cleanup
end

begin "24 the 60 s give-up path stops the quicksave presenter and removes its directory"
reset_states
PSP_PROC_DIR="$T/proc" PSP_AUTORESUME_WAIT=3 NOKILL=1 run_game save "" shutdown hang
use_log
check "give-up path was taken" contains "$LOG" 'Device did not power off'
check "our presenter is gone" sh -c "! pgrep minui-presenter >/dev/null"
check "temporary directory removed" absent /tmp/psp-quicksave
presenter_cleanup
end

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]

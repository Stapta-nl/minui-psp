#!/usr/bin/env bats
# bats file_tags=device,reboot,platform:tg5040,platform:tg5050
# shellcheck disable=SC2016 # the scripts in single quotes run on the device
#
# Auto-resume on a real TrimUI device, including REBOOTS. Needs a device; never runs in `make test`.
#
# These tests run on the HOST and drive the device over ssh (a reboot ends the ssh session
# that `make test-device` runs the on-device bats in, so tests that reboot cannot run there).
# tests/run-device.sh runs them after the on-device tests (see tests/run-reboot.sh); they are
# tagged `device` and `reboot`, and the on-device run leaves `reboot` out. They reuse the
# machinery of e2e.bats (evdev button injection, the /tmp/next hand-off, SIGKILL restarts of
# NextUI, backup/restore of recents and resume files); see tests/helpers/reboot-device.bash.
#
# What is tested (each case only starts the game, so every one is independent of the earlier
# ones except for the steps that say so):
#   R1/R2  quitting with the Exit hotkey saves a state and its Game Switcher preview, arms NO
#          auto-resume marker, and NextUI shows its normal menu (also after NextUI restarts)
#   R3-R5  a power-off request: SIGTERM to PPSSPP and the pak's `poweroff` shim, exactly what the
#          power button's shutdown script does. The marker is armed, a state is saved, the device
#          reboots, NextUI relaunches the game and consumes the marker
#   R6     a crash (kill -9 PPSSPP): no marker, no auto-launch
#   R7     a forced reboot without any handshake (power cut analogue): no auto-resume, the
#          states are untouched
#   R8/R9  "Save state on exit" off: a power-off still arms the marker and relaunches the game
#          (PPSSPP loads the newest existing state), no new state is saved
#
# THE TRADE-OFF: a real power-off cannot be undone remotely (nobody presses the power button),
# so in R3 and R8 the shim's FINAL call, `/sbin/poweroff`, is replaced by a test wrapper that
# records what launch.sh had armed and saved at that moment and then reboots. The shim
# supports this through its test override PSP_POWEROFF_REAL, given only in the environment of
# the one call that the test makes; nothing in the system is replaced and production code is
# unchanged. What is NOT covered: the real `poweroff` command itself, and the power button /
# minui-power-control's own shutdown script (the test plays its role). The wrapper lives in
# /tmp (cleared by the reboot) and the preflight proves that the shim honours the override
# before anything is started: without it the test refuses to run.
#
# Requirements: those of e2e.bats (root over ssh, NextUI, a game in Roms/*(PSP), PPSSPP hotkeys
# select+r1 = save state and select+start = exit), plus key-based ssh that works again after a
# reboot (the same address), and nothing else touching the device while it runs. The Screenshot
# Monitor pak is optional (evidence screenshots).
#
# The device is kept awake for the whole run: a detached keep-awake loop on the device (started by run-device.sh
# before the on-device tests and kept, or started in setup_file, and again after every boot) taps a harmless
# button (KEEPAWAKE_KEY, default l1) and checks the screen every second; the waits and long calls tap too.
# A screen that NextUI turned off anyway (its hybrid sleep, seen as keymon.elf stopped; or a backlight node
# bl_power that says powered down; never on a guess) is woken with a short power key tap: an L1 tap does not end
# NextUI's screen-off. A device in DEEP sleep does not answer ssh, so it cannot be woken from here: prevention
# is what the tests rely on. Long calls (preflight, backup, clean start, restore) run as detached jobs on the
# device that the host polls (rb_job): a Wi-Fi drop does not end them. Whether the device suspended is read from
# its suspend counter (suspend-ledger.txt), never guessed from ping.
#
# Backup: recents, game_switcher, auto_resume, the slot file and previews of the test game, and
# ppsspp.ini, and a copy of every file in the save state folder (the tests overwrite a slot of the
# test game), are backed up on the SD card (/.userdata/shared/.psp-test-backup, shared with e2e.bats) and restored at
# the end; a run that is cut short is restored at the start of the next one. New save states
# are deleted.
#
# Hotkeys: read from the device's controls.ini (Save State, Exit App). A hotkey that is not bound there
# is bound by the tests (SET_HOTKEYS=0 turns that off: a preflight failure instead) and controls.ini is
# put back at the end like the other files; SAVE_KEYS/EXIT_KEYS override and are never written.
#
# Env: DEVICE_HOST, DEVICE_SSH_OPTS (set by run-reboot.sh), SDCARD_PATH, PLATFORM, ROM_DIR, ROM,
# SET_HOTKEYS, SAVE_KEYS, EXIT_KEYS, BOOT_WAIT (20), UI_WAIT (6), NOGAME_WAIT (25),
# and the timeouts and intervals listed in tests/helpers/reboot.bash.
#
# Waits are signals where a signal exists: a reboot is watched on the network (port closes, port opens,
# ssh answers with a new boot_id; the time of each phase is logged), a game start by the emulator
# process running the ROM (and, if minui-power-control wrote it, /tmp/emulator_pid naming it).
# "No auto-launch" (R1, R2, R6, R7) means: after a normal quit, a crash or a forced reboot the device
# comes back to NextUI's normal menu and does NOT start the game by itself: no auto-resume marker is
# consumed and no PPSSPP process appears. NextUI's main() runs autoResume() first (before any init): with
# a marker it deletes it, queues the game and exits, without one it goes on to the menu. So the decision
# is made right after nextui.elf starts, and the check is: the same nextui.elf for NOGAME_SETTLE seconds
# (default 6) with no PPSSPP and no marker, and the pak log (PSP.txt, which launch.sh deletes and
# recreates on every start) not rewritten since before the event (a positive "launch.sh did not run").
# What has no signal keeps a quiet time chosen from the maintainer's observations (a game starts within
# about 5 s, state load included), not measured here: BOOT_SETTLE 6, UI_SETTLE 6, NOGAME_SETTLE 6.
# BOOT_WAIT (20), UI_WAIT (6), NOGAME_WAIT (25) and the REBOOT_* / RESUME_TIMEOUT values are only the
# upper bounds after which a wait gives up; set a *_SETTLE to wait quietly for less or more.

load '../helpers/common'
load '../helpers/reboot'

# --- steps shared between cases (each case is its own subshell, so use files) ----------------
step_done() { : >"$STEPS/$1"; }
need_step() { [ -f "$STEPS/$1" ] || fail "an earlier case did not finish (needs: $1)"; }

# fetch_evidence <label>: what the wrapper recorded at the final power-off call, kept in the logs.
fetch_evidence() {
    dev_kit 60 'for f in "$BAK"/evidence-* "$BAK/wrapper.log" "$BAK/trigger.log"; do [ -f "$f" ] || continue; echo "=== ${f##*/}"; cat "$f"; echo; done' >"$OUT/$1-evidence.txt" 2>&1 || true
}
# fetch_log <label>: the pak log as it is now.
fetch_log() {
    dev_kit 60 'cat "$LOGS/PSP.txt"' >"$OUT/$1-PSP.log" 2>&1 || true
}
# fetch_failure_evidence <label>: after a failed test, what the next report needs to tell what happened:
# the pak log (<label>-PSP.log) and <label>-failure.txt with the boot reports await_reboot took during the
# test (first contact after the boot, SD card mounted: the uptime, the boot id, whether the auto-resume
# marker existed, the pak log, the start of launch.sh / NextUI / PPSSPP after the boot) and one taken now.
# Best effort, short limits: the device may be down (the kit is installed again first).
fetch_failure_evidence() {
    local f="$OUT/$1-failure.txt"
    {
        echo "test: ${BATS_TEST_DESCRIPTION:-?}"
        if [ -n "${RB_BOOT_REPORT:-}" ]; then
            echo "--- boot reports taken by await_reboot in this test"
            printf '%s' "$RB_BOOT_REPORT"
        else
            echo "--- no reboot was awaited in this test (no boot reports)"
        fi
        echo "=== now (after the failure)"
        dev_install_kit 15 >/dev/null 2>&1 || true # a reboot cleared /tmp: without the kit every call below exits 97
        dev_kit 20 rb_boot_report 2>&1 || echo "(no complete answer from the device)"
    } >"$f" 2>&1
    fetch_log "$1"
}

# The non-trace lines of the pak log (launch.sh runs with xtrace on some builds).
pak_log() { dev_kit 60 'grep -v "^+" "$LOGS/PSP.txt"'; }

# start_game <SaveStateOnExit value>: a fresh game start, as NextUI does it, with PPSSPP's
# settings set for the case (auto-load newest state always on).
start_game() {
    rb_timed "start_game: stop, ini, mark, launch" dev_kit 240 "rb_awake 'rb_settle; rb_ini_set SaveStateOnExit $1; rb_ini_set AutoLoadSaveState 2; rb_mark; rb_launch_game'"
    await 90 "PPSSPP to start the test game" probe rb_rom_running
    settle_boot
}

# The game runs (a case that follows an auto-resume keeps it), else start it.
ensure_game() {
    # A timeout or an ssh failure is "unknown", never "not running": starting a game over a running one would be wrong.
    local rc=0
    dev_definite "${RB_PROBE_TIMEOUT:-10}" rb_rom_running || rc=$?
    case "$rc" in
    0) ;;
    1) start_game "$1" ;;
    *) fail "could not tell whether the game is running (the device does not answer)" ;;
    esac
}

assert_dev() { # assert_dev <script>: the script succeeds on the device
    run dev_kit 60 "$1"
    assert_success
}
refute_dev() { # refute_dev <script>: the script fails on the device (not an ssh failure)
    run dev_kit 60 "$1"
    if [ "$status" -eq 0 ] || [ "$status" -ge 124 ]; then
        echo "expected the device script to fail normally (status 1..123), got $status: $1" >&2
        return 1
    fi
}

# Arrays are not exported from setup_file into the tests, so the ssh setup runs for every test.
setup() {
    rb_ssh_setup
    rb_test_begin
}

# One line per test in the TAP output: the total and where the time went (every wait and every ssh call of 2 s or more).
# A test that failed (bats sets BATS_TEST_COMPLETED only for one that passed) leaves its evidence (R7 and every other case).
teardown() {
    if [ -z "${BATS_TEST_COMPLETED:-}" ] && [ -z "${BATS_TEST_SKIPPED:-}" ] && [ -n "${OUT:-}" ]; then
        fetch_failure_evidence "${BATS_TEST_DESCRIPTION%% *}"
    fi
    rb_test_end
}

setup_file() {
    require_tools ssh timeout sed awk tr mktemp cat grep touch
    rb_ssh_setup || fail "DEVICE_HOST is not set (these tests are run by make test-device)"
    SD="${SDCARD_PATH:-/mnt/SDCARD}"
    PLATFORM="$(psp_platform)"
    PAK_NAME="$(psp_pak_name)"
    BOOT_WAIT="${BOOT_WAIT:-20}"
    UI_WAIT="${UI_WAIT:-6}"
    NOGAME_WAIT="${NOGAME_WAIT:-25}"
    OUT="$OUT_DIR/reboot"
    STEPS="$OUT/steps"
    rm -rf "${OUT:?}"
    mkdir -p "$STEPS"
    export SD PLATFORM PAK_NAME BOOT_WAIT UI_WAIT NOGAME_WAIT OUT STEPS

    local rc=0
    # every call before the jobs below is idempotent: one that the network drops (ssh 255) is retried
    rb_device_retry dev_run 30 true || rc=$?
    if [ "$rc" != 0 ]; then
        local note
        note="$(rb_unreachable_note "$rc")"
        fail "the device is unreachable (ssh status $rc)${note:+: $note}"
    fi
    rb_device_retry dev_install_kit || fail "could not install the test kit on the device"
    # Wake / keep-awake tap FIRST, then the keep-awake loop for the whole run (a detached loop on the device:
    # run-device.sh started it before the on-device tests; it is kept, or started here): NextUI turns the screen
    # off after screentimeout and suspends the device suspendTimeout later, which drops ssh. The loop also
    # checks the screen every second and wakes it with a power tap when NextUI's screen-off state is seen.
    dev_kit 15 rb_tick >/dev/null 2>&1 || true
    info "$(rb_device_retry dev_kit 15 rb_keepawake_start 2>&1)"
    # shellcheck disable=SC2034 # read by rb_keepawake_maybe (the waits of setup_file)
    RB_LAST_TICK=$(($(rb_now_ms) / 1000))
    # The suspend counter at the start: a dropped connection is later told apart (asleep or Wi-Fi) by it.
    : >"$OUT/suspend-ledger.txt"
    rb_suspend_record "start of the reboot suite"
    RB_IDLE_INFO="$(rb_device_retry dev_kit 30 rb_idle_settings 2>/dev/null)" || RB_IDLE_INFO=""
    export RB_IDLE_INFO
    [ -z "$RB_IDLE_INFO" ] || info "NextUI idle settings: $RB_IDLE_INFO (a keep-awake loop runs on the device for the whole run)"

    local found
    found="$(rb_device_retry dev_kit 60 rb_discover)" || fail "could not look at the device"
    ROM="$(printf '%s\n' "$found" | sed -n 's/^ROM=//p')"
    [ -n "$ROM" ] || fail "no game found in Roms/*(PSP) on the device (set ROM_DIR or ROM)"
    export ROM
    info "game: $ROM"
    info "$(rb_device_retry dev_kit 60 rb_config_info 2>&1)"

    # The long calls run as detached jobs on the device, polled with short ssh calls (rb_job): a Wi-Fi drop
    # costs a few polls, the job goes on.
    local problems
    if ! problems="$(rb_job 120 preflight rb_preflight)"; then
        fail "preflight failed: $problems"
    fi

    # From here on the device holds a backup (made first thing inside rb_backup): teardown_file
    # restores it, or the next run does.
    RB_STARTED=1
    export RB_STARTED
    # The backup copies every save state (about 9 MB each): the time limit follows the size.
    local kb
    kb="$(rb_device_retry dev_kit 60 rb_state_kb 2>/dev/null)"
    case "$kb" in "" | *[!0-9]*) kb=0 ;; esac
    rb_job "${RB_BACKUP_TIMEOUT:-$((300 + kb / 1000))}" backup rb_backup >"$OUT/hotkeys.txt" 2>&1 || fail "could not back up the device's files (and bind the hotkeys): $(cat "$OUT/hotkeys.txt")"
    [ -s "$OUT/hotkeys.txt" ] && info "$(cat "$OUT/hotkeys.txt")"
    # The id of the backup THIS run made: only that one is restored normally at the end.
    PSP_RUN_ID="$(rb_device_retry dev_kit 60 'cat "$BAK/active"' 2>/dev/null)"
    [ -n "$PSP_RUN_ID" ] || fail "could not read the id of this run's backup"
    export PSP_RUN_ID
    local out
    rc=0
    out="$(rb_job 300 "clean start" rb_settle 2>&1)" || rc=$?
    [ "$rc" = 0 ] || fail "could not bring the device to a clean start (status $rc): $out"
}

teardown_file() {
    [ -n "${RB_STARTED:-}" ] || return 0
    rb_ssh_setup || return 0
    # A case that was cut short in the middle of a reboot: wait for the device first.
    RB_TICK=0 await "${REBOOT_UP_TIMEOUT:-120}" "the device to be reachable for the restore" dev_run "${RB_PROBE_TIMEOUT:-10}" true || {
        echo "# the device is not reachable ($(rb_unreachable_note 255)): its backup stays on the SD card and is restored by the next run" >&3
        return 0
    }
    rb_device_retry dev_install_kit
    # A backup is expected (and waited for) only when this run made one.
    local expect="" restored
    [ -n "${PSP_RUN_ID:-}" ] && expect="RB_EXPECT_BACKUP=1; export RB_EXPECT_BACKUP;"
    if restored="$(rb_job 400 restore "$expect rb_restore" 2>&1)"; then
        [ -n "$restored" ] && echo "# $restored" >&3
        echo "# restored; results in $OUT" >&3
    else
        echo "# the restore failed: run again, the next run restores from the backup on the SD card ($restored)" >&3
    fi
    # Did the device sleep during the run? (tells whether the keep-awake works) Then the loop is stopped and its
    # log (the screen state at every tick since the last boot) kept.
    rb_suspend_record "end of the reboot suite"
    echo "# $(rb_suspend_total)" >&3
    dev_kit 30 'cat "$RB_TMP/psp-keepawake.log"' >"$OUT/keepawake-device.log" 2>/dev/null || true
    dev_kit 30 rb_keepawake_stop >/dev/null 2>&1 || true
}

# --- R1/R2: quit paths --------------------------------------------------------------------
@test "R1 quit with the Exit hotkey: a state and its preview are saved, no auto-resume marker" {
    start_game True
    dev_kit 30 rb_quit_game
    await 40 "PPSSPP to exit after the Exit hotkey (hotkeys: see the log)" probe rb_no_game
    await 90 "NextUI to be back" probe rb_nextui_up
    await 60 "a new save state (.ppst) from the exit" probe rb_has_new_state
    await 40 "the Game Switcher preview of the newest state" probe rb_has_new_preview
    assert_dev '[ "$(rb_slot_file_slot)" = "$(rb_newest_new_slot)" ]'
    refute_dev rb_marker_exists
    settle_ui_short "$(rb_launch_ref)" # NextUI is back (launch.sh is over): it must not launch anything again
    refute_dev rb_marker_exists
    assert_dev rb_nextui_up
    fetch_log R1
    step_done r1-quit
}

@test "R2 NextUI is up after a quit and after a restart and launches no game (no auto-launch)" {
    need_step r1-quit
    local ref
    ref="$(rb_launch_ref)"
    dev_kit 30 kill_ui # SIGKILL: NextUI starts again, and would run autoResume() if a marker existed
    await 90 "NextUI to be back" probe rb_nextui_up
    settle_nogame "$ref"
    assert_dev rb_nextui_up
    assert_dev rb_no_game
    refute_dev rb_marker_exists
}

# --- R3-R5: the power-off path, ending in a reboot ---------------------------------------
@test "R3 power-off request: marker armed and state saved, then the device reboots" {
    start_game True
    dev_kit 30 rb_install_wrapper
    local old
    old="$(rb_boot_id)"
    [ -n "$old" ] || fail "could not read the device's boot id"
    rb_trigger rb_trigger_poweroff
    await_reboot "$old"
    # The kit is installed again; the evidence was written to the SD card at the final power-off call.
    fetch_evidence R3
    assert_dev '[ -f "$BAK/evidence-called" ]'
    run dev_kit 30 'cat "$BAK/evidence-marker"'
    assert_success
    assert_output "${ROM#"$SD"}"
    run dev_kit 30 'grep -v "^+" "$BAK/evidence-PSP.txt"'
    assert_success
    assert_output --partial "Power-off detected"
    assert_output --partial "Auto-resume armed for"
    assert_dev '[ -s "$BAK/evidence-new-states" ]'
    step_done r3-rebooted
}

@test "R4 after the reboot NextUI relaunches the game (auto-resume)" {
    need_step r3-rebooted
    await "${RESUME_TIMEOUT:-180}" "PPSSPP to run the test game after the boot" probe rb_rom_running
    settle_resumed
    assert_dev rb_rom_running
    run pak_log
    assert_success
    assert_output --partial "Auto-resume launch"
    dev_kit 60 'rb_evidence_shot R4-resumed' >"$OUT/R4-resumed.png" 2>/dev/null || true
    fetch_log R4
    step_done r4-resumed
}

@test "R5 the auto-resume marker was consumed by NextUI" {
    need_step r3-rebooted
    await 60 "the marker to be consumed" probe '! rb_marker_exists'
    refute_dev rb_marker_exists
}

# --- R6/R7: no auto-resume without a power-off -----------------------------------------
@test "R6 crash (kill -9 PPSSPP): no marker, back at the menu, no auto-launch" {
    ensure_game True
    dev_kit 30 'killall -9 "PPSSPPSDL_$PLATFORM"'
    await 40 "PPSSPP to be gone" probe rb_no_game
    await 90 "NextUI to be back" probe rb_nextui_up
    settle_nogame "$(rb_launch_ref)"
    assert_dev rb_nextui_up
    assert_dev rb_no_game
    refute_dev rb_marker_exists
    run pak_log
    assert_success
    assert_output --partial "No power-off detected"
    local ref
    ref="$(rb_launch_ref)"
    dev_kit 30 kill_ui
    await 90 "NextUI to be back after its restart" probe rb_nextui_up
    settle_nogame "$ref"
    assert_dev rb_no_game
    fetch_log R6
}

@test "R7 forced reboot without the handshake (power cut analogue): no auto-resume, states intact" {
    start_game True
    dev_kit 30 rb_save_state
    await 30 "a state saved with the Save State hotkey (hotkeys: see the log)" probe rb_has_new_state
    dev_kit 30 rb_save_snapshot
    local old ref
    old="$(rb_boot_id)"
    [ -n "$old" ] || fail "could not read the device's boot id"
    ref="$(rb_launch_ref)" # the pak log of this game: a launch after the boot would rewrite it
    # On a failure, teardown writes R7-failure.txt (boot reports: was the marker there at the first contact,
    # when did launch.sh start after the boot) and R7-PSP.log: a real auto-launch and sleep/wake differ there.
    rb_trigger rb_hard_reboot
    await_reboot "$old"
    await "${RESUME_TIMEOUT:-180}" "NextUI to be up after the boot" probe rb_nextui_up
    settle_nogame "$ref"
    assert_dev rb_nextui_up
    assert_dev rb_no_game
    refute_dev rb_marker_exists
    assert_dev rb_states_intact
}

# --- R8/R9: "Save state on exit" off ------------------------------------------------------
@test "R8 setting off: power-off still arms the marker, saves no new state, then the device reboots" {
    # A state to resume: made with the setting on, by the hotkey and then the exit.
    start_game True
    dev_kit 30 rb_save_state
    await 30 "a state saved with the hotkey" probe rb_has_new_state
    dev_kit 30 rb_quit_game
    await 40 "PPSSPP to exit" probe rb_no_game
    await 90 "NextUI to be back" probe rb_nextui_up
    start_game False # (its rb_settle waits for NextUI: no settle of its own here)
    dev_kit 30 rb_save_snapshot # all states that exist now, none of them may change
    dev_kit 30 rb_install_wrapper
    local old
    old="$(rb_boot_id)"
    [ -n "$old" ] || fail "could not read the device's boot id"
    rb_trigger rb_trigger_poweroff
    await_reboot "$old"
    fetch_evidence R8
    assert_dev '[ -f "$BAK/evidence-called" ]'
    run dev_kit 30 'cat "$BAK/evidence-marker"'
    assert_success
    assert_output "${ROM#"$SD"}"
    run dev_kit 30 'grep -v "^+" "$BAK/evidence-PSP.txt"'
    assert_success
    assert_output --partial "SaveStateOnExit=False"
    assert_output --partial "Auto-resume armed for"
    assert_dev '[ ! -s "$BAK/evidence-new-states" ]'
    assert_dev rb_states_intact
    step_done r8-rebooted
}

@test "R9 setting off: after the reboot the game is relaunched and the marker consumed" {
    need_step r8-rebooted
    await "${RESUME_TIMEOUT:-180}" "PPSSPP to run the test game after the boot" probe rb_rom_running
    settle_resumed
    assert_dev rb_rom_running
    refute_dev rb_marker_exists
    assert_dev rb_states_intact
    fetch_log R9
}

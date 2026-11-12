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
# The device is kept awake while the tests wait: every KEEPAWAKE_INTERVAL seconds a harmless
# button tap is injected (KEEPAWAKE_KEY, default l1); a device whose backlight node bl_power says
# powered down (never on a guess) is woken with a short power key tap instead. A device in DEEP sleep does not answer ssh, so it cannot be woken
# from here: prevention is what the tests rely on.
#
# Backup: recents, game_switcher, auto_resume, the slot file and previews of the test game, and
# ppsspp.ini, and a copy of every file in the save state folder (the tests overwrite a slot of the
# test game), are backed up on the SD card (/.userdata/shared/.psp-reboot-backup) and restored at
# the end; a run that is cut short is restored at the start of the next one. New save states
# are deleted.
#
# Env: DEVICE_HOST, DEVICE_SSH_OPTS (set by run-reboot.sh), SDCARD_PATH, PLATFORM, ROM_DIR, ROM,
# EXIT_KEYS, BOOT_WAIT (20), UI_WAIT (6), NOGAME_WAIT (25: how long "no auto-launch" is watched),
# and the timeouts and intervals listed in tests/helpers/reboot.bash.

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
# The non-trace lines of the pak log (launch.sh runs with xtrace on some builds).
pak_log() { dev_kit 60 'grep -v "^+" "$LOGS/PSP.txt"'; }

# start_game <SaveStateOnExit value>: a fresh game start, as NextUI does it, with PPSSPP's
# settings set for the case (auto-load newest state always on).
start_game() {
    dev_kit 240 "rb_settle; rb_ini_set SaveStateOnExit $1; rb_ini_set AutoLoadSaveState 2; rb_mark; rb_launch_game"
    await 90 "PPSSPP to start the test game" dev_ok 20 rb_rom_running
    pause "$BOOT_WAIT"
}

# The game runs (a case that follows an auto-resume keeps it), else start it.
ensure_game() {
    if ! dev_ok 20 rb_rom_running; then start_game "$1"; fi
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

    dev_run 30 true || fail "the device is unreachable"
    dev_install_kit || fail "could not install the test kit on the device"

    local found
    found="$(dev_kit 60 rb_discover)" || fail "could not look at the device"
    ROM="$(printf '%s\n' "$found" | sed -n 's/^ROM=//p')"
    [ -n "$ROM" ] || fail "no game found in Roms/*(PSP) on the device (set ROM_DIR or ROM)"
    export ROM
    info "game: $ROM"
    info "$(dev_kit 60 rb_config_info 2>&1)"

    local problems
    if ! problems="$(dev_kit 60 rb_preflight)"; then
        fail "preflight failed: $problems"
    fi

    # From here on the device holds a backup (made first thing inside rb_backup): teardown_file
    # restores it, or the next run does.
    RB_STARTED=1
    export RB_STARTED
    dev_kit 300 rb_backup || fail "could not back up the device's files"
    dev_kit 300 rb_settle || fail "could not bring the device to a clean start"
}

teardown_file() {
    [ -n "${RB_STARTED:-}" ] || return 0
    rb_ssh_setup || return 0
    # A case that was cut short in the middle of a reboot: wait for the device first.
    RB_TICK=0 await "${REBOOT_UP_TIMEOUT:-300}" "the device to be reachable for the restore" dev_run 20 true || {
        echo "# the device is not reachable: its backup stays on the SD card and is restored by the next run" >&3
        return 0
    }
    dev_install_kit
    if dev_kit 400 rb_restore; then
        echo "# restored; results in $OUT" >&3
    else
        echo "# the restore failed: run again, the next run restores from the backup on the SD card" >&3
    fi
}

# --- R1/R2: quit paths --------------------------------------------------------------------
@test "R1 quit with the Exit hotkey: a state and its preview are saved, no auto-resume marker" {
    start_game True
    dev_kit 30 rb_quit_game
    await 40 "PPSSPP to exit after the Exit hotkey (hotkeys: see the log)" dev_ok 20 rb_no_game
    await 90 "NextUI to be back" dev_ok 20 rb_nextui_up
    await 60 "a new save state (.ppst) from the exit" dev_ok 20 rb_has_new_state
    await 40 "the Game Switcher preview of the newest state" dev_ok 20 rb_has_new_preview
    assert_dev '[ "$(rb_slot_file_slot)" = "$(rb_newest_new_slot)" ]'
    refute_dev rb_marker_exists
    pause "$UI_WAIT"
    refute_dev rb_marker_exists
    assert_dev rb_nextui_up
    fetch_log R1
    step_done r1-quit
}

@test "R2 NextUI is up after a quit and after a restart and launches no game (no auto-launch)" {
    need_step r1-quit
    dev_kit 30 kill_ui # SIGKILL: NextUI starts again, and would run autoResume() if a marker existed
    await 90 "NextUI to be back" dev_ok 20 rb_nextui_up
    pause "$NOGAME_WAIT"
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
    dev_kit 30 rb_trigger_poweroff
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
    await "${RESUME_TIMEOUT:-180}" "PPSSPP to run the test game after the boot" dev_ok 20 rb_rom_running
    pause "$UI_WAIT"
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
    await 60 "the marker to be consumed" dev_ok 20 '! rb_marker_exists'
    refute_dev rb_marker_exists
}

# --- R6/R7: no auto-resume without a power-off -----------------------------------------
@test "R6 crash (kill -9 PPSSPP): no marker, back at the menu, no auto-launch" {
    ensure_game True
    dev_kit 30 'killall -9 "PPSSPPSDL_$PLATFORM"'
    await 40 "PPSSPP to be gone" dev_ok 20 rb_no_game
    await 90 "NextUI to be back" dev_ok 20 rb_nextui_up
    pause "$NOGAME_WAIT"
    assert_dev rb_nextui_up
    assert_dev rb_no_game
    refute_dev rb_marker_exists
    run pak_log
    assert_success
    assert_output --partial "No power-off detected"
    dev_kit 30 kill_ui
    await 90 "NextUI to be back after its restart" dev_ok 20 rb_nextui_up
    pause "$NOGAME_WAIT"
    assert_dev rb_no_game
    fetch_log R6
}

@test "R7 forced reboot without the handshake (power cut analogue): no auto-resume, states intact" {
    start_game True
    dev_kit 30 rb_save_state
    await 30 "a state saved with the Save State hotkey (hotkeys: see the log)" dev_ok 20 rb_has_new_state
    dev_kit 30 rb_save_snapshot
    local old
    old="$(rb_boot_id)"
    [ -n "$old" ] || fail "could not read the device's boot id"
    dev_kit 30 rb_hard_reboot
    await_reboot "$old"
    await "${RESUME_TIMEOUT:-180}" "NextUI to be up after the boot" dev_ok 20 rb_nextui_up
    pause "$NOGAME_WAIT"
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
    await 30 "a state saved with the hotkey" dev_ok 20 rb_has_new_state
    dev_kit 30 rb_quit_game
    await 40 "PPSSPP to exit" dev_ok 20 rb_no_game
    await 90 "NextUI to be back" dev_ok 20 rb_nextui_up
    pause "$UI_WAIT"
    start_game False
    dev_kit 30 rb_save_snapshot # all states that exist now, none of them may change
    dev_kit 30 rb_install_wrapper
    local old
    old="$(rb_boot_id)"
    [ -n "$old" ] || fail "could not read the device's boot id"
    dev_kit 30 rb_trigger_poweroff
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
    await "${RESUME_TIMEOUT:-180}" "PPSSPP to run the test game after the boot" dev_ok 20 rb_rom_running
    pause "$UI_WAIT"
    assert_dev rb_rom_running
    refute_dev rb_marker_exists
    assert_dev rb_states_intact
    fetch_log R9
}

#!/usr/bin/env bats
# bats file_tags=host
# shellcheck disable=SC2016,SC2030,SC2031,SC2317 # scripts that run on the fake device; bats runs every test in a subshell
#
# Off-device tests of the machinery behind tests/bats/reboot.bats (tests/helpers/reboot.bash on the
# host, tests/helpers/reboot-device.bash on the device): the waits and their timeouts, the
# keep-awake steps, how a reboot is detected, the backup and restore of the device's files, the
# power-off wrapper with the real shim (bin/poweroff), the preflight, run-reboot.sh and the tags.
# The device is a fake: an `ssh` that runs the command locally, against a throw-away SD tree.
# What this cannot show is how a real device reacts (see README "Testing").
#
# Env: SRC_PAK  the pak whose bin/poweroff is used (default: the checkout)

load '../helpers/common'
load '../helpers/reboot'

HELPERS="$TESTS_DIR/helpers"

setup() {
    require_tools sh bash timeout sed awk find touch cp mkdir cat grep tr mktemp sleep
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/tmp"
    # A fake ssh: skips the options, takes the host, and runs the command locally. It can pretend
    # that the device is down for a window of calls and that it booted again at some call.
    cat >"$T/bin/ssh" <<'SSH'
#!/bin/sh
n=$(($(cat "$FAKE_SSH_STATE" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_SSH_STATE"
while [ $# -gt 0 ]; do
    case "$1" in
    -o | -p | -i | -F | -l) shift 2 ;;
    -*) shift ;;
    *) break ;;
    esac
done
host="$1"
shift
echo "$n $*" >>"$FAKE_SSH_LOG"
if [ -n "${FAKE_SSH_DOWN_FROM:-}" ] && [ "$n" -ge "$FAKE_SSH_DOWN_FROM" ] && [ "$n" -le "$FAKE_SSH_DOWN_TO" ]; then
    echo "ssh: connect to host $host port 22: Connection refused" >&2
    exit 255
fi
if [ -n "${FAKE_SSH_NEWBOOT_AT:-}" ] && [ "$n" -ge "$FAKE_SSH_NEWBOOT_AT" ]; then
    echo newboot >"$BOOT_ID_FILE"
fi
exec sh -c "$*"
SSH
    chmod +x "$T/bin/ssh"
    export PATH="$T/bin:$PATH"
    export FAKE_SSH_STATE="$T/ssh.count" FAKE_SSH_LOG="$T/ssh.log"
    : >"$FAKE_SSH_LOG"
    export DEVICE_HOST="root@brick.example" DEVICE_SSH_OPTS="-p 2222 -i /nonexistent/key"
    export BOOT_ID_FILE="$T/boot_id"
    echo oldboot >"$BOOT_ID_FILE"
    export RB_KIT_PATH="$T/kit.sh"
    export POLL_INTERVAL=0.2 KEEPAWAKE_INTERVAL=0
    rb_ssh_setup
    make_device
}

# A device tree like the real one, in $T/sd.
make_device() {
    local pak
    export SD="$T/sd" PLATFORM=tg5040 PAK_NAME=PSP RB_TMP="$T/tmp" RB_OUT="$T/out"
    pak="$SD/Emus/$PLATFORM/$PAK_NAME.pak"
    mkdir -p "$pak/bin" "$pak/PPSSPP/.config/ppsspp/PSP/SYSTEM" "$SD/Roms/Sony PSP (PSP)" \
        "$SD/.userdata/shared/.minui/PSP" "$SD/.userdata/shared/PSP-ppsspp" "$SD/.userdata/$PLATFORM/logs"
    cp "$(psp_src_pak)/bin/poweroff" "$pak/bin/poweroff"
    printf '#!/bin/sh\n' >"$pak/launch.sh"
    printf '#!/bin/sh\n' >"$pak/bin/jpg2bmp"
    chmod +x "$pak/bin/jpg2bmp"
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" "$pak/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    : >"$SD/Roms/Sony PSP (PSP)/game.iso"
    : >"$T/tmp/nextui_exec"
    # The code that runs on the device, sourced here as the kit is there.
    # shellcheck disable=SC1091
    . "$HELPERS/e2e.bash"
    # shellcheck disable=SC1091
    . "$HELPERS/reboot-device.bash"
    rb_init
    PAD=/dev/null
    # Never touch real processes of this machine (a developer's PPSSPP, a parallel test run).
    rb_game_up() { false; }
    rb_kill_game() { :; }
    kill_ui() { :; }
}

# --- host side: ssh, kit, waits -------------------------------------------------------------
@test "dev_run: returns the script's status and scrubs the device address from ssh errors" {
    run dev_run 10 'exit 7'
    assert_failure 7
    export FAKE_SSH_DOWN_FROM=100 FAKE_SSH_DOWN_TO=100
    echo 99 >"$FAKE_SSH_STATE"
    run dev_run 10 true
    assert_failure 255
    assert_output --partial "<device>"
    refute_output --partial "brick.example"
    refute_output --partial "root@"
}

@test "dev_run: a script that hangs is stopped by the timeout (status 124)" {
    run dev_run 1 'exec sleep 20'
    assert_failure 124
}

@test "dev_run: quoting survives (quotes, spaces, dollar signs)" {
    run dev_run 10 "x='a b'\"c\"; echo \"\$x \$(echo \"it's\")\""
    assert_success
    assert_output "a bc it's"
}

@test "dev_kit: installs the kit, exports the settings and runs the script after rb_init" {
    run dev_install_kit
    assert_success
    assert_file_exist "$RB_KIT_PATH"
    run dev_kit 20 'echo "$PLATFORM|$ROM_FILE|$tag|${PAK##*/}"'
    assert_success
    assert_output "tg5040|game.iso|PSP|PSP.pak"
}

@test "dev_kit: settings that are not set are not forwarded; ones that are set arrive quoted" {
    run rb_env_prelude
    assert_output --partial "export PLATFORM='tg5040';"
    refute_output --partial "KEEPAWAKE_KEY"
    KEEPAWAKE_KEY="it's" run rb_env_prelude
    assert_output --partial "export KEEPAWAKE_KEY='it'\\''s';"
}

@test "await: succeeds as soon as the command does" {
    echo 0 >"$T/n"
    # shellcheck disable=SC2317 # called through await
    flaky() { local n; n=$(($(cat "$T/n") + 1)); echo "$n" >"$T/n"; [ "$n" -ge 3 ]; }
    run await 10 "flaky" flaky
    assert_success
    [ "$(cat "$T/n")" = 3 ]
}

@test "await: times out, says what it waited for, and does not wait much longer than asked" {
    local start=$SECONDS
    run await 1 "the moon" false
    assert_failure
    assert_output --partial "timed out after 1s waiting for: the moon"
    [ $((SECONDS - start)) -le 4 ]
}

@test "keep-awake: every interval a tap is sent during await and pause; off with interval 0 or RB_TICK=0" {
    export KEEPAWAKE_INTERVAL=1
    run await 3 "nothing" false
    assert_failure
    local n
    n="$(grep -c 'rb_tick' "$FAKE_SSH_LOG")"
    [ "$n" -ge 2 ]
    : >"$FAKE_SSH_LOG"
    RB_LAST_TICK="" pause 3
    n="$(grep -c 'rb_tick' "$FAKE_SSH_LOG")"
    [ "$n" -ge 2 ]
    : >"$FAKE_SSH_LOG"
    RB_TICK=0 pause 2
    [ "$(grep -c 'rb_tick' "$FAKE_SSH_LOG")" = 0 ]
    KEEPAWAKE_INTERVAL=0 pause 2
    [ "$(grep -c 'rb_tick' "$FAKE_SSH_LOG")" = 0 ]
}

@test "keep-awake: a failing step (device down) never fails the wait" {
    export KEEPAWAKE_INTERVAL=1 FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=999
    run pause 2
    assert_success
}

@test "await_reboot: also waits for the SD card (the backup flag) after the boot" {
    export FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=2 FAKE_SSH_NEWBOOT_AT=3 REBOOT_DOWN_TIMEOUT=5 REBOOT_UP_TIMEOUT=10
    rm -f "$BAK/active"
    ( sleep 2; mkdir -p "$BAK"; : >"$BAK/active" ) 3>&- &
    run await_reboot oldboot
    assert_success
    assert_file_exist "$BAK/active"
}

@test "await_reboot: down, then up with a new boot id, then the kit is installed again" {
    export FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=3 FAKE_SSH_NEWBOOT_AT=4
    export REBOOT_DOWN_TIMEOUT=5 REBOOT_UP_TIMEOUT=10
    mkdir -p "$BAK"
    : >"$BAK/active"
    run await_reboot oldboot
    assert_success
    assert_file_exist "$RB_KIT_PATH"
    [ "$(cat "$BOOT_ID_FILE")" = newboot ]
}

@test "await_reboot: a device that never goes down is an error" {
    export REBOOT_DOWN_TIMEOUT=1 REBOOT_UP_TIMEOUT=2
    run await_reboot oldboot
    assert_failure
    assert_output --partial "the device to go down"
}

@test "await_reboot: a connection that drops and returns with the SAME boot id is not a reboot" {
    export FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=2 REBOOT_DOWN_TIMEOUT=3 REBOOT_UP_TIMEOUT=2
    run await_reboot oldboot
    assert_failure
    assert_output --partial "the device to come back"
}

@test "dev_run works inside a bats test when only setup_file ran rb_ssh_setup (arrays are not exported)" {
    {
        printf '%s\n' '#!/usr/bin/env bats'
        printf "load '%s/helpers/common'\n" "$TESTS_DIR"
        printf "load '%s/helpers/reboot'\n" "$TESTS_DIR"
        printf '%s\n' 'setup_file() { rb_ssh_setup; }'
        printf '%s\n' '@test "dev_run in a test" {' "    run dev_run 10 'echo hello'" '    assert_success' '    assert_output hello' '}'
    } >"$T/probe.bats"
    run env -i PATH="$PATH" HOME="${HOME:-/tmp}" DEVICE_HOST="$DEVICE_HOST" DEVICE_SSH_OPTS="$DEVICE_SSH_OPTS" \
        FAKE_SSH_STATE="$FAKE_SSH_STATE" FAKE_SSH_LOG="$FAKE_SSH_LOG" bash "$TESTS_DIR/lib/bats-core/bin/bats" "$T/probe.bats"
    assert_success
}

@test "reboot.bats sets the ssh command up for every test (setup), not only in setup_file" {
    run awk '/^setup\(\) \{/{f=1} f&&/rb_ssh_setup/{ok=1} /^\}/{f=0} END{exit !ok}' "$TESTS_DIR/bats/reboot.bats"
    assert_success
}

# --- device side: ini ----------------------------------------------------------------------
@test "rb_ini_set: replaces a key, adds a missing one to [General] only, keeps the BOM and other sections" {
    printf '\xef\xbb\xbf[General]\nSaveStateOnExit = True\nAutoLoadSaveState = 2\n[Graphics]\nSaveStateOnExit = keep\n' >"$INI"
    rb_ini_set SaveStateOnExit False
    run rb_ini_get SaveStateOnExit
    assert_output "False"
    grep -q 'SaveStateOnExit = keep' "$INI"
    [ "$(head -c 3 "$INI" | od -An -tx1 | tr -d ' ')" = efbbbf ]
    printf '[General]\nA = 1\n[Graphics]\nB = 2\n' >"$INI"
    rb_ini_set StateSlot 3
    run cat "$INI"
    assert_output $'[General]\nA = 1\nStateSlot = 3\n[Graphics]\nB = 2'
    # a missing key in the last section [General]
    printf '[Graphics]\nB = 2\n[General]\nA = 1\n' >"$INI"
    rb_ini_set StateSlot 3
    run cat "$INI"
    assert_output $'[Graphics]\nB = 2\n[General]\nA = 1\nStateSlot = 3'
}

@test "rb_ini_set: keeps CRLF line endings" {
    printf '[General]\r\nSaveStateOnExit = True\r\nAutoLoadSaveState = 2\r\n' >"$INI"
    rb_ini_set SaveStateOnExit False
    run rb_ini_get SaveStateOnExit
    assert_output "False"
    [ "$(grep -c $'\r$' "$INI")" = 3 ]
}

# --- device side: backup and restore -----------------------------------------------------------
seed_files() {
    mkdir -p "$MINUI"
    printf '/Roms/other.iso\n' >"$RECENT"
    printf '0' >"$SLOT_FILE"
    printf 'preview0' >"$MINUI/$ROM_FILE.0.bmp"
    : >"$STATE_DIR/OLD_1.00_0.ppst"
    cp "$INI" "$T/ini.copy"
}
mess_up() {
    printf '/Roms/changed.iso\n' >"$RECENT"
    printf 'marker' >"$AUTORESUME"
    rm -f "$SLOT_FILE"
    printf 'new' >"$MINUI/$ROM_FILE.2.bmp"
    printf 'new' >"$MINUI/$ROM_FILE.0.bmp"
    : >"$STATE_DIR/NEW_1.00_2.ppst"
    : >"$STATE_DIR/NEW_1.00_2.jpg"
    rb_ini_set SaveStateOnExit False
}

@test "rb_backup + rb_restore: put every file back, remove what the test made" {
    seed_files
    rb_backup
    assert_file_exist "$BAK/active"
    mess_up
    rb_restore
    assert_file_not_exist "$BAK/active"
    run cat "$RECENT"
    assert_output "/Roms/other.iso"
    run cat "$SLOT_FILE"
    assert_output "0"
    run cat "$MINUI/$ROM_FILE.0.bmp"
    assert_output "preview0"
    assert_file_not_exist "$MINUI/$ROM_FILE.2.bmp"
    assert_file_not_exist "$AUTORESUME"
    assert_file_not_exist "$STATE_DIR/NEW_1.00_2.ppst"
    assert_file_not_exist "$STATE_DIR/NEW_1.00_2.jpg"
    assert_file_exist "$STATE_DIR/OLD_1.00_0.ppst"
    run cmp "$INI" "$T/ini.copy"
    assert_success
}

@test "rb_backup: the backup of an aborted run is restored first, and the original is not lost" {
    seed_files
    rb_backup
    mess_up
    # the run was cut short: no rb_restore; the next run starts with rb_backup
    run rb_backup
    assert_success
    assert_output --partial "aborted run"
    run cmp "$INI" "$T/ini.copy"
    assert_success
    run cat "$RECENT"
    assert_output "/Roms/other.iso"
    assert_file_not_exist "$AUTORESUME"
    assert_file_not_exist "$STATE_DIR/NEW_1.00_2.ppst"
    # and the fresh backup holds the restored state, so a second restore changes nothing
    mess_up
    rb_restore
    run cmp "$INI" "$T/ini.copy"
    assert_success
}

@test "rb_restore: does nothing without a backup (no 'active' file)" {
    printf 'x' >"$RECENT"
    run rb_restore
    assert_success
    run cat "$RECENT"
    assert_output x
}

@test "rb_restore: removes the test wrapper" {
    seed_files
    rb_backup
    RB_REBOOT_CMD=/bin/true rb_install_wrapper
    assert_file_exist "$WRAPPER"
    rb_restore
    assert_file_not_exist "$WRAPPER"
}

# --- device side: states ----------------------------------------------------------------------
@test "new states: only .ppst newer than the marker, no undo copies; slot and preview from the newest" {
    mkdir -p "$BAK"
    : >"$BAK/marker"
    touch -d '2020-01-01 00:00:00' "$BAK/marker"
    : >"$STATE_DIR/G_1.00_1.ppst"
    touch -d '2019-01-01 00:00:00' "$STATE_DIR/G_1.00_1.ppst"
    : >"$STATE_DIR/G_1.00_3.ppst"
    : >"$STATE_DIR/G_1.00_3.jpg"
    : >"$STATE_DIR/G_1.00_undo.ppst"
    : >"$STATE_DIR/G_1.00_3.undo.ppst"
    run rb_new_states
    assert_output "$STATE_DIR/G_1.00_3.ppst"
    run rb_newest_new_slot
    assert_output "3"
    run rb_has_new_preview
    assert_failure
    printf 'bmp' >"$MINUI/$ROM_FILE.3.bmp"
    run rb_has_new_preview
    assert_success
    printf '3' >"$SLOT_FILE"
    run rb_slot_file_slot
    assert_output 3
}

@test "new states: without a marker nothing is new" {
    : >"$STATE_DIR/G_1.00_3.ppst"
    rm -f "$BAK/marker"
    run rb_new_states
    assert_output ""
    run rb_has_new_state
    assert_failure
}

@test "state snapshot: intact while unchanged, not when a state changed or went away" {
    mkdir -p "$BAK"
    printf 'aaa' >"$STATE_DIR/G_1.00_0.ppst"
    printf 'bbbb' >"$STATE_DIR/G_1.00_1.ppst"
    rb_save_snapshot
    run rb_states_intact
    assert_success
    : >"$STATE_DIR/G_1.00_2.ppst" # an extra state does not matter
    run rb_states_intact
    assert_success
    printf 'bbbbbbbb' >"$STATE_DIR/G_1.00_1.ppst"
    run rb_states_intact
    assert_failure
    assert_output --partial "state changed or gone"
    printf 'cccc' >"$STATE_DIR/G_1.00_1.ppst" # same size, other content
    run rb_states_intact
    assert_failure
    printf 'bbbb' >"$STATE_DIR/G_1.00_1.ppst"
    run rb_states_intact
    assert_success
    printf 'thumb' >"$STATE_DIR/G_1.00_1.jpg"
    rb_save_snapshot
    printf 'thumX' >"$STATE_DIR/G_1.00_1.jpg" # the thumbnail counts too
    run rb_states_intact
    assert_failure
    rm -f "$BAK/evidence-states-before"
    run rb_states_intact
    assert_failure
}

@test "rb_wait_states_stable: waits for a state that is still being written" {
    mkdir -p "$BAK"
    printf 'a' >"$STATE_DIR/G_1.00_0.ppst"
    ( sleep 0.5; printf 'aaaa' >"$STATE_DIR/G_1.00_0.ppst" ) 3>&- &
    rb_save_snapshot
    run cat "$BAK/evidence-states-before"
    assert_output --partial "G_1.00_0.ppst 4 "
}

@test "rb_sum: gives a checksum of the content, whatever tool the device has" {
    printf 'abc' >"$T/f1"
    printf 'abd' >"$T/f2"
    [ "$(rb_sum "$T/f1")" != "$(rb_sum "$T/f2")" ]
    [ "$(rb_sum "$T/f1")" = "$(rb_sum "$T/f1")" ]
}

@test "rb_backup + rb_restore: existing save states are backed up and put back" {
    seed_files
    printf 'mine' >"$STATE_DIR/MY_1.00_0.ppst"
    printf 'thumb' >"$STATE_DIR/MY_1.00_0.jpg"
    rb_backup
    printf 'overwritten by the test' >"$STATE_DIR/MY_1.00_0.ppst"
    rm -f "$STATE_DIR/MY_1.00_0.jpg"
    : >"$STATE_DIR/NEW_1.00_1.ppst"
    rb_restore
    run cat "$STATE_DIR/MY_1.00_0.ppst"
    assert_output mine
    run cat "$STATE_DIR/MY_1.00_0.jpg"
    assert_output thumb
    assert_file_not_exist "$STATE_DIR/NEW_1.00_1.ppst"
    assert_file_not_exist "$BAK/states"
}

@test "rb_backup: the states of an aborted run are put back too" {
    seed_files
    printf 'mine' >"$STATE_DIR/MY_1.00_0.ppst"
    rb_backup
    printf 'overwritten' >"$STATE_DIR/MY_1.00_0.ppst"
    run rb_backup
    assert_success
    run cat "$STATE_DIR/MY_1.00_0.ppst"
    assert_output mine
}

# --- device side: the power-off wrapper with the real shim ---------------------------------------
@test "wrapper: the shim's final poweroff becomes a reboot, and the evidence is recorded first" {
    seed_files
    rb_backup
    printf '#!/bin/sh\necho "reboot called $*" >"%s/rebooted"\n' "$T" >"$T/fake-reboot"
    chmod +x "$T/fake-reboot"
    RB_REBOOT_CMD="$T/fake-reboot" rb_install_wrapper
    # state of a game that was armed by launch.sh
    touch "$BAK/marker"
    sleep 2
    : >"$STATE_DIR/NEW_1.00_5.ppst"
    printf '/Roms/Sony PSP (PSP)/game.iso' >"$AUTORESUME"
    printf 'Auto-resume armed for x\n' >"$LOGS/PSP.txt"
    run env PSP_POWEROFF_TMP="$RB_TMP" PSP_POWEROFF_REAL="$WRAPPER" PSP_POWEROFF_TIMEOUT=2 sh "$PAK/bin/poweroff"
    assert_success
    assert_file_exist "$T/rebooted"
    run cat "$BAK/evidence-marker"
    assert_output "/Roms/Sony PSP (PSP)/game.iso"
    run cat "$BAK/evidence-PSP.txt"
    assert_output "Auto-resume armed for x"
    run cat "$BAK/evidence-new-states"
    assert_output "$STATE_DIR/NEW_1.00_5.ppst"
    assert_file_exist "$BAK/evidence-called"
    assert_grep "$BAK/wrapper.log" "replaced by reboot"
}

@test "wrapper: never calls poweroff (the generated script contains no poweroff command)" {
    RB_REBOOT_CMD=/bin/true rb_install_wrapper
    run grep -v -e '^#' -e '^echo ' "$WRAPPER"
    refute_output --partial "poweroff"
    assert_output --partial "exec /bin/true"
    [ "$(tail -n 1 "$WRAPPER")" = "exec /bin/true" ]
}

@test "rb_reboot_cmd: never poweroff; falls back in order" {
    unset RB_REBOOT_CMD
    run rb_reboot_cmd
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    case "$output" in *poweroff*) false ;; esac
}

@test "rb_trigger_poweroff: SIGTERM to the emulator, then the shim, which calls the wrapper" {
    seed_files
    rb_backup
    printf '#!/bin/sh\necho x >"%s/rebooted"\n' "$T" >"$T/fake-reboot"
    chmod +x "$T/fake-reboot"
    RB_REBOOT_CMD="$T/fake-reboot" rb_install_wrapper
    sleep 60 3>&- &
    victim=$!
    rb_ppsspp_pid() { echo "$victim"; }
    run rb_trigger_poweroff
    assert_success
    local i=0
    while [ ! -f "$T/rebooted" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    assert_file_exist "$T/rebooted"
    ! kill -0 "$victim" 2>/dev/null || { kill "$victim"; false; }
}

@test "rb_trigger_poweroff: refuses without a running game or without the wrapper" {
    rb_ppsspp_pid() { :; }
    run rb_trigger_poweroff
    assert_failure
    assert_output --partial "not running"
    rb_ppsspp_pid() { echo 1; }
    rm -f "$WRAPPER"
    run rb_trigger_poweroff
    assert_failure
    assert_output --partial "wrapper is not installed"
}

@test "rb_hard_reboot: syncs and runs the forced reboot command detached, with no shim or signal" {
    RB_HARD_REBOOT_CMD="touch $T/hard" run rb_hard_reboot
    assert_success
    local i=0
    while [ ! -f "$T/hard" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    assert_file_exist "$T/hard"
    assert_file_not_exist "$RB_TMP/psp-poweroff-req"
}

# --- device side: process check, sleep ----------------------------------------------------------
@test "rb_rom_running: matches the emulator's argv, not a command line that merely mentions it" {
    (exec -a /pak/PPSSPPSDL_tg5040 bash -c 'sleep 30; :' "$ROM" 3>&-) &
    local emu=$!
    (exec -a bash bash -c 'sleep 30; :' "$ROM" "PPSSPPSDL_tg5040 $ROM" 3>&-) &
    local other=$!
    sleep 0.5
    run rb_rom_running
    assert_success
    kill "$emu"
    wait "$emu" 2>/dev/null || true
    sleep 0.3
    run rb_rom_running
    assert_failure # only the look-alike is left
    kill "$other"
    wait "$other" 2>/dev/null || true
}

@test "rb_rom_running: another game does not count" {
    (exec -a /pak/PPSSPPSDL_tg5040 bash -c 'sleep 30; :' "/Roms/other.iso" 3>&-) &
    local emu=$!
    sleep 0.5
    run rb_rom_running
    assert_failure
    kill "$emu"
    wait "$emu" 2>/dev/null || true
}

@test "rb_asleep: the probe decides when given; rb_tick taps the pad when awake and does not when asleep" {
    SLEEP_PROBE=true run rb_asleep
    assert_success
    SLEEP_PROBE=false run rb_asleep
    assert_failure
    PAD="$T/pad"
    : >"$PAD"
    SLEEP_PROBE=false KEEPAWAKE_KEY=y CHORD_HOLD=0.1 rb_tick
    [ -s "$PAD" ] # (the pad here is a plain file: it holds the last event written)
    : >"$PAD"
    SLEEP_PROBE=true POWER_DEV_NAME='nonexistent-device' run rb_tick
    assert_failure # no power key device: it says so, and does not touch the pad
    assert_output --partial "no power key device"
    [ ! -s "$PAD" ]
}

@test "rb_asleep: only bl_power != 0 counts; brightness 0 or no node never does" {
    export RB_BACKLIGHT_DIR="$T/bl"
    run rb_asleep
    assert_failure # no node at all
    mkdir -p "$T/bl/panel"
    echo 0 >"$T/bl/panel/brightness"
    run rb_asleep
    assert_failure # brightness 0 is not evidence
    echo 0 >"$T/bl/panel/bl_power"
    run rb_asleep
    assert_failure
    echo 4 >"$T/bl/panel/bl_power"
    run rb_asleep
    assert_success
}

@test "rb_tick: with no backlight evidence it taps the pad and never the power key" {
    export RB_BACKLIGHT_DIR="$T/none"
    PAD="$T/pad"
    : >"$PAD"
    POWER_DEV_NAME='.*' CHORD_HOLD=0.1 rb_tick
    [ -s "$PAD" ]
}

# --- the preflight -----------------------------------------------------------------------------
@test "rb_preflight: a good tree passes (as root)" {
    [ "$(id -u)" = 0 ] || skip "needs root (the preflight checks it)"
    command -v pgrep >/dev/null && command -v killall >/dev/null || skip "pgrep/killall missing"
    RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_success
    assert_output ""
}

@test "rb_preflight: refuses a shim that ignores PSP_POWEROFF_REAL, and never runs it (it would power off)" {
    printf '#!/bin/sh\ntouch "%s/shim-ran"\nexit 0\n' "$T" >"$PAK/bin/poweroff"
    RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_failure
    assert_output --partial "PSP_POWEROFF_REAL"
    assert_file_not_exist "$T/shim-ran"
}

@test "rb_preflight: a shim that only mentions the override in a comment is refused without running it" {
    printf '#!/bin/sh\n# ${PSP_POWEROFF_REAL:-x} ${PSP_POWEROFF_TMP:-y} exec "$REAL_POWEROFF"\ntouch "%s/shim-ran"\n' "$T" >"$PAK/bin/poweroff"
    RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_failure
    assert_output --partial "PSP_POWEROFF_REAL"
    assert_file_not_exist "$T/shim-ran"
}

@test "rb_preflight: a shim that reads the override but never calls it fails the probe (nothing real is reached)" {
    cat >"$PAK/bin/poweroff" <<'SHIM'
#!/bin/sh
TMP_DIR="${PSP_POWEROFF_TMP:-/tmp}"
REAL_POWEROFF="${PSP_POWEROFF_REAL:-/sbin/poweroff}"
exit 0
exec "$REAL_POWEROFF" "$@"
SHIM
    RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_failure
    assert_output --partial "did not call PSP_POWEROFF_REAL"
}

@test "rb_preflight: the real shim passes the static check" {
    run rb_shim_honours_override "$PAK/bin/poweroff"
    assert_success
}

@test "rb_preflight: names every problem (missing pak, game, ini, ...)" {
    rm -rf "$SD/Emus" "$SD/Roms"
    ROM="" ROM_DIR="" RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_failure
    assert_output --partial "not installed"
    assert_output --partial "no Roms/*(PSP) folder"
}

# --- run-reboot.sh and the tags ---------------------------------------------------------------
@test "run-reboot.sh: SKIP_REBOOT_TESTS leaves the tests out and succeeds" {
    SKIP_REBOOT_TESTS=1 run bash "$TESTS_DIR/run-reboot.sh" tg5040 "$T/stage"
    assert_success
    assert_output --partial "SKIP"
}

@test "run-reboot.sh: usage errors and a missing device are errors" {
    run bash "$TESTS_DIR/run-reboot.sh"
    assert_failure 2
    run bash "$TESTS_DIR/run-reboot.sh" 'Bad Name' "$T/stage"
    assert_failure 2
    unset DEVICE_HOST
    run bash "$TESTS_DIR/run-reboot.sh" tg5040 "$T/stage"
    assert_failure 2
    assert_output --partial "DEVICE_HOST"
}

count_tests() { # count_tests <filter...>: how many tests bats selects (in a clean environment)
    local args=() f
    for f in "$@"; do args+=(--filter-tags "$f"); done
    env -i PATH="$PATH" HOME="${HOME:-/tmp}" bash "$TESTS_DIR/lib/bats-core/bin/bats" --count "${args[@]}" "$TESTS_DIR/bats/reboot.bats"
}

@test "tags: the reboot tests are device tests, not host tests, and are left out of the on-device run" {
    run count_tests host
    assert_output 0
    run count_tests 'device,!reboot,platform:tg5040' 'device,!reboot,!platform:tg5040,!platform:tg5050'
    assert_output 0
    run count_tests 'reboot,platform:tg5040' 'reboot,!platform:tg5040,!platform:tg5050'
    [ "$output" -ge 9 ]
    run count_tests 'reboot,platform:tg5050'
    [ "$output" -ge 9 ]
}

@test "tags: run-device.sh and run-reboot.sh use the filters the tags above assume" {
    assert_grep "$TESTS_DIR/run-device.sh" 'filter_generic="device,!reboot"'
    assert_grep "$TESTS_DIR/run-device.sh" 'filter_platform="device,!reboot,platform:'
    assert_grep "$TESTS_DIR/run-reboot.sh" 'filter_platform="reboot,platform:'
}

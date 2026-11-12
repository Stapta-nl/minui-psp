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
case " $* " in *" -G "*) printf 'hostname brick.example\nport 2222\nproxyjump none\n'; exit 0 ;; esac
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
    export RB_TIMINGS_FILE="$T/timings.txt"
    export RB_PORT_PROBE=fake_port FAKE_PORT_STATE="$T/port.count"
    : >"$FAKE_PORT_STATE"
    rb_ssh_setup
    make_device
}

# The fake network: the port probe call n is closed from FAKE_PORT_DOWN_FROM to FAKE_PORT_DOWN_TO
# (calls are counted), open otherwise.
fake_port() {
    local n
    n=$(($(cat "$FAKE_PORT_STATE" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_PORT_STATE"
    [ -n "${FAKE_PORT_DOWN_FROM:-}" ] && [ "$n" -ge "$FAKE_PORT_DOWN_FROM" ] && [ "$n" -le "${FAKE_PORT_DOWN_TO:-0}" ] && return 1
    return 0
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
    printf '[ControlMapping]\nSelect = 10-196\nStart = 10-197\nR = 10-192\nSave State = 10-196:10-192\nExit App = 10-196:10-197\n' >"$pak/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    : >"$SD/Roms/Sony PSP (PSP)/game.iso"
    : >"$T/tmp/nextui_exec"
    # The code that runs on the device, sourced here as the kit is there.
    # shellcheck disable=SC1091
    . "$HELPERS/e2e.bash"
    # shellcheck disable=SC1091
    . "$HELPERS/devconfig.bash"
    # shellcheck disable=SC1091
    . "$HELPERS/reboot-device.bash"
    rb_init
    PAD=/dev/null
    # Never touch real processes of this machine (a developer's PPSSPP, a parallel test run).
    rb_game_up() { false; }
    rb_kill_game() { :; }
    kill_ui() { :; }
    e2e_stop_game() { :; } # the real one is tested in devconfig.bats; this machine has no game
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

@test "keep-awake: every interval a tap is sent during await; off with interval 0 or RB_TICK=0" {
    export KEEPAWAKE_INTERVAL=1
    run await 3 "nothing" false
    assert_failure
    local n
    n="$(grep -c 'rb_tick' "$FAKE_SSH_LOG")"
    [ "$n" -ge 2 ]
    : >"$FAKE_SSH_LOG"
    RB_TICK=0 run await 2 "nothing" false
    [ "$(grep -c 'rb_tick' "$FAKE_SSH_LOG")" = 0 ]
    KEEPAWAKE_INTERVAL=0 run await 2 "nothing" false
    [ "$(grep -c 'rb_tick' "$FAKE_SSH_LOG")" = 0 ]
}

@test "keep-awake: a failing step (device down) never fails the wait" {
    export KEEPAWAKE_INTERVAL=1 FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=999
    local n=0
    # shellcheck disable=SC2317 # called through await
    third() { n=$((n + 1)); [ "$n" -ge 6 ]; }
    run await 5 "the 6th poll" third
    assert_success
}

@test "await polls every second by default (POLL_INTERVAL) and returns as soon as the condition holds" {
    unset POLL_INTERVAL
    local start=$SECONDS n=0
    # shellcheck disable=SC2317 # called through await
    third() { n=$((n + 1)); [ "$n" -ge 3 ]; }
    await 60 "the third poll" third
    [ "$n" = 3 ]
    # three polls at 1 s: two sleeps; a generous upper bound, it only shows that the default is not 3 s or more per poll
    [ $((SECONDS - start)) -lt 9 ]
}

# --- the reboot: down, then up, each detected and timed ----------------------------------------
@test "await_reboot: port closes, port opens but ssh does not answer yet, then a NEW boot id: timings are logged" {
    # port probes 1..: open at 1 is not needed (down is seen at the first closed probe); closed 2..4;
    # ssh calls: the port is open from probe 5 but ssh refuses calls 1-2, then answers with a new id.
    export FAKE_PORT_DOWN_FROM=2 FAKE_PORT_DOWN_TO=4 FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=2 FAKE_SSH_NEWBOOT_AT=3
    export REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=20
    mkdir -p "$BAK"
    : >"$BAK/active"
    run await_reboot oldboot
    assert_success
    assert_output --partial "reboot: triggered, watching"
    assert_output --partial "reboot: down (ssh port closed) after"
    assert_output --partial "then ssh with a new boot_id"
    assert_output --partial "reboot timing: down after"
    assert_output --partial "SD card mounted at"
    assert_file_exist "$RB_KIT_PATH"
    [ "$(cat "$BOOT_ID_FILE")" = newboot ]
    run cat "$T/timings.txt"
    assert_output --partial "reboot timing: down after"
    refute_output --partial "brick.example"
}

@test "await_reboot: a port that closes at once is detected at the first probe (no 5-10 s granularity)" {
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=2 FAKE_SSH_NEWBOOT_AT=1 REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=20
    mkdir -p "$BAK"
    : >"$BAK/active"
    run await_reboot oldboot
    assert_success
    # (no wall-clock assertion: the port probe and the ssh fake are counted, not timed)
    [ "$(cat "$FAKE_PORT_STATE")" -ge 1 ]
    assert_output --partial "down (ssh port closed) after"
}

@test "await_reboot: also waits for the SD card (the backup flag) after the boot" {
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=2 FAKE_SSH_NEWBOOT_AT=1 REBOOT_DOWN_TIMEOUT=5 REBOOT_UP_TIMEOUT=10
    rm -f "$BAK/active"
    ( sleep 2; mkdir -p "$BAK"; : >"$BAK/active" ) 3>&- &
    run await_reboot oldboot
    assert_success
    assert_file_exist "$BAK/active"
}

@test "await_reboot: a device that never goes down (port stays open, same boot id) is an error naming the phase" {
    export REBOOT_DOWN_TIMEOUT=1 REBOOT_UP_TIMEOUT=2
    run await_reboot oldboot
    assert_failure
    assert_output --partial "the device to go down"
    assert_output --partial "was not seen going down"
}

@test "await_reboot: a reboot the port probe never saw is still found by the boot id that changed" {
    export FAKE_SSH_NEWBOOT_AT=1 REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=10
    mkdir -p "$BAK"
    : >"$BAK/active"
    run await_reboot oldboot
    assert_success
}

@test "await_reboot: the port goes down and comes back with the SAME boot id: not a reboot" {
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=3 REBOOT_DOWN_TIMEOUT=3 REBOOT_UP_TIMEOUT=2
    run await_reboot oldboot
    assert_failure
    assert_output --partial "the device to come back"
    assert_output --partial "ssh port open: yes; new boot_id: no"
}

@test "await_reboot: the port never opens again: an error after the backup timeout" {
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=100000 REBOOT_DOWN_TIMEOUT=3 REBOOT_UP_TIMEOUT=1
    run await_reboot oldboot
    assert_failure
    assert_output --partial "ssh port open: no"
}

@test "await_reboot: a phase that used more than half of its backup time is flagged SLOW" {
    run rb_phase_note "down" 8 10
    assert_output --partial "SLOW"
    run rb_phase_note "down" 3 10
    refute_output --partial "SLOW"
}

@test "rb_net_setup: the ssh port of the device (ssh -G, then -p in the options), the jump host case, no address in the description" {
    unset RB_PORT_PROBE
    rb_net_setup
    [ "$RB_NET_HOST" = brick.example ] && [ "$RB_NET_PORT" = 2222 ]
    [ "$RB_NET_VIA" = tcp ]
    [[ "$RB_NET_DESC" != *brick.example* ]]
    # without ssh -G: the target and -p are read from the settings
    printf '#!/bin/sh\nexit 1\n' >"$T/bin/ssh"
    rb_net_setup
    [ "$RB_NET_HOST" = brick.example ] && [ "$RB_NET_PORT" = 2222 ]
    DEVICE_SSH_OPTS="-J jump.example" rb_net_setup
    [ "$RB_NET_VIA" = ssh ]
}

@test "rb_port_open: a real TCP connect (bash /dev/tcp) sees an open port and a closed one" {
    unset RB_PORT_PROBE
    bash -c 'exec 3<>/dev/tcp/127.0.0.1/9' 2>&1 | grep -qi 'no such file' && skip "this bash has no /dev/tcp"
    require_tools python3
    local port
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    RB_NET_VIA=tcp RB_NET_HOST=127.0.0.1 RB_NET_PORT="$port"
    run rb_port_open
    assert_failure
    python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(5); time.sleep(8)' "$port" 3>&- &
    local i=0
    while [ "$i" -lt 30 ] && ! rb_port_open; do sleep 0.2; i=$((i + 1)); done
    rb_port_open
    kill %1 2>/dev/null
    true
}

# --- settle signals instead of fixed sleeps --------------------------------------------------------
fake_settle_tools() {
    mkdir -p "$T/fs"
    cat >"$T/fs/pgrep" <<'FAKE'
#!/bin/sh
case "$1" in
nextui.elf) [ -f "$FS/nextui.pid" ] && { cat "$FS/nextui.pid"; exit 0; }; exit 1 ;;
PPSSPPSDL) [ -f "$FS/game.pid" ] && { cat "$FS/game.pid"; exit 0; }; exit 1 ;;
esac
exit 1
FAKE
    chmod +x "$T/fs/pgrep"
    export FS="$T/fs" PATH="$T/fs:$PATH"
    # shellcheck disable=SC1091
    . "$HELPERS/e2e.bash"
    # shellcheck disable=SC2317
    rb_rom_running() { [ -f "$FS/game.pid" ]; }
}

@test "wait_ui_settled: returns after N quiet polls, early (not after the old fixed wait)" {
    fake_settle_tools
    echo 100 >"$FS/nextui.pid"
    hook() { echo x >>"$T/hook.log"; }
    E2E_POLL_HOOK=hook run wait_ui_settled 2 60
    assert_success
    # early: 3 polls (2 quiet ones), not the 60 of the limit
    [ "$(wc -l <"$T/hook.log")" -le 5 ]
}

@test "wait_ui_settled: a NextUI that restarts (new pid) or exits to launch a game is not settled; the limit is the backup" {
    fake_settle_tools
    echo 100 >"$FS/nextui.pid"
    ( for p in 101 102 103 104 105 106 107 108; do sleep 0.6; echo "$p" >"$FS/nextui.pid"; done ) &
    run wait_ui_settled 3 4
    assert_failure
    assert_output --partial "did not settle within 4s"
    wait
    echo 200 >"$FS/nextui.pid"
    echo 300 >"$FS/game.pid"
    run wait_ui_settled 2 3
    assert_failure
    assert_output --partial "a game is running"
    rm -f "$FS/nextui.pid" "$FS/game.pid"
    run wait_ui_settled 1 2
    assert_failure
    assert_output --partial "pid: none"
}

@test "wait_game_settled: the same game process for N polls; a game that dies while starting ends the wait at once" {
    fake_settle_tools
    echo 300 >"$FS/game.pid"
    run wait_game_settled 2 30
    assert_success
    hook() { echo x >>"$T/hook.log"; [ "$(wc -l <"$T/hook.log")" -lt 3 ] || rm -f "$FS/game.pid"; }
    E2E_POLL_HOOK=hook run wait_game_settled 100 300
    assert_failure
    assert_output --partial "exited or was restarted"
    [ "$(wc -l <"$T/hook.log")" -le 6 ] # ended at once, not after 100 polls
    rm -f "$FS/game.pid"
    run wait_game_settled 1 2
    assert_failure
    assert_output --partial "not running steadily within 2s"
}

@test "the settle loops call E2E_POLL_HOOK (the keep-awake) on the device" {
    fake_settle_tools
    echo 100 >"$FS/nextui.pid"
    hook() { echo x >>"$T/hook.log"; }
    E2E_POLL_HOOK=hook run wait_ui_settled 2 30
    [ "$(wc -l <"$T/hook.log")" -ge 3 ]
}

@test "e2e_settle_count: the default (6 s), cut to the upper bound; an explicit override wins either way" {
    run e2e_settle_count "" 6 20
    assert_output 6
    run e2e_settle_count "" 6 4 # a bound lower than the default cuts it
    assert_output 4
    run e2e_settle_count 2 6 20 # an explicit, lower SETTLE
    assert_output 2
    run e2e_settle_count 30 6 20 # an explicit, higher one (raise it for a slow device)
    assert_output 30
    run e2e_settle_count x 6 20
    assert_output 6
    run e2e_settle_count "" 6 junk
    assert_output 0
}

@test "the settle defaults: 6 s quiet for the game start, NextUI and the absence check; the *_WAIT values are the bounds" {
    unset BOOT_SETTLE UI_SETTLE NOGAME_SETTLE BOOT_WAIT UI_WAIT NOGAME_WAIT
    # shellcheck disable=SC2317 # replaces the wait itself: only its arguments are recorded
    wait_game_settled() { echo "game $*" >>"$T/calls"; }
    # shellcheck disable=SC2317
    wait_ui_settled() { echo "ui $*" >>"$T/calls"; }
    game_settle
    ui_settle
    nogame_settle
    run cat "$T/calls"
    assert_output "game 6 26
ui 6 12
ui 6 31"
    : >"$T/calls"
    BOOT_SETTLE=2 BOOT_WAIT=40 game_settle # lowered quiet time, raised bound
    NOGAME_SETTLE=20 NOGAME_WAIT=25 nogame_settle # raised quiet time
    BOOT_WAIT=3 game_settle # a bound below the default cuts it
    run cat "$T/calls"
    assert_output "game 2 42
ui 20 45
game 3 6"
}

@test "settle_* on the host: only loads reboot.bash (no e2e.bash there): the call is built and the settle variables are forwarded" {
    # a fresh shell that has ONLY the host helpers, as reboot.bats has
    run bash -c '
        source "$1/helpers/reboot.bash"
        dev_kit() { echo "limit=$1 script=$2"; }
        BOOT_WAIT=20 settle_boot
        UI_WAIT=6 UI_SETTLE=3 settle_ui_short "12 34 first line"
        NOGAME_WAIT=25 settle_nogame
        echo "$RB_ENV_VARS"' _ "$TESTS_DIR"
    assert_success
    assert_output --partial "limit=100 script= game_settle"
    assert_output --partial "script=E2E_LAUNCH_REF='12 34 first line'; export E2E_LAUNCH_REF; ui_settle"
    assert_output --partial "script= nogame_settle"
    assert_output --partial "BOOT_SETTLE UI_SETTLE NOGAME_SETTLE"
}

@test "settle_ui / settle_game / settle_nogame: the verdict comes from the device (a game process, no game)" {
    fake_settle_tools
    echo 100 >"$FS/nextui.pid"
    dev_install_kit
    # a real process with the emulator's argv: argv0 PPSSPPSDL_tg5040 and the ROM as an argument
    ( exec -a PPSSPPSDL_tg5040 bash -c 'sleep 60; :' "$ROM" ) 3>&- &
    local gp=$!
    echo "$gp" >"$FS/game.pid"
    UI_SETTLE=1 UI_WAIT=5 run settle_ui_short
    assert_failure # a game runs: NextUI is not "settled"
    BOOT_SETTLE=1 BOOT_WAIT=5 run settle_boot
    assert_success
    kill "$gp" 2>/dev/null
    wait "$gp" 2>/dev/null || true
    rm -f "$FS/game.pid"
    UI_SETTLE=1 UI_WAIT=5 run settle_ui_short
    assert_success
    NOGAME_SETTLE=1 NOGAME_WAIT=5 run settle_nogame
    assert_success
    BOOT_SETTLE=1 BOOT_WAIT=2 run settle_boot
    assert_failure # no game
}

@test "launch_sig / launch_unchanged: a log that grew is not a launch; a rewritten one (inode, first line, smaller) is" {
    local log="$T/PSP.txt"
    run launch_sig "$T/none.txt"
    assert_output none
    printf '/pak/launch.sh /Roms/game.iso\nline 2\n' >"$log"
    local ref
    ref="$(launch_sig "$log")"
    launch_unchanged "$ref" "$log"
    printf 'more output of the running game\n' >>"$log" # appended: still the same launch
    launch_unchanged "$ref" "$log"
    printf '/pak/launch.sh /Roms/other.iso\nline 2\nmore output of the running game\n' >"$T/new.txt" # another first line
    rm "$log"
    cp "$T/new.txt" "$log"
    run launch_unchanged "$ref" "$log"
    assert_failure
    rm "$log"
    printf '/pak/launch.sh /Roms/game.iso\n' >"$log" # same first line, fewer bytes than before: rewritten
    ref="12 99 /pak/launch.sh /Roms/game.iso"
    run launch_unchanged "$ref" "$log"
    assert_failure
    run launch_unchanged none "$log" # there was no log, now there is one
    assert_failure
    rm "$log"
    launch_unchanged none "$log"
    run launch_unchanged "$ref" "$log" # a log that vanished is a change too (launch.sh deletes it first)
    assert_failure
}

@test "wait_ui_settled: a launch since the reference fails at once; an auto-resume marker is never quiet; the log can grow" {
    fake_settle_tools
    echo 100 >"$FS/nextui.pid"
    local log="$T/PSP.txt"
    printf 'first\n' >"$log"
    export E2E_LAUNCH_LOG="$log" E2E_LAUNCH_REF
    E2E_LAUNCH_REF="$(launch_sig "$log")"
    printf 'grows\n' >>"$log"
    run wait_ui_settled 1 5
    assert_success
    rm "$log"
    printf 'second\n' >"$log"
    run wait_ui_settled 1 5
    assert_failure
    assert_output --partial "launch.sh was started"
    unset E2E_LAUNCH_REF
    mkdir -p "$(dirname "$AUTORESUME")"
    : >"$AUTORESUME"
    run wait_ui_settled 1 2
    assert_failure
    assert_output --partial "the auto-resume marker exists"
    rm -f "$AUTORESUME"
    run wait_ui_settled 1 5
    assert_success
}

@test "wait_game_settled: /tmp/emulator_pid (when present) must name the game process; absent, it is not required" {
    fake_settle_tools
    echo 300 >"$FS/game.pid"
    export E2E_EMULATOR_PID_FILE="$T/emulator_pid"
    echo 999 >"$E2E_EMULATOR_PID_FILE" # another process: not attached to this game
    run wait_game_settled 1 3
    assert_failure
    assert_output --partial "emulator_pid: 999"
    echo 300 >"$E2E_EMULATOR_PID_FILE"
    run wait_game_settled 1 5
    assert_success
    rm -f "$E2E_EMULATOR_PID_FILE"
    run wait_game_settled 1 5
    assert_success
}

@test "dev_definite: a timeout or ssh failure is unknown (retried, then 2), a definite no is 1, yes is 0" {
    export RB_DEFINITE_TRIES=3
    dev_install_kit
    run dev_definite 10 true
    assert_success
    run dev_definite 10 false
    assert_failure 1
    export FAKE_SSH_DOWN_FROM=1 FAKE_SSH_DOWN_TO=100000
    run dev_definite 10 false
    assert_failure 2
    assert_output --partial "no definite answer"
    unset FAKE_SSH_DOWN_FROM FAKE_SSH_DOWN_TO
    run dev_definite 1 'exec sleep 20' # a timeout is unknown too
    assert_failure 2
}

@test "ensure_game never starts a game over one it could not see: an unreachable device is a failure, not 'not running'" {
    run awk '/^ensure_game\(\) \{/{f=1} f{print} /^\}/{f=0}' "$TESTS_DIR/bats/reboot.bats"
    assert_output --partial "dev_definite"
    refute_output --partial "! probe rb_rom_running"
}

@test "await_reboot: a WRONG port probe (never open) with working ssh: found by the new boot id, which signal is logged" {
    export RB_PORT_PROBE=false FAKE_SSH_NEWBOOT_AT=1 REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=20
    mkdir -p "$BAK"
    : >"$BAK/active"
    run await_reboot oldboot
    assert_success
    assert_output --partial "reboot: back via: ssh with a new boot_id (the port probe never saw the port open"
}

@test "await_reboot: a wrong port probe and ssh that answers the OLD id is still not a reboot" {
    export RB_PORT_PROBE=false REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=2
    run await_reboot oldboot
    assert_failure
    assert_output --partial "the device to come back"
}

@test "await_reboot: a false 'down' (port closed for a moment) does not leave a misleading port time" {
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=1 REBOOT_DOWN_TIMEOUT=10 REBOOT_UP_TIMEOUT=3
    # the port is open again at once but the boot id never changes: no reboot; then it closes for real
    run await_reboot oldboot
    assert_failure
    export RB_OLD_ID=oldboot RB_UP_N=0 RB_T_PORT=5
    export FAKE_PORT_DOWN_FROM=1 FAKE_PORT_DOWN_TO=100
    echo 0 >"$FAKE_PORT_STATE"
    rb_up_check || true
    [ -z "$RB_T_PORT" ]
}

@test "rb_net_setup: no /dev/tcp in bash selects nc (else ping), and the probes call them with short limits" {
    unset RB_PORT_PROBE
    printf '#!/bin/sh\necho "bash: /dev/tcp/127.0.0.1/9: No such file or directory" >&2\nexit 1\n' >"$T/bin/nobash"
    chmod +x "$T/bin/nobash"
    printf '#!/bin/sh\necho "$*" >"%s/nc.args"\n' "$T" >"$T/bin/nc"
    printf '#!/bin/sh\necho "$*" >"%s/ping.args"\n' "$T" >"$T/bin/ping"
    chmod +x "$T/bin/nc" "$T/bin/ping"
    RB_BASH="$T/bin/nobash" rb_net_setup
    [ "$RB_NET_VIA" = nc ]
    rb_port_open
    grep -q -- '-z -w 2 brick.example 2222' "$T/nc.args"
    rm "$T/bin/nc"
    PATH="$T/bin:/usr/bin:/bin" RB_BASH="$T/bin/nobash" rb_net_setup
    command -v nc >/dev/null 2>&1 && skip "a system nc exists: the ping branch cannot be selected here"
    [ "$RB_NET_VIA" = ping ]
    rb_port_open
    grep -q -- '-c1 -W1 brick.example' "$T/ping.args"
}

@test "touch_marker: returns once the clock moved past the marker, so a later write is newer" {
    touch_marker "$T/marker"
    : >"$T/later"
    [ "$T/later" -nt "$T/marker" ] || [ "$(stat -c %Y "$T/later")" -gt "$(stat -c %Y "$T/marker")" ]
    run touch_marker "$T/nodir/marker"
    assert_failure
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

@test "rb_backup binds a missing Save State/Exit hotkey (not Next Slot); rb_restore puts controls.ini back byte for byte" {
    seed_files
    printf '[ControlMapping]\nSelect = 10-196\nR = 10-192\n' >"$CONTROLS"
    cp "$CONTROLS" "$T/controls.orig"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    run rb_config_info
    assert_output --partial "NOT BOUND"
    cmp "$CONTROLS" "$T/controls.orig"     # nothing is written before the backup
    run rb_backup
    assert_success
    assert_output --partial "Save State = 10-196:10-192"
    assert_grep "$CONTROLS" '^Exit App = 10-196:10-197'
    refute_grep "$CONTROLS" '^Next Slot'
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    [ "$SAVE_KEYS" = select+r1 ] && [ -z "$HOTKEY_TO_BIND" ]
    run rb_restore
    assert_output --partial "controls.ini restored"
    cmp "$CONTROLS" "$T/controls.orig"
}

@test "rb_backup after an aborted run: the original controls.ini is restored first, then the hotkeys are bound again" {
    seed_files
    printf '[ControlMapping]\nSelect = 10-196\n' >"$CONTROLS"
    cp "$CONTROLS" "$T/controls.orig"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    rb_backup >/dev/null
    assert_differ "$CONTROLS" "$T/controls.orig"
    # the run is cut short here: no rb_restore. The next run:
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    run rb_backup
    assert_success
    assert_output --partial "restoring those files first"
    assert_output --partial "Save State = 10-196:10-192"
    rb_restore >/dev/null
    cmp "$CONTROLS" "$T/controls.orig"  # the ORIGINAL, not the run's bound version
}

@test "rb_backup: an unbound hotkey with SET_HOTKEYS=0 fails and leaves controls.ini alone" {
    seed_files
    printf '[ControlMapping]\nSelect = 10-196\n' >"$CONTROLS"
    cp "$CONTROLS" "$T/controls.orig"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    SET_HOTKEYS=0 rb_init
    SET_HOTKEYS=0 run rb_preflight
    assert_failure
    assert_output --partial "FAIL: Save State hotkey (Save State) is not bound"
    cmp "$CONTROLS" "$T/controls.orig"
}

# A device whose controls.ini has no hotkeys (so the tests bind them).
unbound_controls() {
    seed_files
    printf '[ControlMapping]\nSelect = 10-196\nR = 10-192\n' >"$CONTROLS"
    cp "$CONTROLS" "$T/controls.orig"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
}

@test "e2e and reboot share ONE backup dir: a bound file left by a cut-short run of either is restored first" {
    unbound_controls
    # the e2e side uses the same functions and the same dir (see e2e.bats): backup, bind, cut short
    cfg_reinit_hotkeys
    psp_backup >/dev/null
    cfg_apply_hotkeys >/dev/null
    assert_differ "$CONTROLS" "$T/controls.orig"
    [ "$BAK" = "$SHARED/.psp-test-backup" ]
    grep -q 'psp-test-backup' "$TESTS_DIR/bats/e2e.bats"
    # the other suite starts
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    run rb_backup
    assert_success
    assert_output --partial "aborted run"
    assert_output --partial "Save State = 10-196:10-192"
    run rb_restore
    assert_output --partial "controls.ini restored"
    cmp "$CONTROLS" "$T/controls.orig"   # the ORIGINAL, never the bound file
}

@test "an interrupted bind (killed between the first write and the end) is restored by the next start; nothing is lost" {
    unbound_controls
    cfg_reinit_hotkeys
    psp_backup >/dev/null
    cfg_controls_bind "$CONTROLS" "Save State" "10-196:10-192" # the first write ... and then the run dies
    assert_differ "$CONTROLS" "$T/controls.orig"
    assert_file_not_exist "$BAK/controls.bound"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    run rb_backup
    assert_success
    assert_output --partial "WARNING"          # the half-bound file is kept, not silently dropped
    run bash -c "grep -l 'Save State' '$CONTROLS'.replaced.*"
    assert_success
    rb_restore >/dev/null
    cmp "$CONTROLS" "$T/controls.orig"
}

@test "after a restore nothing points at the stash: a later user edit is never overwritten" {
    unbound_controls
    rb_backup >/dev/null
    run rb_restore
    assert_success
    assert_file_not_exist "$BAK/active"
    assert_file_not_exist "$BAK/present"
    printf '[ControlMapping]\nSelect = 10-196\nSave State = 10-197:10-193\n' >"$CONTROLS"   # the user edits it
    cp "$CONTROLS" "$T/user.edit"
    run rb_restore                                  # a second restore (or the next suite's start) does nothing
    assert_success
    cmp "$CONTROLS" "$T/user.edit"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    rb_backup >/dev/null                            # the edited file is the original of the next run
    rb_restore >/dev/null
    cmp "$CONTROLS" "$T/user.edit"
}

@test "a user edit after a CUT-SHORT run is kept as .replaced.<unique>, the original is restored, the edit is not lost" {
    unbound_controls
    rb_backup >/dev/null
    printf '[ControlMapping]\nSelect = 10-196\nSave State = 10-197:10-193\n' >"$CONTROLS"   # edited by the user
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    rb_init
    run rb_backup
    assert_output --partial "neither the backup nor what the tests left"
    run bash -c "cat '$CONTROLS'.replaced.*"
    assert_output --partial "Save State = 10-197:10-193"
    rb_restore >/dev/null
    cmp "$CONTROLS" "$T/controls.orig"
}

@test "a normal end of run: PPSSPP's own rewrite of ppsspp.ini is not a foreign change (no .replaced copy), a cut-short one is flagged" {
    seed_files
    rb_backup >/dev/null
    rb_ini_set SaveStateOnExit False
    printf '%s\n' '[General]' 'SaveStateOnExit = Rewritten' >"$INI"   # PPSSPP rewrote it when it exited
    run rb_restore
    assert_success
    refute_output --partial "WARNING"
    assert_same "$INI" "$T/ini.copy"
    set -- "$INI".replaced.*
    [ ! -e "$1" ]
    # cut short: nothing refreshed the snapshot, the rewrite differs from backup and from what the tests left
    rb_backup >/dev/null
    rb_ini_set SaveStateOnExit False
    printf '%s\n' '[General]' 'SaveStateOnExit = Rewritten' >"$INI"
    run rb_backup
    assert_output --partial "WARNING"
    run bash -c "grep -l Rewritten '$INI'.replaced.*"
    assert_success
}

@test "a backup that cannot be made completely (full SD card) fails before anything was changed" {
    unbound_controls
    cp() { command cp "$@" && : >"$2"; } # every copy is truncated
    run rb_backup
    assert_failure
    assert_output --partial "could not back up"
    unset -f cp
    cmp "$CONTROLS" "$T/controls.orig"
    assert_file_not_exist "$BAK/active"
    refute_grep "$CONTROLS" 'Save State'
}

@test "psp_restore stops the game BEFORE restoring; a game that is still starting means NOT restored and the backup stays" {
    unbound_controls
    rb_backup >/dev/null
    PSP_STOP_GAME=hook
    hook() { command cp "$CONTROLS" "$T/seen-at-stop"; }
    run psp_restore normal
    assert_success
    grep -q 'Save State = 10-196:10-192' "$T/seen-at-stop"   # still bound when the game was stopped
    cmp "$CONTROLS" "$T/controls.orig"                        # restored after
    # now a game that cannot be stopped (still starting): nothing is restored
    rb_backup >/dev/null
    export PSP_STOP_GAME=false
    run psp_restore normal
    assert_failure
    assert_output --partial "not restored"
    assert_output --partial "$BAK"
    assert_file_exist "$BAK/active"
    grep -q 'Save State = 10-196:10-192' "$CONTROLS"
}

@test "rb_restore after a reboot: waits for the SD card, and fails loudly when there is no backup (RB_EXPECT_BACKUP)" {
    unbound_controls
    RB_EXPECT_BACKUP=1 RB_SD_WAIT=1 run rb_restore
    assert_failure
    assert_output --partial "no backup found at $BAK"
    assert_output --partial "NOTHING WAS RESTORED"
    # the backup shows up while it waits (the SD card gets mounted)
    rb_backup >/dev/null
    mv "$BAK" "$T/unmounted"
    ( sleep 1; mv "$T/unmounted" "$BAK" ) &
    RB_EXPECT_BACKUP=1 RB_SD_WAIT=5 run rb_restore
    wait
    assert_success
    cmp "$CONTROLS" "$T/controls.orig"
    # without the expectation a missing backup is fine (nothing to do)
    run rb_restore
    assert_success
}

# --- the end of a run, with the real functions ----------------------------------------------------
fake_game_up() { # a NextUI that is up and no game: what e2e_stop_game wants to see
    mkdir -p "$T/fb"
    printf '#!/bin/sh\n[ "$1" = nextui.elf ]\n' >"$T/fb/pgrep"
    printf '#!/bin/sh\n:\n' >"$T/fb/killall"
    chmod +x "$T/fb/pgrep" "$T/fb/killall"
    export PATH="$T/fb:$PATH"
    # shellcheck disable=SC1091
    . "$HELPERS/e2e.bash" # the real e2e_stop_game (make_device made it a no-op)
}

@test "end of run: a leftover backup this run did not make (its setup failed early) is restored STRICTLY, a user edit survives" {
    unbound_controls
    rb_backup >/dev/null                                  # an older, cut-short run
    printf '[General]\nSaveStateOnExit = USER\n' >"$INI"  # the user edits ppsspp.ini ...
    printf '[ControlMapping]\nSelect = 10-196\nSave State = 10-197:10-193\n' >"$CONTROLS" # ... and controls.ini
    unset PSP_RUN_ID                                      # this run failed before its own backup
    run psp_finish
    assert_success
    assert_output --partial "WARNING"
    assert_same "$INI" "$T/ini.copy"
    cmp "$CONTROLS" "$T/controls.orig"
    run bash -c "cat '$INI'.replaced.* '$CONTROLS'.replaced.*"
    assert_output --partial "SaveStateOnExit = USER"
    assert_output --partial "Save State = 10-197:10-193"
    assert_file_not_exist "$BAK/active"
    # a backup with ANOTHER run's id is just as strict
    seed_files
    rb_backup >/dev/null
    printf 'edited by hand' >"$RECENT"
    PSP_RUN_ID=some-other-run run psp_finish
    assert_output --partial "neither the backup nor what the tests left"
}

@test "end of run: the backup this run made is restored normally (its own changes are not 'foreign')" {
    unbound_controls
    rb_backup >/dev/null
    [ -n "$PSP_RUN_ID" ] && [ "$(cat "$BAK/active")" = "$PSP_RUN_ID" ]
    printf '/Roms/changed.iso\n' >"$RECENT"               # what NextUI does during the run
    printf '%s\n' '[General]' 'x = rewritten by PPSSPP' >"$INI"
    run psp_finish
    assert_success
    refute_output --partial "WARNING"
    assert_same "$INI" "$T/ini.copy"
    cmp "$CONTROLS" "$T/controls.orig"
}

@test "psp_backup sets PSP_RUN_ID only when it succeeded" {
    unbound_controls
    unset PSP_RUN_ID
    cp() { command cp "$@" && : >"$2"; }
    run psp_backup
    assert_failure
    unset -f cp
    [ -z "${PSP_RUN_ID:-}" ]
    psp_backup >/dev/null
    [ -n "$PSP_RUN_ID" ]
}

@test "recover after an abort: another game's state and a NEWER recent.txt of the user are not lost or deleted" {
    unbound_controls
    rb_backup >/dev/null
    printf 'user state' >"$STATE_DIR/OTHERGAME_1.00_0.ppst"     # the user plays another game ...
    printf '/Roms/the-users-newest.iso\n' >"$RECENT"             # ... recents moved on
    printf 'users switcher' >"$PERSIST"                           # a file that did not exist at the backup
    unset PSP_RUN_ID
    run psp_finish
    assert_success
    assert_file_exist "$STATE_DIR/OTHERGAME_1.00_0.ppst"
    run cat "$RECENT"
    assert_output "/Roms/other.iso"
    run bash -c "cat '$RECENT'.replaced.*"
    assert_output "/Roms/the-users-newest.iso"
    run bash -c "cat '$PERSIST'.replaced.*"
    assert_output "users switcher"
    assert_file_not_exist "$PERSIST"
}

@test "normal end of run: only states made since the backup are deleted; the ones that were there stay" {
    unbound_controls
    : >"$STATE_DIR/OLD_1.00_1.ppst"
    rb_backup >/dev/null
    sleep 1
    : >"$STATE_DIR/NEW_1.00_2.ppst"
    run psp_finish
    assert_success
    assert_file_not_exist "$STATE_DIR/NEW_1.00_2.ppst"
    assert_file_exist "$STATE_DIR/OLD_1.00_1.ppst"
    assert_file_exist "$STATE_DIR/OLD_1.00_0.ppst"
}

@test "a backup of an OLDER version (per-test dirs) is restored first, retired, and never taken for the original" {
    unbound_controls
    local old="$SHARED/.psp-e2e-backup"
    mkdir -p "$old$(dirname "$CONTROLS")"
    command cp -p "$CONTROLS" "$old$CONTROLS"
    printf '%s\n' "$CONTROLS" >"$old/present"
    : >"$old/active"
    printf '%s' 'older version: bound' >>"$CONTROLS"      # the file the cut-short run left
    cp "$CONTROLS" "$T/old-live"
    run rb_backup
    assert_success
    assert_output --partial "older version"
    assert_output --partial "WARNING"                       # not what the old run is known to have left: kept
    run bash -c "cat '$CONTROLS'.replaced.*"
    assert_output --partial "older version: bound"
    assert_file_not_exist "$old/active"
    [ -d "$(echo "$old".restored.*)" ]
    # the new backup holds the ORIGINAL: restoring it gives that back
    rb_restore >/dev/null
    cmp "$CONTROLS" "$T/controls.orig"
}

@test "an older version's backup that cannot be restored stops the run and names the directory" {
    unbound_controls
    local old="$SHARED/.psp-reboot-backup"
    mkdir -p "$old"
    printf '%s\n' "$CONTROLS" >"$old/present"   # listed, but the copy is missing
    : >"$old/active"
    run rb_backup
    assert_failure
    assert_output --partial "$old"
    assert_file_exist "$old/active"
}

@test "restores are atomic: a copy that fails leaves the live file untouched and the backup active" {
    unbound_controls
    rb_backup >/dev/null
    printf 'user content' >"$RECENT"
    cp "$RECENT" "$T/live"
    cp() { return 1; }
    PSP_RUN_ID="$(cat "$BAK/active")" run psp_finish
    unset -f cp
    assert_failure
    assert_output --partial "backup stays"
    cmp "$RECENT" "$T/live"
    assert_file_exist "$BAK/active"
    run bash -c "ls '$RECENT'.psp-restore.* 2>/dev/null"
    assert_output ""
}

@test "unchecked writes are checked: active, present and states.before that cannot be written abort before anything is touched" {
    unbound_controls
    mkdir -p "$BAK/active"                    # writing the active flag must fail (a directory)
    run psp_backup
    assert_failure
    assert_output --partial "could not write"
    rmdir "$BAK/active"
    mkdir -p "$BAK/present"
    run psp_backup
    assert_failure
    assert_output --partial "could not back up"
    cmp "$CONTROLS" "$T/controls.orig"
    assert_file_not_exist "$BAK/active"
    rm -rf "$BAK/present"
    mkdir -p "$BAK/states.before"
    run psp_backup
    assert_failure
    assert_output --partial "states.before"
}

@test "PPSSPP's own rewrite is tolerated once the game has been stopped (snapshot after the stop); a later edit is not" {
    seed_files
    fake_game_up
    psp_backup >/dev/null
    printf '%s\n' '[General]' 'x = rewritten by PPSSPP when it exited' >"$INI"
    e2e_stop_game                                  # the harness stops/settles: the files are noted
    # the run is cut short here. The next start:
    unset PSP_RUN_ID
    run psp_backup
    refute_output --partial "WARNING"
    assert_same "$INI" "$T/ini.copy"
    psp_restore normal >/dev/null
    # and the same cut-short run with a user edit AFTER the last stop is flagged
    psp_backup >/dev/null
    printf '%s\n' '[General]' 'x = rewritten' >"$INI"
    e2e_stop_game
    printf '%s\n' '[General]' 'x = the user edited it' >"$INI"
    unset PSP_RUN_ID
    run psp_backup
    assert_output --partial "WARNING"
    run bash -c "cat '$INI'.replaced.*"
    assert_output --partial "the user edited it"
}

@test "rb_restore: a backup this run made is waited for; none known means a leftover is just restored strictly" {
    unbound_controls
    rb_backup >/dev/null
    PSP_RUN_ID="$(cat "$BAK/active")" run rb_restore
    assert_success
    assert_output --partial "controls.ini restored"
}

@test "SET_HOTKEYS is forwarded to the device when set" {
    run rb_env_prelude
    refute_output --partial SET_HOTKEYS
    SET_HOTKEYS=0 run rb_env_prelude
    assert_output --partial "export SET_HOTKEYS='0';"
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
    # (save states are never deleted when recovering a cut-short run: their origin is not known)
    assert_file_exist "$STATE_DIR/NEW_1.00_2.ppst"
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

@test "new states: PPSSPP's undo copies (load_undo.ppst, save_undo.ppst, *.undo.*) are never states" {
    mkdir -p "$BAK"
    touch -d '2020-01-01 00:00:00' "$BAK/marker"
    : >"$STATE_DIR/load_undo.ppst" # written at game start when a state is auto-loaded
    : >"$STATE_DIR/save_undo.ppst"
    : >"$STATE_DIR/G_1.00_0.undo.ppst"
    : >"$STATE_DIR/G_1.00_0.undo.jpg"
    run rb_new_states
    assert_output ""
    run rb_has_new_state
    assert_failure
    run rb_all_states
    assert_output ""
    : >"$STATE_DIR/G_1.00_2.ppst"
    run rb_has_new_state
    assert_success
    run rb_new_states
    assert_output "$STATE_DIR/G_1.00_2.ppst"
}

@test "state snapshot: undo copies are not part of it (a load_undo.ppst appearing is not a change)" {
    mkdir -p "$BAK"
    printf 'aaa' >"$STATE_DIR/G_1.00_0.ppst"
    rb_save_snapshot
    printf 'x' >"$STATE_DIR/load_undo.ppst"
    printf 'y' >"$STATE_DIR/save_undo.ppst"
    run rb_states_intact
    assert_success
    run cat "$BAK/evidence-states-before"
    refute_output --partial undo
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
    : >"$STATE_DIR/load_undo.ppst" # PPSSPP's undo copies are no saved states
    : >"$STATE_DIR/save_undo.ppst"
    : >"$STATE_DIR/NEW_1.00_5.undo.ppst"
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

@test "rb_preflight: a hotkey bound to something the test cannot press is one clear FAIL line" {
    printf '[ControlMapping]\nSelect = 10-196\nSave State = 1-133\n' >"$CONTROLS"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS # rb_init in setup set them
    rb_init
    RB_REBOOT_CMD=/bin/true run rb_preflight
    assert_failure
    assert_output --partial "FAIL: Save State hotkey (Save State) is bound to '1-133'"
}

@test "rb_save_state and rb_quit_game press the hotkeys read from the device's controls.ini" {
    printf '[ControlMapping]\nSelect = 10-196\nStart = 10-197\nL = 10-193\nR = 10-192\nSave State = 10-197:10-193\nExit App = 10-196:10-192\n' >"$CONTROLS"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS # rb_init in setup set them
    rb_init
    press() { echo "$1" >>"$T/pressed"; }
    rb_save_state
    rb_quit_game
    run cat "$T/pressed"
    assert_output "start+l1
select+r1"
}

@test "dev_kit: the kit has devconfig.bash, so the hotkeys are resolved on the device" {
    printf '[ControlMapping]\nSelect = 10-196\nStart = 10-197\nExit App = 10-197:10-196\nSave State = 10-196:10-192\nR = 10-192\n' >"$CONTROLS"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS # set by rb_init in setup; the device resolves its own
    run dev_install_kit
    assert_success
    run dev_kit 20 'echo "$EXIT_KEYS|$SAVE_KEYS"'
    assert_output "start+select|select+r1"
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

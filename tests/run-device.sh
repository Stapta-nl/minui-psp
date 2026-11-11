#!/usr/bin/env bash
# On-device tests over ssh (make test-device / make test-device-<platform>).
#
# Usage: run-device.sh <platform> [--skip-unconfigured]
#
# The device is configured with <PLATFORM>_HOST (ssh target) and optionally
# <PLATFORM>_SSH_OPTS (extra ssh options, split on spaces), see tests/devices.env.example.
#   not configured  : an error, or with --skip-unconfigured a message and exit 0
#   configured but unreachable, tools missing, tests fail: exit non-zero
#
# Flow: check the device is reachable and has bash, tar, gzip, mktemp, awk, sort, uniq and cut (any missing is
# named); stream dist/psp-device-tests.tar.gz (make test-bundle) into a temp dir on the
# device; run the bats tests tagged "device" (and for this platform) there; bring back the
# JUnit report, logs, screenshots and device info; remove the temp dir. The debug bundle is
# dist/test-report-<platform>-<timestamp>.tar.gz.
#
# ssh always runs with BatchMode=yes (no prompts) and a connect timeout
# ($SSH_CONNECT_TIMEOUT, default 10 s). The bundle is streamed through ssh instead of scp,
# which needs an sftp server that small devices (dropbear) often lack.
#
# The pak is expected in Emus/<platform>/<PAK_NAME>.pak; PAK_NAME defaults to "name" in
# pak.json (PSP) and is passed to the device.
#
# Forwarded to the device when set: SDCARD_PATH ROM_DIR ROM PSP_KEYS EXIT_KEYS BOOT_WAIT
# UI_WAIT KEY_GAP CHORD_HOLD KEEP LAUNCH_SHELL TMP_ROOT.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

platform="${1:-}"
skip_unconfigured=0
[ "${2:-}" = "--skip-unconfigured" ] && skip_unconfigured=1
case "$platform" in "" | *[!a-z0-9_]*)
    echo "usage: run-device.sh <platform> [--skip-unconfigured]" >&2
    exit 2
    ;;
esac

upper="$(printf '%s' "$platform" | tr '[:lower:]' '[:upper:]')"
host_var="${upper}_HOST"
opts_var="${upper}_SSH_OPTS"
host="${!host_var:-}"
host="${host//[[:space:]]/}"
opts="${!opts_var:-}"

if [ -z "$host" ]; then
    if [ "$skip_unconfigured" = 1 ]; then
        echo "SKIP $platform: $host_var is not set (see tests/devices.env.example)"
        exit 0
    fi
    echo "ERROR $platform: $host_var is not set. Copy tests/devices.env.example to tests/devices.env or run: make test-device-$platform $host_var=root@<device>" >&2
    exit 2
fi

stage="dist/test-out/$platform"
rm -rf "dist/test-out/$platform"
mkdir -p "$stage"
TEST_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TEST_STARTED
export TEST_TARGET_INFO="$platform: $host_var is set (the address is not recorded)"
export PLATFORM="$platform"

ssh_base=(ssh -o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-10}" -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
read -r -a ssh_extra <<<"$opts"
rssh() { "${ssh_base[@]}" ${ssh_extra[@]+"${ssh_extra[@]}"} "$host" "$@"; }
# Quotes a value for the remote shell.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Escapes a string for use in an extended regular expression.
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$|/(){}+?]/\\&/g'; }

# The names redact() must hide: <PLATFORM>_HOST (user@host or an ssh_config alias) and what
# ssh resolves it to (ssh -G connects to nothing): the real HostName and the user.
redact_literals=()
add_redact_literal() { [ -n "$1" ] && redact_literals+=("$1"); }
add_redact_literal "$host"
add_redact_literal "${host#*@}"
if command -v ssh >/dev/null 2>&1; then
    while read -r key value; do
        case "$key" in
        hostname | user) add_redact_literal "$value" ;;
        esac
    done < <("${ssh_base[@]}" ${ssh_extra[@]+"${ssh_extra[@]}"} -G "$host" 2>/dev/null </dev/null)
fi

# Masks the device address in text that goes into the bundle (stdin to stdout): the literal
# names above, then, whatever their source, ssh's "connect to host X port N" style text and any
# IPv4 or IPv6 address. Use it for everything in the bundle that came from ssh.
redact() {
    local args=() lit
    for lit in ${redact_literals[@]+"${redact_literals[@]}"}; do
        args+=(-e "s|$(re_escape "$lit")|<device>|g")
    done
    sed -E ${args[@]+"${args[@]}"} \
        -e "s/(connect to host )[^ ]+( port)/\1<device>\2/g" \
        -e "s/(Could not resolve hostname )[^:]+:/\1<device>:/g" \
        -e "s/(Permanently added ')[^']*'/\1<device>'/g" \
        -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' \
        -e 's/(^|[^0-9A-Fa-f:])[0-9A-Fa-f:]*::[0-9A-Fa-f:]*/\1<ip>/g' \
        -e 's/(^|[^0-9A-Fa-f:])([0-9A-Fa-f]{1,4}:){5,7}[0-9A-Fa-f]{1,4}/\1<ip>/g'
}

remote_tmp=""
run_pid=""
finishing=0
# Best-effort removal of the remote temp dir: BatchMode, a connect timeout and an overall
# timeout (CLEANUP_TIMEOUT, default 20 s), so an interrupted run never hangs on it.
cleanup() {
    case "$remote_tmp" in
    /tmp/psp-tests.*)
        if command -v timeout >/dev/null 2>&1; then
            timeout -k 2 "${CLEANUP_TIMEOUT:-20}" "${ssh_base[@]}" ${ssh_extra[@]+"${ssh_extra[@]}"} "$host" "rm -rf '$remote_tmp'" >/dev/null 2>&1 </dev/null
        else
            rssh "rm -rf '$remote_tmp'" >/dev/null 2>&1 </dev/null
        fi
        ;;
    esac
}

# finish <status> [message]: removes the remote temp dir, writes the debug bundle and exits.
# It runs once: later signals are ignored and the EXIT trap does nothing after it.
finish() {
    local status="$1"
    [ "$finishing" = 0 ] || exit "$status"
    finishing=1
    trap '' INT TERM HUP
    trap - EXIT
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | redact >"$stage/error.txt"
        printf 'ERROR %s: %s\n' "$platform" "$2" | redact >&2
    fi
    if [ -f "$stage/console.log" ]; then
        redact <"$stage/console.log" >"$stage/console.log.tmp" && mv "$stage/console.log.tmp" "$stage/console.log"
    fi
    TEST_FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export TEST_FINISHED
    cleanup
    bash tests/bundle.sh "$platform" "$status"
    exit "$status"
}

# Stops the background ssh pipeline of a step (see run_step).
# shellcheck disable=SC2317 # only called from the traps
stop_run() {
    [ -n "$run_pid" ] || return 0
    command -v pkill >/dev/null 2>&1 && pkill -TERM -P "$run_pid" 2>/dev/null
    kill -TERM "$run_pid" 2>/dev/null
    run_pid=""
}

# on_signal <name> <exit status>: a Ctrl-C or kill still cleans up the device and writes the
# bundle, which is marked as interrupted.
# shellcheck disable=SC2317 # only called from the traps
on_signal() {
    trap '' INT TERM HUP
    stop_run
    printf '%s\n' "$1" >"$stage/interrupted.txt"
    finish "$2" "the run was interrupted ($1)"
}
trap 'on_signal SIGINT 130' INT
trap 'on_signal SIGTERM 143' TERM
trap 'on_signal SIGHUP 129' HUP
# Any other exit (an unexpected failure) is still cleaned up and bundled.
trap 'finish "$?" "the run ended unexpectedly"' EXIT

# run_step <stdin file> <command...>: runs a long ssh step in the background and waits for it,
# because bash only runs a trap after a foreground command ends, which would delay a kill of
# this script until the tests are over.
run_step() {
    local in="$1"
    shift
    "$@" <"$in" &
    run_pid=$!
    local rc=0
    wait "$run_pid" || rc=$?
    run_pid=""
    return "$rc"
}

command -v ssh >/dev/null 2>&1 || finish 2 "ssh is not installed on this machine"
[ -f dist/psp-device-tests.tar.gz ] || finish 2 "dist/psp-device-tests.tar.gz is missing (make test-bundle)"

echo "== $platform: connecting"
if ! err="$(rssh true 2>&1 </dev/null)"; then
    finish 3 "$host_var is set but the device is unreachable: $err"
fi

# shellcheck disable=SC2016 # runs on the device, $t must not expand here
missing="$(rssh 'for t in bash tar gzip mktemp awk sort uniq cut; do command -v "$t" >/dev/null 2>&1 || printf "%s " "$t"; done' 2>&1 </dev/null)" ||
    finish 3 "checking the device's tools failed: $missing"
missing="${missing% }"
[ -z "$missing" ] || finish 3 "required tools missing on the device: $missing"

remote_tmp="$(rssh 'mktemp -d /tmp/psp-tests.XXXXXX' 2>&1 </dev/null)" || finish 3 "cannot create a temp dir on the device: $remote_tmp"
case "$remote_tmp" in /tmp/psp-tests.*) ;; *) finish 3 "unexpected temp dir from the device: $remote_tmp" ;; esac

echo "== $platform: copying the test bundle"
run_step dist/psp-device-tests.tar.gz rssh "cd '$remote_tmp' && gzip -dc | tar -xf -" ||
    finish 3 "copying the test bundle to the device failed"

# Tests tagged platform:<name> run only on that platform; untagged device tests run everywhere.
# Built from pak.json, so a new platform needs no change here.
filter_platform="device,platform:$platform"
filter_generic="device"
while IFS= read -r p; do
    filter_generic="$filter_generic,!platform:$p"
done < <(jq -r '.platforms[]' pak.json)

sd="${SDCARD_PATH:-/mnt/SDCARD}"
pak_name="${PAK_NAME:-$(jq -r '.name // empty' pak.json 2>/dev/null)}"
pak_name="${pak_name:-PSP}"
assignments="PLATFORM=$(q "$platform") PAK_NAME=$(q "$pak_name") SRC_PAK=$(q "$sd/Emus/$platform/$pak_name.pak") RESULT_DIR=$(q "$remote_tmp/result") DEVICE_COLLECT=1"
for v in SDCARD_PATH ROM_DIR ROM PSP_KEYS EXIT_KEYS BOOT_WAIT UI_WAIT KEY_GAP CHORD_HOLD KEEP LAUNCH_SHELL TMP_ROOT; do
    if [ -n "${!v+x}" ]; then
        assignments="$assignments $v=$(q "${!v}")"
    fi
done

echo "== $platform: running the device tests"
# shellcheck disable=SC2317 # called through run_step
run_tests() {
    rssh "cd '$remote_tmp' && $assignments bash tests/run-bats.sh --filter-tags $(q "$filter_platform") --filter-tags $(q "$filter_generic")" </dev/null |
        tee "$stage/console.log"
    return "${PIPESTATUS[0]}"
}
run_step /dev/null run_tests
rc=$?

# shellcheck disable=SC2317 # called through run_step
fetch_results() {
    rssh "cd '$remote_tmp/result' && tar -cf - ." </dev/null | tar -xf - -C "$stage"
}
echo "== $platform: fetching results"
if ! run_step /dev/null fetch_results; then
    finish 3 "fetching the results from the device failed (exit status of the tests: $rc)"
fi
[ "$rc" != 255 ] || finish 3 "the ssh connection broke while the tests ran"
finish "$rc"

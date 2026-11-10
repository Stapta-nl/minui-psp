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
# Flow: check the device is reachable and has bash, tar, gzip and mktemp (any missing is
# named); stream dist/psp-device-tests.tar.gz (make test-bundle) into a temp dir on the
# device; run the bats tests tagged "device" (and for this platform) there; bring back the
# JUnit report, logs, screenshots and device info; remove the temp dir. The debug bundle is
# dist/test-report-<platform>-<timestamp>.tar.gz.
#
# ssh always runs with BatchMode=yes (no prompts) and a connect timeout
# ($SSH_CONNECT_TIMEOUT, default 10 s). The bundle is streamed through ssh instead of scp,
# which needs an sftp server that small devices (dropbear) often lack.
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

# Replaces the device address in text that goes into the bundle.
redact() {
    local pattern
    pattern="$(printf '%s' "${host#*@}" | sed 's/[][\.*^$|/]/\\&/g')"
    sed "s|$pattern|<device>|g"
}

remote_tmp=""
cleanup() {
    case "$remote_tmp" in
    /tmp/psp-tests.*) rssh "rm -rf '$remote_tmp'" >/dev/null 2>&1 ;;
    esac
}

# finish <status> [message]: writes the debug bundle and exits.
finish() {
    local status="$1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | redact >"$stage/error.txt"
        printf 'ERROR %s: %s\n' "$platform" "$2" | redact >&2
    fi
    TEST_FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export TEST_FINISHED
    cleanup
    bash tests/bundle.sh "$platform" "$status"
    exit "$status"
}

ssh_base=(ssh -o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-10}" -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
read -r -a ssh_extra <<<"$opts"
rssh() { "${ssh_base[@]}" ${ssh_extra[@]+"${ssh_extra[@]}"} "$host" "$@"; }
# Quotes a value for the remote shell.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

command -v ssh >/dev/null 2>&1 || finish 2 "ssh is not installed on this machine"
[ -f dist/psp-device-tests.tar.gz ] || finish 2 "dist/psp-device-tests.tar.gz is missing (make test-bundle)"

echo "== $platform: connecting"
if ! err="$(rssh true 2>&1 </dev/null)"; then
    finish 3 "$host_var is set but the device is unreachable: $err"
fi

# shellcheck disable=SC2016 # runs on the device, $t must not expand here
missing="$(rssh 'for t in bash tar gzip mktemp; do command -v "$t" >/dev/null 2>&1 || printf "%s " "$t"; done' 2>&1 </dev/null)" ||
    finish 3 "checking the device's tools failed: $missing"
missing="${missing% }"
[ -z "$missing" ] || finish 3 "required tools missing on the device: $missing"

remote_tmp="$(rssh 'mktemp -d /tmp/psp-tests.XXXXXX' 2>&1 </dev/null)" || finish 3 "cannot create a temp dir on the device: $remote_tmp"
case "$remote_tmp" in /tmp/psp-tests.*) ;; *) finish 3 "unexpected temp dir from the device: $remote_tmp" ;; esac

echo "== $platform: copying the test bundle"
rssh "cd '$remote_tmp' && gzip -dc | tar -xf -" <dist/psp-device-tests.tar.gz ||
    finish 3 "copying the test bundle to the device failed"

# Tests tagged platform:<name> run only on that platform; untagged device tests run everywhere.
# Built from pak.json, so a new platform needs no change here.
filter_platform="device,platform:$platform"
filter_generic="device"
while IFS= read -r p; do
    filter_generic="$filter_generic,!platform:$p"
done < <(jq -r '.platforms[]' pak.json)

sd="${SDCARD_PATH:-/mnt/SDCARD}"
assignments="PLATFORM=$(q "$platform") SRC_PAK=$(q "$sd/Emus/$platform/PSP.pak") RESULT_DIR=$(q "$remote_tmp/result") DEVICE_COLLECT=1"
for v in SDCARD_PATH ROM_DIR ROM PSP_KEYS EXIT_KEYS BOOT_WAIT UI_WAIT KEY_GAP CHORD_HOLD KEEP LAUNCH_SHELL TMP_ROOT; do
    if [ -n "${!v+x}" ]; then
        assignments="$assignments $v=$(q "${!v}")"
    fi
done

echo "== $platform: running the device tests"
rssh "cd '$remote_tmp' && $assignments bash tests/run-bats.sh --filter-tags $(q "$filter_platform") --filter-tags $(q "$filter_generic")" </dev/null |
    tee "$stage/console.log"
rc=${PIPESTATUS[0]}

echo "== $platform: fetching results"
if ! rssh "cd '$remote_tmp/result' && tar -cf - ." </dev/null | tar -xf - -C "$stage"; then
    finish 3 "fetching the results from the device failed (exit status of the tests: $rc)"
fi
[ "$rc" != 255 ] || finish 3 "the ssh connection broke while the tests ran"
finish "$rc"

#!/usr/bin/env bash
# The on-device tests that REBOOT the device (tests/bats/reboot.bats), run from the host over ssh.
# Called by run-device.sh after the on-device tests; usable on its own.
#
# Usage: run-reboot.sh <platform> <stage dir>
# Environment: DEVICE_HOST (ssh target), DEVICE_SSH_OPTS (extra ssh options): set by run-device.sh.
#   SKIP_REBOOT_TESTS=1  do not run them (exit 0): for when the device must not be rebooted.
# Everything else (SDCARD_PATH ROM_DIR ROM EXIT_KEYS BOOT_WAIT UI_WAIT KEEPAWAKE_* REBOOT_*
# ...) is read from the environment by the tests, see tests/bats/reboot.bats and tests/helpers/reboot.bash.
#
# Writes <stage dir>/reboot/ (output.tap, junit/report.xml, logs/, exit-code) and
# <stage dir>/reboot-console.log. Exits with bats' status; 2 on a usage error.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

platform="${1:-}"
stage="${2:-}"
case "$platform" in "" | *[!a-z0-9_]*)
    echo "usage: run-reboot.sh <platform> <stage dir>" >&2
    exit 2
    ;;
esac
[ -n "$stage" ] || {
    echo "usage: run-reboot.sh <platform> <stage dir>" >&2
    exit 2
}
case "${SKIP_REBOOT_TESTS:-}" in "" | 0) ;; *)
    echo "SKIP $platform: the tests that reboot the device (SKIP_REBOOT_TESTS is set)"
    exit 0
    ;;
esac
[ -n "${DEVICE_HOST:-}" ] || {
    echo "run-reboot.sh: DEVICE_HOST is not set" >&2
    exit 2
}

# Tests tagged platform:<name> run only on that platform; untagged ones run everywhere
# (the same rule as run-device.sh, built from pak.json).
filter_platform="reboot,platform:$platform"
filter_generic="reboot"
while IFS= read -r p; do
    filter_generic="$filter_generic,!platform:$p"
done < <(jq -r '.platforms[]' pak.json)

case "$stage" in /*) abs_stage="$stage" ;; *) abs_stage="$ROOT/$stage" ;; esac
mkdir -p "$abs_stage"
rm -rf "$abs_stage/reboot"
echo "== $platform: running the tests that reboot the device"
export PLATFORM="$platform"
RESULT_DIR="$abs_stage/reboot" bash tests/run-bats.sh --filter-tags "$filter_platform" --filter-tags "$filter_generic" |
    tee "$abs_stage/reboot-console.log"
exit "${PIPESTATUS[0]}"

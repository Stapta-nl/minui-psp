#!/usr/bin/env bash
# `make test`: the tests tagged "host" on this machine. Never uses ssh.
# Writes dist/test-out/host/ and the debug bundle dist/test-report-host-<timestamp>.tar.gz.
# On Ctrl-C or a kill the tests are stopped, the bundle is still written (marked as
# interrupted) and the exit status is 130 (INT), 143 (TERM) or 129 (HUP).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
rm -rf dist/test-out/host
mkdir -p dist/test-out/host
TEST_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TEST_STARTED

bundled=0
bats_pid=""
# write_bundle <exit status>: once only.
write_bundle() {
    [ "$bundled" = 0 ] || exit "$1"
    bundled=1
    trap '' INT TERM HUP
    trap - EXIT
    TEST_FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export TEST_FINISHED
    bash tests/bundle.sh host "$1"
    exit "$1"
}
# on_signal <name> <unused> <exit status>: stops the tests with SIGINT, which bats handles by
# running its teardown,
# waits a few seconds for them, then writes the bundle.
# shellcheck disable=SC2317 # only called from the traps
on_signal() {
    local waited=0
    trap '' INT TERM HUP
    if [ -n "$bats_pid" ]; then
        kill -INT -- "-$bats_pid" 2>/dev/null # the job's whole process group (set -m)
        while [ "$waited" -lt 20 ]; do
            waited=$((waited + 1))
            kill -0 "$bats_pid" 2>/dev/null || break
            sleep 0.5
        done
        kill -KILL -- "-$bats_pid" 2>/dev/null
    fi
    printf '%s\n' "$1" >dist/test-out/host/interrupted.txt
    write_bundle "$3"
}
trap 'on_signal SIGINT - 130' INT
trap 'on_signal SIGTERM - 143' TERM
trap 'on_signal SIGHUP - 129' HUP
trap 'write_bundle "$?"' EXIT

# In the background, so a trap runs at once instead of after the tests. Job control (set -m)
# keeps the job from ignoring SIGINT, which an async command otherwise does.
set -m
RESULT_DIR="$ROOT/dist/test-out/host" bash tests/run-bats.sh --filter-tags host &
bats_pid=$!
wait "$bats_pid"
rc=$?
bats_pid=""
write_bundle "$rc"

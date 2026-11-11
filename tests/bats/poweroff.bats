#!/usr/bin/env bats
# bats file_tags=host
#
# Off-device tests for the poweroff shim protocol (bin/poweroff), ported from the old
# tests/poweroff_shim_test.sh. The shim is run on its own against a fake "real" poweroff
# and a stand-in for launch.sh (a sleeping process with its pid in the pid file). Several
# cases are timing based (they measure how long the shim waits), with a margin of a second.
#
# Env: SRC_PAK  the pak whose bin/poweroff is tested (default: the checkout)

load '../helpers/common'

setup() {
    require_tools sh sleep kill date cat cp mkdir chmod grep
    SHIM="$(psp_src_pak)/bin/poweroff"
    [ -f "$SHIM" ] || fail "no shim at $SHIM"
    T="$BATS_TEST_TMPDIR"
    PAK=""
    # A fake real poweroff that records its arguments.
    cat >"$T/fake-poweroff" <<FAKE
#!/bin/sh
echo "called \$*" >"$T/real-called"
FAKE
    chmod +x "$T/fake-poweroff"
    export PSP_POWEROFF_TMP="$T"
    export PSP_POWEROFF_REAL="$T/fake-poweroff"
    export PSP_POWEROFF_TIMEOUT=4
}

teardown() {
    [ -n "$PAK" ] && kill "$PAK" 2>/dev/null
    return 0
}

# Starts a background process standing in for launch.sh and writes its pid file.
# (3>&- keeps bats' output descriptor out of background processes, or bats would wait for them.)
start_pak() {
    sleep 30 3>&- &
    PAK=$!
    echo "$PAK" >"$T/psp-pak.pid"
}

stop_pak() {
    kill "$PAK" 2>/dev/null || true
    wait "$PAK" 2>/dev/null || true
    PAK=""
}

# Runs the shim, sets ELAPSED (whole seconds).
run_shim() {
    local start
    start=$(date +%s)
    sh "$SHIM" "$@"
    ELAPSED=$(($(date +%s) - start))
}

# assert_between <value> <min> <max> <what>
assert_between() {
    if [ "$1" -lt "$2" ] || [ "$1" -gt "$3" ]; then
        echo "$4: expected $2..$3, got $1" >&2
        return 1
    fi
}
# assert_contents_are <file> <text>: the file holds exactly this text
assert_contents_are() {
    [ "$(cat "$1" 2>/dev/null)" = "$2" ] || {
        echo "expected $1 to hold: $2 (got: $(cat "$1" 2>/dev/null))" >&2
        return 1
    }
}

@test "ok file already present: no waiting, request recorded, real poweroff gets the args" {
    start_pak
    : >"$T/psp-poweroff-ok"
    run_shim -f
    stop_pak
    assert_file_exist "$T/psp-poweroff-req"
    # the request file holds the epoch
    run grep -E '^[0-9]{9,}$' "$T/psp-poweroff-req"
    assert_success
    assert_between "$ELAPSED" 0 1 "present: no wait (${ELAPSED}s)"
    assert_contents_are "$T/real-called" "called -f"
}

@test "ok arrives after 2 s: shim waits for it, but not for the timeout" {
    start_pak
    (sleep 2 && : >"$T/psp-poweroff-ok") 3>&- &
    run_shim
    stop_pak
    wait
    assert_between "$ELAPSED" 2 3 "late: waited for ok (${ELAPSED}s)"
    assert_file_exist "$T/real-called"
}

@test "ok never arrives: bounded by the timeout, real poweroff still called" {
    start_pak
    PSP_POWEROFF_TIMEOUT=2 run_shim
    stop_pak
    assert_between "$ELAPSED" 2 3 "timeout: gave up after the timeout (${ELAPSED}s)"
    assert_file_exist "$T/real-called"
}

@test "launch.sh gone while waiting: stops early" {
    start_pak
    (sleep 1 && kill "$PAK") 3>&- &
    run_shim
    wait "$PAK" 2>/dev/null || true
    PAK=""
    wait
    assert_between "$ELAPSED" 0 3 "gone: stopped before the timeout (${ELAPSED}s)"
    assert_file_exist "$T/real-called"
}

@test "launch.sh already gone (stale pid file): no wait, no request" {
    local dead
    sleep 0 3>&- &
    dead=$!
    wait "$dead" || true
    echo "$dead" >"$T/psp-pak.pid"
    run_shim
    assert_between "$ELAPSED" 0 1 "stale pid file: no wait (${ELAPSED}s)"
    assert_file_not_exist "$T/psp-poweroff-req"
    assert_file_exist "$T/real-called"
}

@test "no pid file (no PSP running): no wait, no request" {
    run_shim
    assert_between "$ELAPSED" 0 1 "no PSP running: no wait (${ELAPSED}s)"
    assert_file_not_exist "$T/psp-poweroff-req"
    assert_file_exist "$T/real-called"
}

@test "garbage in the pid file and a non-numeric timeout do not break it" {
    echo "not a pid" >"$T/psp-pak.pid"
    PSP_POWEROFF_TIMEOUT=abc run_shim
    assert_between "$ELAPSED" 0 1 "garbage pid file: no wait (${ELAPSED}s)"
    assert_file_exist "$T/real-called"
}

@test "real poweroff and busybox missing: poweroff from PATH is used, never the shim itself" {
    local sh_bin
    sh_bin="$(command -v sh)"
    mkdir -p "$T/shimdir" "$T/other"
    cp "$SHIM" "$T/shimdir/poweroff"
    cp "$T/fake-poweroff" "$T/other/poweroff"
    # the shim's own directory is in PATH, first
    PSP_POWEROFF_REAL="$T/missing" PSP_POWEROFF_BUSYBOX="$T/missing" \
        PATH="$T/shimdir:$T/other:$PATH" "$sh_bin" "$T/shimdir/poweroff" -f || true
    assert_contents_are "$T/real-called" "called -f"
}

@test "nothing to run at all: gives up with an error instead of looping or calling itself" {
    local sh_bin
    sh_bin="$(command -v sh)"
    mkdir -p "$T/shimdir"
    cp "$SHIM" "$T/shimdir/poweroff"
    run env PSP_POWEROFF_REAL="$T/missing" PSP_POWEROFF_BUSYBOX="$T/missing" \
        PATH="$T/shimdir" "$sh_bin" "$T/shimdir/poweroff"
    assert_failure
    run grep 'no real poweroff found' "$T/psp-poweroff-shim.log"
    assert_success
}

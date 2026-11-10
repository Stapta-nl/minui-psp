#!/bin/sh
# Off-device tests for the poweroff shim protocol (bin/poweroff).
# Usage: sh tests/poweroff_shim_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="$ROOT/bin/poweroff"
WORK="$(mktemp -d)"
trap 'kill $(cat "$WORK"/sleeper.pid 2>/dev/null) 2>/dev/null; rm -rf "$WORK"' EXIT

failures=0
# check <description> <command...>: passes if the command succeeds.
check() {
    desc="$1"
    shift
    if "$@"; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc"
        failures=$((failures + 1))
    fi
}
between() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }
exists() { [ -f "$1" ]; }
absent() { [ ! -f "$1" ]; }
contents_are() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }

# Fresh /tmp stand-in and a fake real poweroff that records its arguments.
setup() {
    T="$WORK/$1"
    mkdir -p "$T"
    cat >"$T/fake-poweroff" <<FAKE
#!/bin/sh
echo "called \$*" >"$T/real-called"
FAKE
    chmod +x "$T/fake-poweroff"
    export PSP_POWEROFF_TMP="$T"
    export PSP_POWEROFF_REAL="$T/fake-poweroff"
    export PSP_POWEROFF_TIMEOUT=4
}

# Starts a background process standing in for launch.sh and writes its pid file.
start_pak() {
    sleep 30 &
    PAK=$!
    echo "$PAK" >"$T/psp-pak.pid"
    echo "$PAK" >"$WORK/sleeper.pid"
}

stop_pak() {
    kill "$PAK" 2>/dev/null
    wait "$PAK" 2>/dev/null
}

# Runs the shim, sets ELAPSED (whole seconds).
run_shim() {
    start=$(date +%s)
    sh "$SHIM" "$@"
    ELAPSED=$(($(date +%s) - start))
}

# 1. ok file already present: no waiting, request recorded, real poweroff gets the args.
setup present
start_pak
: >"$T/psp-poweroff-ok"
run_shim -f
stop_pak
check "present: request file created" exists "$T/psp-poweroff-req"
check "present: no wait (${ELAPSED}s)" between "$ELAPSED" 0 1
check "present: real poweroff called with args" contents_are "$T/real-called" "called -f"

# 2. ok arrives after 2 s: shim waits for it, but not for the timeout.
setup late
start_pak
(sleep 2 && : >"$T/psp-poweroff-ok") &
run_shim
stop_pak
wait
check "late: waited for ok (${ELAPSED}s)" between "$ELAPSED" 2 3
check "late: real poweroff called" exists "$T/real-called"

# 3. ok never arrives: bounded by the timeout, real poweroff still called.
setup timeout
start_pak
PSP_POWEROFF_TIMEOUT=2 run_shim
stop_pak
check "timeout: gave up after the timeout (${ELAPSED}s)" between "$ELAPSED" 2 3
check "timeout: real poweroff called" exists "$T/real-called"

# 4. launch.sh gone while waiting: stops early.
setup gone
start_pak
(sleep 1 && kill "$PAK") &
run_shim
wait "$PAK" 2>/dev/null
wait
check "gone: stopped before the timeout (${ELAPSED}s)" between "$ELAPSED" 0 3
check "gone: real poweroff called" exists "$T/real-called"

# 5. launch.sh already gone (stale pid file) or no pid file: no wait, no request.
setup stale
sleep 0 &
DEAD=$!
wait "$DEAD"
echo "$DEAD" >"$T/psp-pak.pid"
run_shim
check "stale pid file: no wait (${ELAPSED}s)" between "$ELAPSED" 0 1
check "stale pid file: no request" absent "$T/psp-poweroff-req"
check "stale pid file: real poweroff called" exists "$T/real-called"
setup nopid
run_shim
check "no PSP running: no wait (${ELAPSED}s)" between "$ELAPSED" 0 1
check "no PSP running: no request" absent "$T/psp-poweroff-req"
check "no PSP running: real poweroff called" exists "$T/real-called"

# 6. garbage in the pid file and a non-numeric timeout do not break it.
setup garbage
echo "not a pid" >"$T/psp-pak.pid"
PSP_POWEROFF_TIMEOUT=abc run_shim
check "garbage pid file: no wait (${ELAPSED}s)" between "$ELAPSED" 0 1
check "garbage pid file: real poweroff called" exists "$T/real-called"

# 7. Real poweroff and busybox missing: another poweroff in PATH is used, but never
# the shim itself (its own directory is in PATH, first).
setup fallback
SH="$(command -v sh)"
mkdir -p "$T/shimdir" "$T/other"
cp "$SHIM" "$T/shimdir/poweroff"
cp "$T/fake-poweroff" "$T/other/poweroff"
PSP_POWEROFF_REAL="$T/missing" PSP_POWEROFF_BUSYBOX="$T/missing" \
    PATH="$T/shimdir:$T/other:$PATH" "$SH" "$T/shimdir/poweroff" -f
check "fallback: poweroff from PATH used, shim skipped" contents_are "$T/real-called" "called -f"

# 8. Nothing to run at all: gives up with an error instead of looping or calling itself.
setup nothing
mkdir -p "$T/shimdir"
cp "$SHIM" "$T/shimdir/poweroff"
SH="$(command -v sh)"
PSP_POWEROFF_REAL="$T/missing" PSP_POWEROFF_BUSYBOX="$T/missing" \
    PATH="$T/shimdir" "$SH" "$T/shimdir/poweroff" 2>/dev/null
rc=$?
check "nothing to run: non-zero exit, no hang" test "$rc" -ne 0
check "nothing to run: logged" grep -q 'no real poweroff found' "$T/psp-poweroff-shim.log"

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "all tests passed"


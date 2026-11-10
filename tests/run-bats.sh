#!/usr/bin/env bash
# Runs the bats tests and writes everything a debug bundle needs into $RESULT_DIR.
# Runs on the host and, from the bundle `make test-bundle` makes, on the device.
#
# Usage: RESULT_DIR=<dir> run-bats.sh [bats options, e.g. --filter-tags host]
#
# Writes into $RESULT_DIR:
#   output.tap  the TAP stream (also printed)   stderr.log  bats' stderr
#   junit/      the JUnit XML (report.xml)       logs/       per-case logs, screenshots ($OUT_DIR)
#   exit-code   bats' exit status
#   device/     the device collectors' output (only with DEVICE_COLLECT=1)
# Exits with bats' status.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
: "${RESULT_DIR:?RESULT_DIR must be set}"
BATS=tests/lib/bats-core/bin/bats
[ -x "$BATS" ] || {
    echo "run-bats.sh: $BATS not found (make tests/lib/bats-core/bin/bats)" >&2
    exit 2
}

mkdir -p "$RESULT_DIR/junit" "$RESULT_DIR/logs"

# bats needs nl, which some device firmwares (e.g. TinaLinux on the tg5040) lack.
# Stand in with awk, which bats needs anyway; only used where nl is missing.
if ! command -v nl >/dev/null 2>&1; then
    shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/bats-shim.XXXXXX")" || exit 2
    trap 'rm -rf "$shim_dir"' EXIT
    cat >"$shim_dir/nl" <<'SHIM'
#!/bin/sh
exec awk '{ printf "%6d\t%s\n", NR, $0 }' "$@"
SHIM
    chmod +x "$shim_dir/nl"
    export PATH="$shim_dir:$PATH"
    echo "run-bats.sh: nl not found, using an awk stand-in" >&2
fi
user_out_dir="${OUT_DIR:-}"
export OUT_DIR="${OUT_DIR:-$RESULT_DIR/logs}"
mkdir -p "$OUT_DIR"

"$BATS" --formatter tap --report-formatter junit --output "$RESULT_DIR/junit" "$@" tests/bats \
    2>"$RESULT_DIR/stderr.log" | tee "$RESULT_DIR/output.tap"
rc=${PIPESTATUS[0]}
cat "$RESULT_DIR/stderr.log" >&2
echo "$rc" >"$RESULT_DIR/exit-code"

# A custom OUT_DIR: bring its files into the result dir as well.
if [ -n "$user_out_dir" ] && [ "$user_out_dir" != "$RESULT_DIR/logs" ]; then
    cp -R "$user_out_dir/." "$RESULT_DIR/logs/" 2>/dev/null
fi

if [ -n "${DEVICE_COLLECT:-}" ]; then
    sh tests/collect.sh tests/collectors/device.list "$RESULT_DIR/device"
fi
exit "$rc"

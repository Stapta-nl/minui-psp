#!/usr/bin/env bash
# Completes the debug bundle of a run and packs it:  dist/test-report-<target>-<timestamp>.tar.gz
# It is written whether the tests passed or failed.
#
# Usage: bundle.sh <target> <exit status>
#   <target>  "host" or a platform name; the run's files are in dist/test-out/<target>/
# Environment: TEST_STARTED, TEST_FINISHED, MAKE_VARS, TEST_TARGET_INFO (see collectors/host.list)
#
# An interrupted run (run-host.sh, run-device.sh) leaves interrupted.txt in the stage dir;
# the summary then says INTERRUPTED.
#
# Adds host/ (collectors/host.list) and summary.md to dist/test-out/<target>/. The summary is
# also what CI appends to the job summary. A device's address is never written to the bundle.

target="$1"
status="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
stage="dist/test-out/$target"
mkdir -p "$stage"

sh tests/collect.sh tests/collectors/host.list "$stage/host"

tap="$stage/output.tap"
passed=0 failed=0 skipped=0
if [ -f "$tap" ]; then
    passed="$(grep -c '^ok .*' "$tap" | tr -d ' ')"
    skipped="$(grep -c '^ok .* # skip' "$tap" | tr -d ' ')"
    failed="$(grep -c '^not ok ' "$tap" | tr -d ' ')"
    passed=$((passed - skipped))
fi
if [ -s "$stage/interrupted.txt" ]; then
    verdict="INTERRUPTED"
elif [ "$status" = 0 ]; then
    verdict="PASSED"
else
    verdict="FAILED"
fi
sha="$(head -n 1 "$stage/host/git-sha.txt" 2>/dev/null)"
dirty=""
[ -s "$stage/host/git-dirty.txt" ] && dirty=" (uncommitted changes)"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
bundle="dist/test-report-$target-$ts.tar.gz"

{
    echo "## Tests $verdict: $target"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Target | $target |"
    echo "| Platform | ${PLATFORM:-$(jq -r '.platforms[0]' pak.json 2>/dev/null) (default)} |"
    echo "| Result | $passed passed, $failed failed, $skipped skipped |"
    echo "| Exit status | $status |"
    [ -s "$stage/interrupted.txt" ] && echo "| Interrupted by | $(head -n 1 "$stage/interrupted.txt") |"
    echo "| Commit | ${sha:-unknown}$dirty |"
    echo "| Started | ${TEST_STARTED:-unknown} |"
    echo "| Finished | ${TEST_FINISHED:-unknown} |"
    echo "| Debug bundle | \`$(basename "$bundle")\` |"
    if [ -s "$stage/error.txt" ]; then
        echo
        echo "### Error"
        echo
        echo '```'
        cat "$stage/error.txt"
        echo '```'
    elif [ ! -f "$tap" ]; then
        echo
        echo "No test results were produced."
    fi
    if [ "$failed" -gt 0 ]; then
        echo
        echo "### Failed tests"
        echo
        # each failed test with the diagnostics bats printed (lines starting with "# ")
        awk '
            function close_block() { if (open) print "  ```"; open = 0 }
            /^not ok / {
                close_block()
                name = $0
                sub(/^not ok [0-9]+ /, "", name)
                sub(/ # in [0-9]+ ms$/, "", name)
                print "- `" name "`"
                print ""
                print "  ```"
                open = 1
                next
            }
            /^(ok |1\.\.)/ { close_block(); next }
            open && /^# / { line = $0; sub(/^# /, "", line); print "  " line }
            END { close_block() }
        ' "$tap"
    fi
    # bats' own errors (e.g. a missing tool) explain a failed run without failed tests.
    if [ "$status" != 0 ] && [ "$failed" = 0 ] && [ -s "$stage/stderr.log" ]; then
        echo
        echo "### Error output (last 20 lines of stderr.log)"
        echo
        echo '```'
        tail -n 20 "$stage/stderr.log"
        echo '```'
    fi
    if [ -s "$stage/host/collector-errors.txt" ] || [ -s "$stage/device/collector-errors.txt" ]; then
        echo
        echo "### Collectors that failed (the bundle is complete otherwise)"
        echo
        echo '```'
        cat "$stage/host/collector-errors.txt" "$stage/device/collector-errors.txt" 2>/dev/null
        echo '```'
    fi
} >"$stage/summary.md"

# Written under a temporary name, so an interrupt never leaves a truncated bundle behind.
if ! tar -czf "$bundle.part" -C dist/test-out "$target" || ! mv "$bundle.part" "$bundle"; then
    rm -f "$bundle.part"
    exit 2
fi
echo "debug bundle: $bundle"
echo "summary:      $stage/summary.md"

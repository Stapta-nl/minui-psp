#!/usr/bin/env bash
# `make test`: the tests tagged "host" on this machine. Never uses ssh.
# Writes dist/test-out/host/ and the debug bundle dist/test-report-host-<timestamp>.tar.gz.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
rm -rf dist/test-out/host
mkdir -p dist/test-out/host
TEST_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TEST_STARTED

RESULT_DIR="$ROOT/dist/test-out/host" bash tests/run-bats.sh --filter-tags host
rc=$?

TEST_FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TEST_FINISHED
bash tests/bundle.sh host "$rc"
exit "$rc"

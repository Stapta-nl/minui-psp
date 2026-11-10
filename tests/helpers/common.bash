# shellcheck shell=bash
# Shared helpers for the bats tests. Load it from a .bats file with: load '../helpers/common'
#
# It loads bats-support, bats-assert and bats-file (downloaded into tests/lib by the
# Makefile) and defines the settings every test file shares. Runs on the host and, with
# the bundle from `make test-bundle`, on the device (bash is all it needs).

TESTS_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck disable=SC2034 # used by the test files
FIX="$TESTS_DIR/fixtures"

load "$TESTS_DIR/lib/bats-support/load.bash"
load "$TESTS_DIR/lib/bats-assert/load.bash"
load "$TESTS_DIR/lib/bats-file/load.bash"

# Where per-case logs, screenshots and kept files go (the debug bundle picks them up).
# Each test file wipes and uses its own subdirectory.
OUT_DIR="${OUT_DIR:-/tmp/psp-test-out}"

# The platform under test: $PLATFORM, or the first platform in pak.json (host runs).
psp_platform() {
    if [ -n "${PLATFORM:-}" ]; then
        printf '%s' "$PLATFORM"
    else
        jq -r '.platforms[0]' "$REPO_DIR/pak.json"
    fi
}

# The pak under test: $SRC_PAK (an unpacked release in CI, the installed pak on a device),
# else the repository checkout.
psp_src_pak() {
    printf '%s' "${SRC_PAK:-$REPO_DIR}"
}

# require_tools <tool...>: fails naming every tool that is missing. The device's BusyBox is
# small, so say clearly what is missing instead of failing oddly later.
require_tools() {
    local missing="" tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        fail "missing tools on this system:$missing"
    fi
}

# Writes a note into the test output (shown by bats for passing tests too).
info() { echo "# $*" >&3; }

# --- assertions on files (thin wrappers that print what went wrong) -----------------------
# assert_grep <file> <regex>: the file has a line matching the regex.
assert_grep() {
    grep -q -- "$2" "$1" || {
        echo "expected $1 to match: $2" >&2
        return 1
    }
}
# refute_grep <file> <regex>: no line matches.
refute_grep() {
    if grep -q -- "$2" "$1"; then
        echo "expected $1 not to match: $2" >&2
        return 1
    fi
}
# assert_same <file> <file>: identical bytes.
assert_same() {
    cmp -s "$1" "$2" || {
        echo "files differ: $1 $2" >&2
        return 1
    }
}
assert_differ() {
    if cmp -s "$1" "$2"; then
        echo "files are identical: $1 $2" >&2
        return 1
    fi
}

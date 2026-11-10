#!/usr/bin/env bats
# bats file_tags=host,device
#
# RetroAchievements sync of launch.sh. The 18 cases live in tests/ra.sh, a POSIX sh script
# that CI also runs under BusyBox (see .github/workflows/ci.yaml), so it stays a script;
# this wrapper makes it part of `make test` and of the on-device run (where it runs under
# the device's own sh). Its PASS/FAIL lines are in the test output on failure.
#
# Env overrides: SRC_PAK, PAK_NAME, PLATFORM, OUT_DIR (this file uses OUT_DIR/ra), KEEP, LAUNCH_SHELL, TMP_ROOT.

load '../helpers/common'

@test "RetroAchievements sync: all cases of tests/ra.sh pass" {
    export SRC_PAK
    SRC_PAK="$(psp_src_pak)"
    export PAK_NAME
    PAK_NAME="$(psp_pak_name)"
    export PLATFORM
    PLATFORM="$(psp_platform)"
    export OUT_DIR="$OUT_DIR/ra"
    mkdir -p "$OUT_DIR"
    run sh "$TESTS_DIR/ra.sh"
    printf '%s\n' "$output" >"$OUT_DIR/console.txt"
    info "$(printf '%s\n' "$output" | tail -n 1)"
    assert_success
}

#!/usr/bin/env bats
# bats file_tags=host
# shellcheck disable=SC2016,SC2030,SC2031 # bats runs every test in a subshell
#
# Off-device tests of "which pak is under test": tests/collectors/pak-files.sh (what the device
# lists), tests/pakcheck.sh (the comparison with the checkout or an unpacked release) and the
# line in summary.md (tests/bundle.sh). The device is a throw-away directory.

load '../helpers/common'

setup() {
    require_tools sh bash jq awk sed grep cut sort git
    T="$BATS_TEST_TMPDIR"
    REL="$T/release" DEV="$T/device.pak"
    mkdir -p "$REL/bin" "$REL/scripts" "$REL/PPSSPP/assets" "$REL/PPSSPP/.config/ppsspp/PSP/SYSTEM"
    printf '#!/bin/sh\necho launch\n' >"$REL/launch.sh"
    printf '#!/bin/sh\necho poweroff\n' >"$REL/bin/poweroff"
    printf 'ini\n' >"$REL/scripts/ini.sh"
    printf 'font' >"$REL/PPSSPP/assets/font.ttf"
    printf 'ELF\0v1.20.3-5-gabcdef0\0rest' >"$REL/PPSSPP/PPSSPPSDL_tg5040"
    printf 'default ini' >"$REL/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    printf 'default controls' >"$REL/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    jq -n '{name:"PSP", version:"6.2.0", update_ignore:["PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini","PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"]}' >"$REL/pak.json"
    cp -R "$REL" "$DEV"
}

# list_device: what the device's collector prints for $DEV
list_device() { sh "$TESTS_DIR/collectors/pak-files.sh" "$DEV" tg5040 >"$T/files.txt"; }
check() { bash "$TESTS_DIR/pakcheck.sh" "$T/files.txt" "${1:-$REL}"; }

@test "collector: header (algorithm, pak.json version, PPSSPP build text), checksums, no user data" {
    mkdir -p "$DEV/PPSSPP/.config/ppsspp/PSP/SAVEDATA"
    printf 'save' >"$DEV/PPSSPP/.config/ppsspp/PSP/SAVEDATA/x.bin"
    list_device
    assert_grep "$T/files.txt" '^# algo: '
    assert_grep "$T/files.txt" '^# pak.json version: 6.2.0$'
    assert_grep "$T/files.txt" '^# ppsspp build: v1.20.3-5-gabcdef0$'
    assert_grep "$T/files.txt" '  launch.sh$'
    assert_grep "$T/files.txt" '  PPSSPP/PPSSPPSDL_tg5040$'
    refute_grep "$T/files.txt" 'SAVEDATA'
    refute_grep "$T/files.txt" 'ppsspp.ini'
}

@test "collector: never runs the emulator binary" {
    printf '#!/bin/sh\ntouch "%s/ran"\n' "$T" >"$DEV/PPSSPP/PPSSPPSDL_tg5040"
    chmod +x "$DEV/PPSSPP/PPSSPPSDL_tg5040"
    list_device
    assert_file_not_exist "$T/ran"
}

@test "collector: a missing pak is an error line and a failure" {
    run sh "$TESTS_DIR/collectors/pak-files.sh" "$T/none" tg5040
    assert_failure
    assert_output --partial "# error: no pak at"
}

@test "match: the same files, and the user's settings differing, is a match" {
    printf 'my own settings and hotkeys' >"$DEV/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    printf 'my hotkeys' >"$DEV/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    mkdir -p "$DEV/PPSSPP/.config/ppsspp/PSP/SAVEDATA"
    printf 'save' >"$DEV/PPSSPP/.config/ppsspp/PSP/SAVEDATA/x.bin"
    list_device
    run check
    assert_success
    assert_output --partial "Pak under test: matches the release in $REL"
    assert_output --partial "PPSSPP build text in the binary: v1.20.3-5-gabcdef0"
    refute_output --partial WARNING
}

@test "mismatch: a changed file, a missing file and an extra file are each named; it is a warning status 1" {
    printf '#!/bin/sh\necho OLD launch\n' >"$DEV/launch.sh"
    rm "$DEV/scripts/ini.sh"
    printf 'x' >"$DEV/bin/leftover"
    list_device
    run check
    assert_failure 1
    assert_output --partial "WARNING: the pak installed on the device is NOT the one under test"
    assert_output --partial "differs from the release in $REL: launch.sh"
    assert_output --partial "missing on the device: scripts/ini.sh"
    assert_output --partial "leftover file on the device, not part of this release (harmless unless the pak loads it): bin/leftover"
    refute_output --partial "extra on the device"
    refute_output --partial "bin/poweroff"
    assert_output --partial "pak.json version on the device: 6.2.0"
}

@test "mismatch: a different PPSSPP binary is found by its checksum" {
    printf 'ELF\0v1.19.0\0old' >"$DEV/PPSSPP/PPSSPPSDL_tg5040"
    list_device
    run check
    assert_failure 1
    assert_output --partial "differs from the release in $REL: PPSSPP/PPSSPPSDL_tg5040 (build text on the device: v1.19.0; in the release in $REL: v1.20.3-5-gabcdef0)"
    assert_output --partial "PPSSPP build text on the device: v1.19.0"
}

@test "a build output that differs is a note, not a warning, and the 'matches' text stays accurate" {
    local co="$T/checkout"
    mkdir -p "$co"
    cp -R "$REL/." "$co/"
    printf 'PPSSPP/PPSSPPSDL_tg5040\nbin/jpg2bmp\n' >"$co/.gitarchiveinclude"
    printf 'built here' >"$co/bin/jpg2bmp"
    git -C "$co" init -q
    git -C "$co" add -A
    printf 'built elsewhere' >"$DEV/bin/jpg2bmp"
    printf 'ELF\0v1.19.0\0old' >"$DEV/PPSSPP/PPSSPPSDL_tg5040"
    list_device
    run check "$co"
    assert_success
    refute_output --partial WARNING
    assert_output --partial "note: differs from the release in $co; build output, may be a different build: bin/jpg2bmp"
    assert_output --partial "build output, may be a different build: PPSSPP/PPSSPPSDL_tg5040"
    assert_output --partial "2 build outputs differ"
    # a tracked file that differs is still the warning
    printf 'old' >"$DEV/launch.sh"
    list_device
    run check "$co"
    assert_failure 1
    assert_output --partial "differs from the release in $co: launch.sh"
}

@test "a checkout: the PPSSPP binary that was not built here is 'not compared', never a mismatch" {
    local co="$T/checkout"
    mkdir -p "$co"
    cp -R "$REL/." "$co/"
    rm "$co/PPSSPP/PPSSPPSDL_tg5040"
    mkdir -p "$co/tests" "$co/src"
    printf 'x' >"$co/tests/foo"
    printf 'x' >"$co/Makefile"
    printf 'PPSSPP/PPSSPPSDL_tg5040\n' >"$co/.gitarchiveinclude"
    git -C "$co" init -q
    git -C "$co" add -A
    list_device
    run check "$co"
    assert_success
    assert_output --partial "1 not compared"
    assert_output --partial "not compared (binary comes from a release download, none in the release in $co): PPSSPP/PPSSPPSDL_tg5040 (build text on the device: v1.20.3-5-gabcdef0; in the release in $co: not available)"
    # ... and a file that only the checkout's tests/ or Makefile has is not "missing on the device"
    refute_output --partial "Makefile"
    refute_output --partial "tests/foo"
}

@test "a checkout whose built binary exists locally is compared (a difference is a note, a missing one a warning)" {
    local co="$T/checkout"
    mkdir -p "$co"
    cp -R "$REL/." "$co/"
    printf 'PPSSPP/PPSSPPSDL_tg5040\n' >"$co/.gitarchiveinclude"
    git -C "$co" init -q
    git -C "$co" add -A
    printf 'ELF\0v1.19.0\0old' >"$DEV/PPSSPP/PPSSPPSDL_tg5040"
    list_device
    run check "$co"
    assert_success # a build output: only a note
    assert_output --partial "build output, may be a different build: PPSSPP/PPSSPPSDL_tg5040 (build text on the device: v1.19.0; in the release in $co: v1.20.3-5-gabcdef0)"
    rm "$DEV/PPSSPP/PPSSPPSDL_tg5040" # a MISSING build output is still a warning
    list_device
    run check "$co"
    assert_failure 1
    assert_output --partial "missing on the device: PPSSPP/PPSSPPSDL_tg5040"
}

@test "extra files alone are a note, not a warning: the verdict is a match with a leftover count, status 0" {
    mkdir -p "$DEV/tests/device/fixtures"
    printf 'x' >"$DEV/tests/device/e2e.sh"
    printf 'x' >"$DEV/tests/device/fixtures/thumb1.jpg"
    printf 'old binary' >"$DEV/PPSSPP/PPSSPPSDL_tg5040.orig"
    list_device
    run check
    assert_success
    assert_output --partial "Pak under test: matches the release in $REL"
    assert_output --partial "3 leftover files, see pak/check.txt"
    assert_output --partial "leftover file on the device, not part of this release (harmless unless the pak loads it): tests/device/e2e.sh"
    refute_output --partial WARNING
    refute_output --partial "NOT the one"
    # with a real difference, the extras are still only notes
    printf 'old' >"$DEV/launch.sh"
    list_device
    run check
    assert_failure 1
    assert_output --partial "differs from the release in $REL: launch.sh"
    assert_output --partial "leftover file on the device"
}

@test "collector: PPSSPP's own version string is found among decoys (v1.1, zlib's v1.2.11) and an unreliable find is 'unknown'" {
    local b="$DEV/PPSSPP/PPSSPPSDL_tg5040"
    printf 'ELF\0libfoo v1.1\0v1.1\0libz v1.2.11 text\0v1.2.11\0\0v1.20.3\0PPSSPP %%s\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "v1.20.3 (also found: v1.2.11)"
    # a describe string with commits since the tag wins over any plain tag-like text
    printf 'ELF\0v1.2.11\0v1.20.3-14-g0123abc\0v1.19.0\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "v1.20.3-14-g0123abc (also found: v1.2.11 v1.19.0)"
    # only decoys of the wrong shape: unknown, never the first v1.x text
    printf 'ELF\0v1.1\0see v1.2.11 here\0v1.2\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "unknown"
    list_device
    assert_grep "$T/files.txt" '^# ppsspp build: unknown$'
    assert_grep "$T/files.txt" '^# ppsspp build of PPSSPP/PPSSPPSDL_tg5040: unknown$'
}

@test "collector: a build of a fork or a modified tree (v1.20.3-5-gHASH-dirty, v1.20.3-saveonexit) is found; text inside another string is only approximate" {
    local b="$DEV/PPSSPP/PPSSPPSDL_tg5040"
    printf 'ELF\0libz v1.2.11 x\0v1.2.11\0v1.20.3-5-gabc1234-dirty\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "v1.20.3-5-gabc1234-dirty (also found: v1.2.11)"
    printf 'ELF\0v1.20.3-saveonexit\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "v1.20.3-saveonexit"
    printf 'ELF\0v1.1\0see PPSSPP v1.20.3-7-gdeadbee here\0' >"$b"
    run sh "$TESTS_DIR/collectors/pak-files.sh" --build "$b"
    assert_output "~v1.20.3-7-gdeadbee"
}

@test "an identical PPSSPP binary is said to be identical, with the build text, whatever the device's grep found" {
    local co="$T/checkout"
    mkdir -p "$co"
    cp -R "$REL/." "$co/"
    printf 'PPSSPP/PPSSPPSDL_tg5040\n' >"$co/.gitarchiveinclude"
    git -C "$co" init -q
    git -C "$co" add -A
    printf 'ELF\0v1.20.3-5-gabcdef0\0rest' >"$co/PPSSPP/PPSSPPSDL_tg5040"
    cp "$co/PPSSPP/PPSSPPSDL_tg5040" "$DEV/PPSSPP/PPSSPPSDL_tg5040"
    list_device
    sed -i 's|^# ppsspp build of PPSSPP/PPSSPPSDL_tg5040: .*|# ppsspp build of PPSSPP/PPSSPPSDL_tg5040: unknown|' "$T/files.txt"
    run check "$co"
    assert_success
    assert_output --partial "identical to the release in $co: PPSSPP/PPSSPPSDL_tg5040 (build text on the device: unknown; in the release in $co: v1.20.3-5-gabcdef0)"
}

@test "collector: the build text of every PPSSPP binary in the pak is listed" {
    printf 'ELF\0v1.20.3\0' >"$DEV/PPSSPP/PPSSPPSDL_tg5050"
    list_device
    assert_grep "$T/files.txt" '^# ppsspp build of PPSSPP/PPSSPPSDL_tg5050: v1.20.3$'
    assert_grep "$T/files.txt" '^# ppsspp build of PPSSPP/PPSSPPSDL_tg5040: v1.20.3-5-gabcdef0$'
}

@test "an unusable list is status 2, not a verdict" {
    : >"$T/files.txt"
    run bash "$TESTS_DIR/pakcheck.sh" "$T/files.txt" "$REL"
    assert_failure 2
    printf '# algo: bogus\n' >"$T/files.txt"
    run bash "$TESTS_DIR/pakcheck.sh" "$T/files.txt" "$REL"
    assert_failure 2
}

@test "summary.md: a match is one line in the table, a mismatch is a prominent WARNING section" {
    local target="unit-pak-$$" stage
    stage="$REPO_DIR/dist/test-out/$target"
    mkdir -p "$stage/pak"
    echo "Pak under test: matches this checkout (3 files compared; user settings ignored)" >"$stage/pak/check.txt"
    (cd "$REPO_DIR" && bash tests/bundle.sh "$target" 0 >/dev/null 2>&1)
    assert_grep "$stage/summary.md" '^| Pak under test | matches this checkout'
    refute_grep "$stage/summary.md" 'WARNING'
    printf 'WARNING: the pak installed on the device is NOT the one under test (this checkout).\n  differs from this checkout: launch.sh\n' >"$stage/pak/check.txt"
    (cd "$REPO_DIR" && bash tests/bundle.sh "$target" 0 >/dev/null 2>&1)
    assert_grep "$stage/summary.md" '^### WARNING: the pak on the device is not the pak under test'
    assert_grep "$stage/summary.md" 'differs from this checkout: launch.sh'
    assert_grep "$stage/summary.md" '^| Pak under test | WARNING'
    rm -rf "$stage" "$REPO_DIR"/dist/test-report-"$target"-*.tar.gz
}

@test "run-device.sh: the list is not redacted, the collector's stderr is separate, the status and the algo line are checked" {
    local f="$TESTS_DIR/run-device.sh" blk
    blk="$(sed -n '/checking which pak is installed/,/running the device tests/p' "$f")"
    [[ "$blk" == *'>"$stage/pak/files.txt" 2>"$stage/pak/collector-stderr.txt"'* ]]
    [[ "$blk" != *'redact >"$stage/pak/files.txt"'* ]]
    [[ "$blk" == *'collect_rc=$?'* ]]
    [[ "$blk" == *"grep -q '^# algo: '"* ]]
    [[ "$blk" == *"Nothing was compared"* ]]
}

@test "pakcheck: a list without the algo line is status 2, no extra-file list" {
    printf 'abc  launch.sh\n' >"$T/files.txt"
    run bash "$TESTS_DIR/pakcheck.sh" "$T/files.txt" "$REL"
    assert_failure 2
    refute_output --partial "extra on the device"
}

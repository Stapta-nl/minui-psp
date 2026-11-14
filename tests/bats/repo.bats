#!/usr/bin/env bats
# bats file_tags=host
#
# Repository and release checks (host only): shellcheck, release contents, and that the
# device settings example matches the platforms in pak.json.
#
# Env: SRC_PAK     the pak to check (an unpacked release in CI; default: the checkout)
#      RELEASE_ZIP the release archive (CI); default: what `git archive HEAD` would ship
#      JPG2BMP     jpg2bmp to check instead of $SRC_PAK/bin/jpg2bmp

load '../helpers/common'

REQUIRED_FILES="launch.sh scripts/ini.sh scripts/set_ini_values.awk scripts/retroachievements.sh pak.json bin/jpg2bmp bin/poweroff"

@test "shellcheck passes on all shell scripts and bats files" {
    require_tools shellcheck
    cd "$REPO_DIR"
    run shellcheck -x launch.sh scripts/*.sh tests/*.sh tests/helpers/*.bash tests/bats/*.bats
    assert_success
}

@test "release contains the files launch.sh needs" {
    local f pak
    pak="$(psp_src_pak)"
    for f in $REQUIRED_FILES; do
        [ -f "$pak/$f" ] || {
            echo "missing from release: $f" >&2
            return 1
        }
    done
    if [ -n "${RELEASE_ZIP:-}" ]; then
        require_tools unzip
        for f in $REQUIRED_FILES; do
            unzip -l "$RELEASE_ZIP" | grep -q " $f$" || {
                echo "missing from $RELEASE_ZIP: $f" >&2
                return 1
            }
        done
    fi
}

@test "bin/poweroff is executable in the release" {
    [ -x "$(psp_src_pak)/bin/poweroff" ]
    if [ -n "${RELEASE_ZIP:-}" ]; then
        require_tools unzip
        run unzip -Z -l "$RELEASE_ZIP" bin/poweroff
        assert_success
        # the zip keeps the unix mode: -rwxr-xr-x
        assert_output --partial "-rwx"
    fi
}

@test "bin/jpg2bmp is an aarch64 binary" {
    require_tools file
    run file "${JPG2BMP:-$(psp_src_pak)/bin/jpg2bmp}"
    assert_success
    assert_output --partial "ARM aarch64"
}

@test "src/ and tests/ do not leak into the release" {
    local listing
    if [ -n "${RELEASE_ZIP:-}" ]; then
        require_tools unzip
        listing="$(unzip -l "$RELEASE_ZIP")"
    else
        require_tools git tar
        listing="$(git -C "$REPO_DIR" archive HEAD | tar -t)"
    fi
    if printf '%s\n' "$listing" | grep -qE '(^| )(src|tests)/'; then
        echo "src/ or tests/ leaked into the release" >&2
        return 1
    fi
}

# --- device settings ----------------------------------------------------------------------
# platforms (lower case) from pak.json, one per line
pak_platforms() { jq -r '.platforms[]' "$REPO_DIR/pak.json" | sort; }
# the <PLATFORM> part of every <PLATFORM>_<what> line of the example file, lower case
example_platforms() { # example_platforms <HOST|SSH_OPTS>
    sed -n "s/^[[:space:]]*#\{0,1\}[[:space:]]*\([A-Z0-9]*\)_$1[[:space:]]*?=.*/\1/p" "$REPO_DIR/tests/devices.env.example" |
        tr '[:upper:]' '[:lower:]' | sort
}

@test "tests/devices.env.example lists exactly the platforms in pak.json" {
    run pak_platforms
    assert_success
    [ -n "$output" ]
    local expected="$output"
    run example_platforms HOST
    assert_output "$expected"
    run example_platforms SSH_OPTS
    assert_output "$expected"
}

@test "tests/devices.env is git-ignored" {
    require_tools git
    run git -C "$REPO_DIR" check-ignore -q tests/devices.env
    assert_success
}

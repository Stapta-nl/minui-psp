# shellcheck shell=bash
# Helpers for tests/bats/ra.bats: a throw-away SD card tree with a stub PPSSPP in which the
# real launch.sh runs, and what the stub saw at start-up. Load it after helpers/common.
#
# ra_setup builds a fresh sandbox (call it from setup), ra_teardown removes it. A NextUI-style
# minuisettings.txt is put in $SHARED_USERDATA_PATH and the stub records what PPSSPP would see:
# the [Achievements] section of ppsspp.ini, the token file PPSSPP reads
# (SYSTEM/ppsspp_retroachievements.dat) and the inodes of both (to prove nothing is rewritten
# needlessly). Nothing under the real SD card is touched.
#
# Only launch.sh runs under $LAUNCH_SHELL (default sh; e.g. "busybox sh"); the test code is bash.
# Env: SRC_PAK, PAK_NAME, PLATFORM, OUT_DIR (logs go to $OUT_DIR/ra), TMP_ROOT (where the
# sandbox is made, default /tmp; e.g. /mnt/SDCARD to test on FAT), LAUNCH_SHELL, KEEP=1.

# Secrets: they must reach the token file and nothing else (no log, no ini).
RA_TOKEN="tok3nS3cr3tA1b2C3d4"
RA_PASSWORD="pa55S3cr3tZ9y8"
# shellcheck disable=SC2034 # used by the tests
CR="$(printf '\r')"

# Section-aware ini filter, written to $SECTION_AWK. Headers are read the way
# scripts/set_ini_values.awk reads them (CR, a BOM before the first header, blanks
# around the brackets), so no check depends on where a section or a key is in the file.
#   mode=in    print the lines of section s, header included (CR kept)
#   mode=out   print every other line
#   mode=host  replace the AchievementsHost lines of section s by one "AchievementsHost = h",
#              right after the header
ra_section_program() {
    cat <<'AWK'
{
    l = $0
    sub(/\r$/, "", l)
    if (NR == 1 && index(l, "[") > 1 && index(l, "[") <= 4)
        l = substr(l, index(l, "["))
}
l ~ /^[ \t]*\[.*\][ \t]*$/ {
    name = l
    gsub(/^[ \t]*\[|\][ \t]*$/, "", name)
    on = (name == s)
    if (mode == "host") {
        print
        if (on)
            print "AchievementsHost = " h
        next
    }
}
mode == "in" && on
mode == "out" && !on
mode == "host" && !(on && l ~ /^[ \t]*AchievementsHost[ \t]*=/)
AWK
}

ra_setup() {
    require_tools mktemp cp mv rm mkdir cmp grep head tr sed cat awk ls wc find touch chmod cut

    PLATFORM="$(psp_platform)"
    SRC_PAK="$(psp_src_pak)"
    LAUNCH_SHELL="${LAUNCH_SHELL:-sh}"
    OUT="$OUT_DIR/ra"
    mkdir -p "$OUT"
    T="$(mktemp -d "${TMP_ROOT:-/tmp}/psp-ra-test.XXXXXX")" || fail "cannot create a temp dir"

    SD="$T/sd"
    PAK="$SD/Emus/$PLATFORM/$(psp_pak_name).pak"
    USERDATA="$SD/.userdata/$PLATFORM"
    SHARED="$SD/.userdata/shared"
    LOGS="$USERDATA/logs"
    ROMDIR="$SD/Roms/PlayStation Portable (PSP)"
    FLAGS="$USERDATA/PSP-ppsspp"
    STUB="$T/stub"
    SYSDIR="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM"
    INI="$SYSDIR/ppsspp.ini"
    TOKEN="$SYSDIR/ppsspp_retroachievements.dat"
    SETTINGS="$SHARED/minuisettings.txt"
    SECTION_AWK="$T/section.awk"
    RUN_N=0

    mkdir -p "$PAK/bin" "$SYSDIR" "$LOGS" "$ROMDIR" "$FLAGS" "$SHARED" "$STUB"
    cp "$SRC_PAK/launch.sh" "$SRC_PAK/pak.json" "$PAK/"
    cp -R "$SRC_PAK/scripts" "$PAK/"
    cp "$SRC_PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" "$T/shipped.ini"
    ra_section_program >"$SECTION_AWK"
    local b
    for b in minui-power-control setalpha show_message jpg2bmp; do
        printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/$b"
    done

    # Fake PPSSPP: records what the real one would read at start-up, then exits.
    cat >"$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" <<'EOF2'
#!/bin/sh
printf '%s\n' "$@" >"$STUB/args"
awk -v mode=in -v s=Achievements -f "$SECTION_AWK" "$INI" >"$STUB/ach.ini"
ls -i "$INI" | awk '{ print $1 }' >"$STUB/ini.inode"
rm -f "$STUB/token"
if [ -f "$TOKEN" ]; then
    cp "$TOKEN" "$STUB/token"
    ls -i "$TOKEN" | awk '{ print $1 }' >"$STUB/token.inode"
    ls -l "$TOKEN" | cut -c1-10 >"$STUB/token.mode"
else
    echo none >"$STUB/token.inode"
fi
EOF2
    chmod +x "$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" "$PAK/bin/"*
    printf 'g' >"$ROMDIR/Game.iso"

    export PLATFORM DEVICE=brick SDCARD_PATH="$SD" USERDATA_PATH="$USERDATA" LOGS_PATH="$LOGS" \
        SHARED_USERDATA_PATH="$SHARED" ROMS_PATH="$SD/Roms" STUB INI TOKEN SECTION_AWK

    # Does this filesystem keep Unix permissions? (FAT does not.)
    touch "$T/perm" && chmod 600 "$T/perm"
    PERMS_WORK=0
    # shellcheck disable=SC2012 # BusyBox has no stat -c; the file name is our own
    # shellcheck disable=SC2034 # used by the tests
    [ "$(ls -l "$T/perm" | cut -c1-10)" = "-rw-------" ] && PERMS_WORK=1
    return 0
}

# Keeps the stub's files and the ini when the test failed (or with KEEP=1) and removes the sandbox.
ra_teardown() {
    [ -n "${T:-}" ] || return 0
    if [ -n "${KEEP:-}" ] || [ -z "${BATS_TEST_COMPLETED:-}" ]; then
        mkdir -p "$OUT/$BATS_TEST_NUMBER.files"
        cp -R "$STUB" "$OUT/$BATS_TEST_NUMBER.files/stub" 2>/dev/null
        cp "$INI" "$OUT/$BATS_TEST_NUMBER.files/ppsspp.ini" 2>/dev/null
    fi
    if [ -n "${KEEP:-}" ]; then
        echo "# sandbox kept in $T" >&3
    else
        rm -rf "$T"
    fi
    return 0
}

# ra_section <in|out> <name> <file>
ra_section() { awk -v mode="$1" -v s="$2" -f "$SECTION_AWK" "$3"; }
# Prints the [Achievements] section of ini $1 (CR kept, so CRLF can be checked).
ach_section() { ra_section in Achievements "$1"; }

# fresh: shipped ini, no token, no flags, no settings.
fresh() {
    cp "$T/shipped.ini" "$INI"
    rm -f "$TOKEN" "$SETTINGS" "$FLAGS/no-ra-sync" "$FLAGS/no-config-changes" "$FLAGS/debug"
}

# settings [key=value ...]: a NextUI-style minuisettings.txt (as NextUI's CFG_sync writes
# it), logged in with hardcore off; arguments override or add lines (later lines win,
# like NextUI's parser). "-raEnable" drops that key.
settings() {
    {
        echo "font=1"
        echo "radius=20"
        echo "raEnable=1"
        echo "raUsername=Player1"
        echo "raPassword=$RA_PASSWORD"
        echo "raHardcoreMode=0"
        echo "raToken=$RA_TOKEN"
        echo "raServerUsername=Player1"
        echo "raAuthenticated=1"
        echo "raShowNotifications=1"
        local kv
        for kv in "$@"; do
            case "$kv" in -*) ;; *) printf '%s\n' "$kv" ;; esac
        done
    } >"$SETTINGS.new"
    local kv
    for kv in "$@"; do
        case "$kv" in
        -*)
            grep -v "^${kv#-}=" "$SETTINGS.new" >"$SETTINGS.tmp"
            mv "$SETTINGS.tmp" "$SETTINGS.new"
            ;;
        esac
    done
    mv "$SETTINGS.new" "$SETTINGS"
}

# run_game: runs launch.sh (under $LAUNCH_SHELL) to completion and keeps its log as
# $OUT_DIR/ra/<test number>.<run>.log; $LOG is that file.
run_game() {
    rm -f "$STUB/args" "$STUB/ach.ini" "$STUB/token" "$STUB/ini.inode" "$STUB/token.inode" "$STUB/token.mode"
    RUN_N=$((RUN_N + 1))
    # shellcheck disable=SC2086 # LAUNCH_SHELL may be a command with arguments ("busybox sh")
    $LAUNCH_SHELL "$PAK/launch.sh" "$ROMDIR/Game.iso" >"$T/launch.out" 2>&1 || true
    LOG="$OUT/$BATS_TEST_NUMBER.$RUN_N.log"
    cat "$LOGS/PSP.txt" "$T/launch.out" >"$LOG" 2>/dev/null || true
}

# ach KEY: value of KEY in the [Achievements] section PPSSPP saw; fails if KEY is absent.
ach() {
    awk -v k="$1" '{ sub(/\r$/, "") }
        index($0, k " = ") == 1 { print substr($0, length(k) + 4); f = 1 }
        END { exit !f }' "$STUB/ach.ini"
}
# assert_ach KEY VALUE
assert_ach() {
    local v
    v="$(ach "$1")" || {
        echo "$1 is not in the [Achievements] section PPSSPP saw" >&2
        return 1
    }
    assert_equal "$v" "$2"
}
# assert_ach_count KEY N: KEY appears N times in what PPSSPP saw.
assert_ach_count() {
    assert_equal "$(grep -c "^$1 = " "$STUB/ach.ini")" "$2"
}
# AchievementsHost lines in the [Achievements] section of the shipped ini and of what
# PPSSPP saw must be identical (both absent, or the same lines).
assert_host_unchanged() {
    assert_equal "$(grep '^[ 	]*AchievementsHost[ 	]*=' "$STUB/ach.ini")" \
        "$(ach_section "$T/shipped.ini" | grep '^[ 	]*AchievementsHost[ 	]*=')"
}
# Sets AchievementsHost in [Achievements] of ppsspp.ini, as if set by hand in PPSSPP:
# whatever AchievementsHost lines the section has, wherever they are, become one.
set_host_by_hand() {
    awk -v mode=host -v s=Achievements -v h="$1" -f "$SECTION_AWK" "$INI" >"$INI.x"
    mv "$INI.x" "$INI"
}
assert_token() { # assert_token <exact content>
    assert_file_exist "$STUB/token"
    printf '%s' "$1" | cmp -s - "$STUB/token" || {
        echo "token file is not exactly the expected token" >&2
        return 1
    }
}
assert_token_absent() {
    assert_file_not_exist "$STUB/token"
    assert_file_not_exist "$TOKEN"
}
assert_launched() { assert_file_exist "$STUB/args"; }
assert_no_tmp_left() {
    local left
    left="$(find "$SYSDIR" -name '*.tmp*')"
    assert_equal "$left" ""
}
assert_no_secrets() { # assert_no_secrets <file>
    refute_grep "$1" "$RA_TOKEN"
    refute_grep "$1" "$RA_PASSWORD"
}

assert_enabled() { # assert_enabled <user> <hardcore True|False>
    assert_launched
    assert_ach AchievementsEnable True
    assert_ach AchievementsUserName "$1"
    assert_ach AchievementsChallengeMode "$2"
    assert_token "$RA_TOKEN" # token file holds exactly the NextUI token
    assert_no_secrets "$LOG"
    refute_grep "$INI" "$RA_TOKEN" # token not in ppsspp.ini
    assert_no_tmp_left
}

assert_disabled() {
    assert_launched
    assert_ach AchievementsEnable False
    assert_ach AchievementsUserName ""
    assert_token_absent
    assert_no_secrets "$LOG"
}

# A PPSSPP that was set up by hand inside PPSSPP (MinUI users, no-ra-sync users).
manual_ppsspp_login() {
    awk '{ sub(/^AchievementsEnable = .*/, "AchievementsEnable = True")
           sub(/^AchievementsUserName = .*/, "AchievementsUserName = HandUser") } 1' \
        "$T/shipped.ini" >"$INI"
    printf 'handTok' >"$TOKEN"
    ach_section "$INI" >"$T/before.ach"
}

assert_untouched() {
    assert_launched
    assert_same "$STUB/ach.ini" "$T/before.ach" # [Achievements] section unchanged
    assert_token handTok                        # hand-made token kept
}

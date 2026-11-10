#!/usr/bin/env bats
# bats file_tags=host,device
#
# RetroAchievements sync of launch.sh (launch.sh, scripts/retroachievements.sh, scripts/ini.sh).
#
# Every test runs the *real* launch.sh in its own throw-away SD card tree (see
# helpers/ra.bash), with a stub standing in for PPSSPP and a NextUI-style minuisettings.txt,
# and checks what PPSSPP would see at start-up: the [Achievements] section of ppsspp.ini and
# the token file. Nothing under the real SD card is touched; the sandbox is deleted afterwards.
#
# launch.sh runs under $LAUNCH_SHELL (default sh, e.g. dash; CI also runs "busybox sh"),
# so the shell the device uses is covered; the test code itself is bash.
#
# Env overrides:
#   SRC_PAK       pak to test (default: the repository checkout; on a device the installed pak)
#   PAK_NAME      pak directory name without .pak (default: "name" in pak.json)
#   PLATFORM      platform under test (default: the first one in pak.json)
#   OUT_DIR       where logs are kept (default /tmp/psp-test-out; this file uses OUT_DIR/ra)
#   TMP_ROOT      where the sandbox is made (default /tmp; e.g. /mnt/SDCARD to test on FAT)
#   LAUNCH_SHELL  shell that runs launch.sh (default sh; e.g. "busybox sh", bash)
#   KEEP=1        keep the sandbox

load '../helpers/common'
load '../helpers/ra'

setup_file() {
    rm -rf "$OUT_DIR/ra"
    mkdir -p "$OUT_DIR/ra"
}

setup() { ra_setup; }
teardown() { ra_teardown; }

@test "1 enabled, softcore" {
    fresh
    settings
    run_game
    assert_enabled Player1 False
    assert_grep "$LOG" "RetroAchievements: enabling for user 'Player1' (hardcore: False)"
    if [ "$PERMS_WORK" = 1 ]; then
        assert_equal "$(cat "$STUB/token.mode")" "-rw-------" # token file is private
    fi
}

@test "2 enabled, hardcore" {
    fresh
    settings raHardcoreMode=1
    run_game
    assert_enabled Player1 True
}

@test "3 disabled in NextUI -> off, logged out" {
    fresh
    settings
    run_game
    settings raEnable=0
    run_game
    assert_disabled
    assert_grep "$LOG" "RetroAchievements: disabled in NextUI"
}

@test "4 enabled but not logged in -> off, logged out" {
    fresh
    settings
    run_game
    settings raAuthenticated=0
    run_game
    assert_disabled
    assert_grep "$LOG" "enabled in NextUI but not logged in"
    settings raToken=
    run_game
    assert_token_absent # empty token also counts as logged out
    settings raUsername=
    run_game
    assert_ach AchievementsEnable False # empty username also counts as logged out
}

@test "5 no minuisettings.txt (MinUI) -> PPSSPP untouched" {
    fresh
    manual_ppsspp_login
    run_game
    assert_untouched
    assert_grep "$LOG" "no NextUI settings found"
}

@test "6 no raEnable key (older NextUI) -> PPSSPP untouched" {
    fresh
    manual_ppsspp_login
    settings -raEnable
    run_game
    assert_untouched
    assert_grep "$LOG" "not configured in NextUI"
}

@test "7 no-ra-sync flag -> PPSSPP untouched" {
    fresh
    manual_ppsspp_login
    settings raEnable=0
    touch "$FLAGS/no-ra-sync"
    run_game
    assert_untouched
    assert_grep "$LOG" "sync disabled via no-ra-sync"
}

@test "8 no-config-changes flag -> PPSSPP untouched" {
    fresh
    manual_ppsspp_login
    settings raEnable=0
    touch "$FLAGS/no-config-changes"
    cp "$INI" "$T/before.ini"
    run_game
    assert_untouched
    assert_same "$INI" "$T/before.ini" # ini byte for byte unchanged (graphics too)
    assert_grep "$LOG" "RetroAchievements: Config changes disabled"
}

@test "9 username with special characters / & | \\1" {
    fresh
    settings 'raUsername=a/b&c|d\1e'
    run_game
    assert_enabled 'a/b&c|d\1e' False
}

@test "10a older ini without the keys" {
    fresh
    grep -v -e '^AchievementsEnable = ' -e '^AchievementsUserName = ' -e '^AchievementsChallengeMode = ' \
        "$T/shipped.ini" >"$INI"
    settings raHardcoreMode=1
    run_game
    assert_enabled Player1 True
    assert_ach AchievementsEnableRAIntegration False # untouched
    assert_ach_count AchievementsEnable 1            # added once
}

@test "10b older ini without the section" {
    fresh
    settings raHardcoreMode=1
    ra_section out Achievements "$T/shipped.ini" >"$INI"
    run_game
    assert_enabled Player1 True
    assert_equal "$(ach_section "$INI" | grep -c 'Achievements\]')" 1 # section added once
    run ra_section in Graphics "$INI"                                    # [Graphics] still there
    assert_output --partial 'DisplayAspectRatio = '
}

@test "11 CRLF ini keeps CRLF" {
    fresh
    sed "s/\$/$CR/" "$T/shipped.ini" >"$INI"
    grep -v '^AchievementsUserName = ' "$INI" >"$INI.x"
    mv "$INI.x" "$INI"
    settings
    run_game
    assert_enabled Player1 False
    # every line still ends in CR
    assert_equal "$(grep -c "$CR\$" "$INI")" "$(wc -l <"$INI" | tr -d ' ')"
    refute_grep "$INI" "^AchievementsUserName = Player1\$" # no bare LF line added
}

@test "12 token file with a trailing newline is normalised" {
    fresh
    settings
    printf '%s\n' "$RA_TOKEN" >"$TOKEN"
    run_game
    assert_token "$RA_TOKEN" # the token without newline
    assert_grep "$LOG" "login token updated"
    assert_no_secrets "$LOG"
}

@test "13 AchievementsHost is never touched" {
    fresh
    settings
    run_game
    assert_enabled Player1 False
    # The shipped ini may or may not have the key (PPSSPP writes "AchievementsHost =" once it
    # has saved the ini, e.g. in a pak installed on a device): it must be as it was.
    assert_host_unchanged
    set_host_by_hand "http://hand.example"
    run_game
    assert_ach_count AchievementsHost 1
    assert_ach AchievementsHost "http://hand.example" # set by hand in PPSSPP, keeps its value
    settings raEnable=0
    run_game
    assert_ach AchievementsHost "http://hand.example" # kept when disabling too
}

@test "14 second launch changes nothing (same inodes, same content)" {
    fresh
    settings raHardcoreMode=1
    run_game
    cp "$STUB/ach.ini" "$T/run1.ach"
    cp "$INI" "$T/run1.ini"
    local ini1 tok1
    ini1="$(cat "$STUB/ini.inode")"
    tok1="$(cat "$STUB/token.inode")"
    run_game
    assert_enabled Player1 True
    assert_equal "$(cat "$STUB/ini.inode")" "$ini1"     # ini inode unchanged
    assert_equal "$(cat "$STUB/token.inode")" "$tok1"   # token inode unchanged
    assert_same "$INI" "$T/run1.ini"                    # ini content unchanged
    refute_grep "$LOG" "login token updated"
}

@test "15 secrets never in the log, also with the debug flag (set -x)" {
    fresh
    touch "$FLAGS/debug"
    settings raHardcoreMode=1
    run_game
    assert_grep "$LOG" '^+ ' # debug tracing is on
    assert_enabled Player1 True
    printf '%s\n' "$RA_TOKEN" >"$TOKEN"
    run_game
    assert_no_secrets "$LOG" # token rewrite traced without secrets
    settings raEnable=0
    run_game
    assert_disabled
    assert_grep "$LOG" '^+ .*mount' # tracing resumes after the sync
}

# A full SD card, made in the sandbox copy of scripts/set_ini_values.awk (so it works under any
# shell, also a BusyBox ash that runs its applets in preference to what is first in PATH):
# the awk script writes only the first 3 lines to the temporary ini, and then says it failed
# (mode exit) or claims success with the number of lines it meant to write (mode lie).
failing_awk() { # failing_awk <exit|lie>
    local awk_file="$PAK/scripts/set_ini_values.awk"
    cp "$awk_file" "$T/real.awk"
    sed -e 's/^    print s > out$/    if (written < 3) print s > out/' "$T/real.awk" >"$awk_file"
    if [ "$1" = exit ]; then
        sed -e 's/^    print written$/    exit 1/' "$awk_file" >"$T/failing.awk"
        cp "$T/failing.awk" "$awk_file"
    fi
    # the edits must have applied, or this would not test anything
    assert_differ "$T/real.awk" "$awk_file"
    assert_grep "$awk_file" 'if (written < 3) print s > out'
    if [ "$1" = exit ]; then
        assert_grep "$awk_file" '^    exit 1$'
    fi
}

@test "16a failed ini write (full SD card, awk fails) leaves ppsspp.ini as it was" {
    fresh
    settings raHardcoreMode=1
    cp "$INI" "$T/before.ini"
    failing_awk exit
    run_game
    assert_same "$INI" "$T/before.ini"
    assert_grep "$LOG" "could not write"
    assert_no_tmp_left
    assert_launched
}

@test "16b failed ini write (full SD card, awk claims success) leaves ppsspp.ini as it was" {
    fresh
    settings raHardcoreMode=1
    cp "$INI" "$T/before.ini"
    failing_awk lie
    run_game
    assert_same "$INI" "$T/before.ini"
    assert_grep "$LOG" "could not write"
    assert_no_tmp_left
    assert_launched
}

@test "17a settings parsing: CRLF, last key wins" {
    fresh
    settings raHardcoreMode=1 # the base file says 0 earlier: the later line must win
    sed "s/\$/$CR/" "$SETTINGS" >"$SETTINGS.crlf"
    mv "$SETTINGS.crlf" "$SETTINGS"
    run_game
    assert_enabled Player1 True
}

@test "17b settings parsing: raAuthenticated missing -> off" {
    fresh
    settings
    run_game
    assert_enabled Player1 False
    settings -raAuthenticated
    run_game
    assert_ach AchievementsEnable False
    assert_token_absent
}

@test "17c settings parsing: raAuthenticated not 1 -> off" {
    fresh
    settings
    run_game
    assert_enabled Player1 False
    settings raAuthenticated=yes
    run_game
    assert_ach AchievementsEnable False
}

@test "18a only managed lines change" {
    fresh
    settings raHardcoreMode=1
    run_game
    assert_enabled Player1 True
    local managed='^(AchievementsEnable|AchievementsUserName|AchievementsChallengeMode|DisplayAspectRatio|GraphicsBackend) = '
    grep -v -E "$managed" "$T/shipped.ini" >"$T/a.rest"
    grep -v -E "$managed" "$INI" >"$T/b.rest"
    assert_same "$T/a.rest" "$T/b.rest" # all other lines byte for byte the same
}

@test "18b BOM kept; missing graphics key added" {
    fresh
    settings raHardcoreMode=1
    run_game
    assert_enabled Player1 True
    grep -v '^DisplayAspectRatio = ' "$T/shipped.ini" >"$INI" # the shipped ini starts with a BOM
    run_game
    assert_enabled Player1 True
    # The first line is a section header (with the BOM, if the ini has one): it must be
    # byte for byte the same, so a BOM is neither lost nor doubled.
    assert_equal "$(head -n 1 "$INI")" "$(head -n 1 "$T/shipped.ini")"
    run ra_section in Graphics "$INI"
    assert_output --partial 'DisplayAspectRatio = '
}

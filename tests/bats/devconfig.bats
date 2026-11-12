#!/usr/bin/env bats
# bats file_tags=host
# shellcheck disable=SC2016,SC2030,SC2031 # bats runs every test in a subshell
#
# Off-device tests of tests/helpers/devconfig.bash: how the on-device tests read the hotkeys
# from the device's controls.ini, fall back to the documented defaults, and report every
# unmet assumption in one message. Uses throw-away files, no device and no ssh.

load '../helpers/common'

setup() {
    require_tools awk grep tr
    T="$BATS_TEST_TMPDIR"
    # shellcheck disable=SC1091
    . "$TESTS_DIR/helpers/e2e.bash"
    # shellcheck disable=SC1091
    . "$TESTS_DIR/helpers/devconfig.bash"
    CTL="$T/controls.ini"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS SET_HOTKEYS CFG_CTL CFG_STOP_GAME
    # The shipped layout (with the BOM and CRLF the real file may have)
    SHIPPED='[ControlMapping]
Up = 10-19
Down = 10-20
Left = 10-21
Right = 10-22
Circle = 10-190
Cross = 10-189
Square = 10-191
Triangle = 10-188
Start = 10-197
Select = 10-196
L = 10-193
R = 10-192
Pause = 10-109'
}

ctl() { printf '%s\n' "$SHIPPED" >"$CTL"; printf '%s\n' "$@" >>"$CTL"; }

@test "SET_HOTKEYS=0: the shipped controls.ini has no hotkeys, each needed one is a problem, nothing is assumed" {
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    SET_HOTKEYS=0 cfg_init_hotkeys "$CTL"
    [ -z "$HOTKEY_TO_BIND" ]
    [ -z "$SAVE_KEYS" ] && [ -z "$NEXT_SLOT_KEYS" ] && [ -z "$EXIT_KEYS" ]
    [[ "$HOTKEY_PROBLEMS" == *"Save State hotkey (Save State) is not bound in controls.ini; PPSSPP has no default - bind it in PPSSPP's Controls > Hotkeys, set SAVE_KEYS"* ]]
    [[ "$HOTKEY_PROBLEMS" == *"set NEXT_SLOT_KEYS"* ]] && [[ "$HOTKEY_PROBLEMS" == *"set EXIT_KEYS"* ]]
}

@test "a missing controls.ini, or one without [ControlMapping], is reported once per needed hotkey" {
    cfg_init_hotkeys "$T/nope.ini" save
    [[ "$HOTKEY_PROBLEMS" == *"nope.ini not found"*"set SAVE_KEYS"* ]]
    [ -z "$HOTKEY_TO_BIND" ]
    [ ! -e "$T/nope.ini" ]
    [ "$(printf '%s\n' "$HOTKEY_PROBLEMS" | wc -l)" = 1 ]
    printf '[Other]\nx = 1\n' >"$CTL"
    unset SAVE_KEYS
    SET_HOTKEYS=0 cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"Save State"*"not bound"* ]]
}

@test "an empty value is unbound" {
    ctl 'Save State = '
    run cfg_hotkey_lookup "$CTL" "Save State"
    assert_output "UNSET"
}

@test "hotkeys are read from controls.ini through the FIXED code table (chords, d-pad)" {
    ctl 'Save State = 10-197:10-193' 'Next Slot = 10-196:10-21' 'Exit App = 10-197:10-196'
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = start+l1 ]
    [ "$NEXT_SLOT_KEYS" = select+left ]
    [ "$EXIT_KEYS" = start+select ]
    [ -z "$HOTKEY_PROBLEMS" ]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: start+l1 (from $CTL)"* ]]
}

@test "the code table ignores the user's PSP button rows (swapped Select/Start, Cross/Circle)" {
    printf '[ControlMapping]\nSelect = 10-197\nStart = 10-196\nCross = 10-190\nCircle = 10-189\nSave State = 10-196:10-190\n' >"$CTL"
    run cfg_hotkey_lookup "$CTL" "Save State"
    assert_output "OK select+a"
    run cfg_code_button 10-189
    assert_output "b"
    run cfg_code_button 10-188
    assert_output "x"
    run cfg_code_button 10-191
    assert_output "y"
}

@test "keyboard, other pads, axes and unmapped buttons (menu, 4, 106, 109) are unusable" {
    local v
    for v in 1-133 11-196 10-4001 10-109 10-4 10-106 10-194; do
        ctl "Save State = $v"
        run cfg_hotkey_lookup "$CTL" "Save State"
        assert_output "BAD $v"
    done
    ctl 'Exit App = 10-194:10-196'
    cfg_init_hotkeys "$CTL" exit
    [[ "$HOTKEY_PROBLEMS" == *"Exit hotkey (Exit App) is bound to '10-194:10-196'"*"set EXIT_KEYS"* ]]
}

@test "names are matched without regard to case; BOM and CRLF are fine; the first line wins" {
    { printf '\357\273\277'; printf '%s\r\n' '[ControlMapping]' 'save state = 10-196:10-192' 'Save State = 10-197'; } >"$CTL"
    run cfg_hotkey_lookup "$CTL" "Save State"
    assert_output "OK select+r1"
}

@test "alternatives: the first one the pad can press is used (keyboard ones are skipped)" {
    ctl 'Save State = 1-133,10-197:10-192,10-196:10-192'
    run cfg_hotkey_lookup "$CTL" "Save State"
    assert_output "OK start+r1"
}

@test "only [ControlMapping] counts (a key elsewhere is ignored)" {
    { printf '%s\n' '[Other]' 'Save State = 10-197:10-193' '[ControlMapping]' 'Up = 10-19'; } >"$CTL"
    run cfg_hotkey_lookup "$CTL" "Save State"
    assert_output "UNSET"
}

@test "problems are per consumer: the reboot tests do not need Next Slot" {
    ctl 'Save State = 10-196:10-192' 'Exit App = 10-196:10-197'
    cfg_init_hotkeys "$CTL" "save exit"
    [ -z "$HOTKEY_PROBLEMS" ]
    cfg_init_hotkeys "$CTL"
    [[ "$HOTKEY_PROBLEMS" == *"Next Slot"* ]]
}

@test "environment overrides win and are validated; empty SAVE_KEYS is rejected, EXIT_KEYS=\"\" is kill mode" {
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cp "$CTL" "$T/orig"
    SAVE_KEYS="l1+r1" EXIT_KEYS="" NEXT_SLOT_KEYS="select+bogus"
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = l1+r1 ] && [ -z "$EXIT_KEYS" ]
    [[ "$HOTKEY_PROBLEMS" == *"NEXT_SLOT_KEYS='select+bogus' has a step the test cannot press: 'select+bogus'"* ]]
    [[ "$HOTKEY_PROBLEMS" != *"EXIT_KEYS"* ]]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: l1+r1 (set by the environment"* ]]
    [[ "$HOTKEY_TO_BIND" != *"Save State"* ]] # an override means: do not touch controls.ini for it
    SAVE_KEYS="" NEXT_SLOT_KEYS="select+right"
    cfg_init_hotkeys "$CTL"
    [[ "$HOTKEY_PROBLEMS" == *"SAVE_KEYS is empty"* ]]
}

@test "cfg_keys_valid: buttons, chords, sleepN and shot pass; anything else is named" {
    run cfg_keys_valid "select+r1 sleep3 shot sleep0.5 left"
    assert_success
    run cfg_keys_valid "select+r1 sleepx"
    assert_failure
    assert_output "sleepx"
    run cfg_keys_valid "a l2"
    assert_output "l2"
}

@test "cfg_ini_general reads [General] only" {
    printf '\357\273\277[General]\r\nSaveStateOnExit = True\r\n[Other]\r\nSaveStateOnExit = False\r\n' >"$T/p.ini"
    run cfg_ini_general "$T/p.ini" SaveStateOnExit
    assert_output "True"
}

@test "cfg_start_mode_info: shows only the start screen keys of minuisettings.txt, never a credential" {
    printf 'screentimeout=60\nraUsername=alice\nraToken=SECRETTOKEN123\nraAuthenticated=1\ndefaultView=1\nhaptics=1\nraPassword=SECRETPW\n' >"$T/m.txt"
    run cfg_start_mode_info "$T/m.txt"
    assert_output "defaultView=1 "
    run cfg_start_mode_info "$T/none.txt"
    assert_output --partial "no start screen setting found"
}

@test "collector: minuisettings.txt and ppsspp.ini reach the bundle without credentials" {
    local sd="$T/sd" pak="$T/sd/Emus/tg5040/PSP.pak/PPSSPP/.config/ppsspp/PSP/SYSTEM"
    mkdir -p "$sd/.userdata/shared" "$pak"
    printf 'screentimeout=60\nraUsername=alice\nraToken=SECRETTOKEN123\nraAuthenticated=1\nraPassword=SECRETPW\ndefaultView=1\n' >"$sd/.userdata/shared/minuisettings.txt"
    printf '[Achievements]\nAchievementsUserName = alice\nAchievementsToken = SECRETTOKEN123\nAchievementsLoginTimestamp = 5\n' >"$pak/ppsspp.ini"
    SDCARD_PATH="$sd" PLATFORM=tg5040 PAK_NAME=PSP sh "$TESTS_DIR/collect.sh" "$TESTS_DIR/collectors/device.list" "$T/col"
    assert_file_exist "$T/col/minuisettings.txt"
    run grep -r -E 'alice|SECRET' "$T/col/minuisettings.txt" "$T/col/ppsspp.ini"
    assert_failure
    assert_grep "$T/col/minuisettings.txt" 'raToken=<hidden>'
    assert_grep "$T/col/minuisettings.txt" 'defaultView=1'
    assert_grep "$T/col/ppsspp.ini" 'AchievementsLoginTimestamp = 5'
}

@test "e2e_preflight_problems: every unmet assumption is one FAIL line, all at once" {
    PAK="$T/sd/pak" INI="$T/sd/pak/ppsspp.ini" MON="$T/sd/mon" PNGCOLOR="$T/none" PAD="" ROM="" ROM_DIR=""
    HOTKEY_PROBLEMS="Save State hotkey is bound to 'x'"
    run e2e_preflight_problems
    assert_failure
    assert_output --partial "FAIL: the pak is not installed"
    assert_output --partial "FAIL: $T/sd/pak/bin/jpg2bmp missing"
    assert_output --partial "FAIL: Screenshot Monitor pak not found"
    assert_output --partial "FAIL: no Roms/*(PSP) folder found"
    assert_output --partial "FAIL: Save State hotkey is bound to 'x'"
    assert_output --partial "TRIMUI Player1"
}

@test "e2e_preflight_problems: passes on a complete tree" {
    [ "$(id -u)" = 0 ] || skip "needs root (the preflight checks it)"
    [ -f /tmp/nextui_exec ] || skip "needs /tmp/nextui_exec"
    export PAD=/dev/null
    PAK="$T/pak" INI="$T/pak/ppsspp.ini" MON="$T/mon" PNGCOLOR="$T/pngcolor" ROM_DIR="$T/roms" ROM="$T/roms/g.iso"
    mkdir -p "$PAK/bin" "$MON/bin" "$ROM_DIR"
    : >"$PAK/bin/jpg2bmp" && chmod +x "$PAK/bin/jpg2bmp"
    : >"$INI" && : >"$MON/bin/screenshot" && : >"$PNGCOLOR" && chmod +x "$PNGCOLOR" && : >"$ROM"
    HOTKEY_PROBLEMS=""
    run e2e_preflight_problems
    assert_success
}

# --- binding missing hotkeys temporarily ---------------------------------------------------------
# The backup/restore is the e2e one (restore_files); BAK is a throw-away dir.
bind_setup() {
    BAK="$T/bak"
    export CONTROLS="$CTL"
    mkdir -p "$BAK"
    : >"$BAK/active"
}
# What e2e.bats / rb_backup do: stash, then bind.
# shellcheck disable=SC2119,SC2120
bind_run() { # bind_run [needs]
    stash "$CTL"
    cfg_init_hotkeys "$CTL" "$@"
    cfg_apply_hotkeys
}

@test "unbound hotkeys are bound with PPSSPP's names and codes, and the original comes back byte for byte" {
    bind_setup
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL"
    [ -z "$HOTKEY_PROBLEMS" ]
    [ "$SAVE_KEYS" = select+r1 ] && [ "$NEXT_SLOT_KEYS" = select+right ] && [ "$EXIT_KEYS" = select+start ]
    [[ "$HOTKEY_INFO" == *"NOT BOUND"*"restore the file"* ]]
    [ ! -f "$BAK/controls.bound" ]  # nothing is written by the preflight
    cmp "$CTL" "$T/orig"
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    run bind_run
    assert_success
    assert_output --partial "Save State = 10-196:10-192"
    assert_grep "$CTL" '^Save State = 10-196:10-192'
    assert_grep "$CTL" '^Next Slot = 10-196:10-22'
    assert_grep "$CTL" '^Exit App = 10-196:10-197'
    # every other line is untouched, and the BOM is still the first thing in the file
    run grep -c -v -E '^(Save State|Next Slot|Exit App) = ' "$CTL"
    [ "$output" = "$(wc -l <"$T/orig")" ]
    [ "$(head -c 3 "$CTL" | od -An -tx1 | tr -d ' ')" = efbbbf ]
    run cfg_hotkey_lookup "$CTL" "Exit App"
    assert_output "OK select+start"
    restore_files
    cmp "$CTL" "$T/orig"
    assert_file_not_exist "$BAK/controls.written"
}

@test "a partly bound file keeps the user's bindings; only the missing ones are added" {
    bind_setup
    ctl 'Save State = 10-193:10-197'
    cp "$CTL" "$T/orig"
    run bind_run
    assert_success
    refute_output --partial "Save State"
    assert_grep "$CTL" '^Save State = 10-193:10-197$'
    assert_grep "$CTL" '^Exit App = 10-196:10-197'
    run grep -c '^Save State' "$CTL"
    [ "$output" = 1 ]
    restore_files
    cmp "$CTL" "$T/orig"
}

@test "an empty value is filled in place, CRLF line endings and the BOM are kept" {
    bind_setup
    { printf '\357\273\277'; printf '%s\r\n' '[ControlMapping]' 'Select = 10-196' 'Save State = ' 'R = 10-192' '[Other]' 'x = 1'; } >"$CTL"
    cp "$CTL" "$T/orig"
    run bind_run save
    assert_success
    run cat -A "$CTL"
    assert_output --partial 'Save State = 10-196:10-192^M$'
    assert_output --partial 'Select = 10-196^M$'
    [ "$(grep -c 'Save State' "$CTL")" = 1 ]
    # added keys stay inside [ControlMapping], before the next section
    run awk '/^\[Other\]/{o=1} o && /Exit App/{bad=1} END{print bad+0}' "$CTL"
    assert_output "0"
    restore_files
    cmp "$CTL" "$T/orig"
}

@test "a file with no [ControlMapping] section is NOT given one (PPSSPP would drop its built-in mappings); a missing file is not created" {
    bind_setup
    printf '[Other]\nx = 1\n' >"$CTL"
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"no [ControlMapping] in "*"the tests do not create the section"*"set SAVE_KEYS"* ]]
    [ -z "$HOTKEY_TO_BIND" ]
    run cfg_controls_bind "$CTL" "Save State" "10-196:10-192"
    assert_failure
    cmp "$CTL" "$T/orig"
    rm -f "$CTL"
    unset SAVE_KEYS
    cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"not found (the tests do not create it)"* ]]
    [ ! -e "$CTL" ]
}

@test "a chord that another action already uses is not taken: a free one is chosen and said so" {
    bind_setup
    ctl 'Pause = 10-196:10-192'
    cfg_init_hotkeys "$CTL" save
    [ "$SAVE_KEYS" = start+r1 ]
    [[ "$HOTKEY_INFO" == *"the usual select+r1 is taken by 'Pause'"* ]]
    # the chord is compared as a set: R+select in the other order collides too
    ctl 'Pause = 10-192:10-196' 'Next Slot = 10-197:10-22'
    unset SAVE_KEYS
    cfg_init_hotkeys "$CTL" "save next"
    [ "$SAVE_KEYS" = start+r1 ]
}

@test "no free chord at all is one clear problem naming the hotkey, nothing is bound" {
    ctl 'A1 = 10-196:10-192' 'A2 = 10-197:10-192' 'A3 = 10-196:10-193'
    cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"Save State hotkey (Save State) is not bound"*"already used by another action"*"set SAVE_KEYS"* ]]
    [ -z "$HOTKEY_TO_BIND" ]
}

@test "the hotkeys chosen for one run never share a chord with each other" {
    ctl 'Pause = 10-196:10-197'
    cfg_init_hotkeys "$CTL"
    [ "$EXIT_KEYS" != select+start ]
    [ "$SAVE_KEYS" != "$EXIT_KEYS" ] && [ "$SAVE_KEYS" != "$NEXT_SLOT_KEYS" ]
}

@test "SET_HOTKEYS=0 keeps the old behaviour: a clear failure and the file is left alone" {
    bind_setup
    ctl 'Exit App = 10-196:10-197'
    cp "$CTL" "$T/orig"
    SET_HOTKEYS=0 run bash -c ". '$TESTS_DIR/helpers/e2e.bash'; . '$TESTS_DIR/helpers/devconfig.bash'; cfg_init_hotkeys '$CTL'; printf '%s' \"\$HOTKEY_PROBLEMS\""
    assert_output --partial "Save State hotkey (Save State) is not bound in controls.ini; PPSSPP has no default"
    assert_output --partial "SET_HOTKEYS=0"
    cmp "$CTL" "$T/orig"
}

@test "environment overrides leave controls.ini alone" {
    bind_setup
    ctl 'Pause = 10-109'
    cp "$CTL" "$T/orig"
    SAVE_KEYS=l1+r1 NEXT_SLOT_KEYS=select+left EXIT_KEYS=start+l1 run bind_run
    assert_success
    assert_output ""
    cmp "$CTL" "$T/orig"
    assert_file_not_exist "$BAK/controls.bound"
}

@test "a hotkey the user bound to something unpressable is never overwritten" {
    bind_setup
    ctl 'Save State = 1-133'
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"is bound to '1-133'"*"never changed"* ]]
    [ -z "$HOTKEY_TO_BIND" ]
}

@test "an aborted run: the next start puts the original back first and binds again" {
    bind_setup
    ctl 'Select = 10-196'
    cp "$CTL" "$T/orig"
    bind_run >/dev/null
    assert_differ "$CTL" "$T/orig"
    # next run: the file still has the old run's bindings, so nothing looks unbound ...
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
    cfg_init_hotkeys "$CTL"
    [ -z "$HOTKEY_TO_BIND" ]
    # ... until the restore of the aborted run, then the hotkeys are resolved again
    restore_files
    cmp "$CTL" "$T/orig"
    cfg_reinit_hotkeys
    [[ "$HOTKEY_TO_BIND" == *"Save State|10-196:10-192|SAVE_KEYS|select+r1"* ]]
    [ "$SAVE_KEYS" = select+r1 ]
}

@test "restore: a controls.ini changed since is kept as controls.ini.replaced, the original still comes back" {
    bind_setup
    ctl 'Select = 10-196'
    cp "$CTL" "$T/orig"
    bind_run >/dev/null
    printf '[ControlMapping]\nSave State = 10-197\n' >"$CTL"
    run restore_files
    assert_output --partial "WARNING"
    cmp "$CTL" "$T/orig"
    run bash -c "grep -l 'Save State = 10-197' '$CTL'.replaced.*"
    assert_success
}

@test "backup: controls.ini is in $BAK/present BEFORE anything is written, and backup + restore leave it byte-identical" {
    bind_setup
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL"
    stash "$CTL"
    assert_grep "$BAK/present" "^$CTL\$"
    cmp "$BAK$CTL" "$T/orig"
    run cfg_apply_hotkeys
    assert_success
    assert_differ "$CTL" "$T/orig"
    run restore_files
    assert_success
    cmp "$CTL" "$T/orig"
}

@test "cfg_apply_hotkeys refuses to write when controls.ini is not backed up" {
    bind_setup
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL"
    run cfg_apply_hotkeys
    assert_failure
    assert_output --partial "refusing to change"
    cmp "$CTL" "$T/orig"
}

@test "e2e.bats uses the shared backup and restore (psp_backup, psp_restore), nothing of its own" {
    local f="$TESTS_DIR/bats/e2e.bats"
    assert_grep "$f" 'psp_backup'
    assert_grep "$f" 'psp_restore normal'
    refute_grep "$f" '^[^#]*\(cfg_backup_and_bind\|cfg_restore_foreign\|restore_files\)'
    refute_grep "$f" 'psp-e2e-backup'
}

# A fake pgrep/killall: $FB/ppsspp exists while the emulator runs, $FB/nextui_down while NextUI is
# not up (a game is running or starting); killing the emulator brings NextUI back.
fake_game_tools() {
    mkdir -p "$T/fb"
    cat >"$T/fb/pgrep" <<'FAKE'
#!/bin/sh
case "$1" in
PPSSPPSDL) [ -e "$FB/ppsspp" ] ;;
nextui.elf) [ ! -e "$FB/nextui_down" ] ;;
esac
FAKE
    cat >"$T/fb/killall" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FB/killed"
rm -f "$FB/ppsspp" "$FB/nextui_down"
FAKE
    chmod +x "$T/fb/pgrep" "$T/fb/killall"
    export FB="$T/fb" PLATFORM=tg5040
}

@test "e2e_stop_game: SIGKILL, then waits until PPSSPP is gone and NextUI is back; nothing running: nothing killed" {
    fake_game_tools
    : >"$FB/ppsspp"
    : >"$FB/nextui_down"
    PATH="$FB:$PATH" run e2e_stop_game
    assert_success
    run cat "$FB/killed"
    assert_output "-9 PPSSPPSDL_tg5040"
    rm -f "$FB/killed"
    PATH="$FB:$PATH" run e2e_stop_game
    assert_success
    assert_file_not_exist "$FB/killed"
}

@test "e2e_stop_game: a game that is still STARTING (NextUI down, no PPSSPP yet) is waited for and then killed" {
    fake_game_tools
    : >"$FB/nextui_down"
    ( sleep 2; : >"$FB/ppsspp" ) &
    PATH="$FB:$PATH" run e2e_stop_game
    assert_success
    assert_file_exist "$FB/killed"
    wait
}

@test "e2e_stop_game: fails (bounded) when NextUI never comes back, so the caller does not restore too early" {
    fake_game_tools
    : >"$FB/nextui_down"
    printf '#!/bin/sh\n:\n' >"$FB/killall"
    E2E_STOP_TIMEOUT=2 PATH="$FB:$PATH" run e2e_stop_game
    assert_failure
    assert_output --partial "still running or starting after 2s"
}

@test "the hotkeys are EXPORTED after the e2e setup path, also after a re-init, so a test sees them" {
    ctl 'Exit App = 10-196:10-197' 'Save State = 10-196:10-192' 'Next Slot = 10-196:10-22'
    local out
    out="$(CONTROLS="$CTL" bash -c ". '$TESTS_DIR/helpers/e2e.bash'; . '$TESTS_DIR/helpers/devconfig.bash'; unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS PSP_KEYS
        e2e_setup_hotkeys; e2e_reinit_hotkeys
        bash -c 'printf \"%s|%s|%s|%s\" \"\$EXIT_KEYS\" \"\$SAVE_KEYS\" \"\$PSP_KEYS\" \"\${HOTKEY_INFO:+info}\"'")"
    [ "$out" = "select+start|select+r1|select+r1 sleep3 shot select+right sleep1 shot select+r1 sleep3 shot|info" ]
}

@test "e2e: with the Exit hotkey exported, the E2 exit test takes the hotkey path, not the kill path" {
    ctl 'Exit App = 10-196:10-197'
    local out
    out="$(CONTROLS="$CTL" PSP_KEYS="" bash -c ". '$TESTS_DIR/helpers/e2e.bash'; . '$TESTS_DIR/helpers/devconfig.bash'; unset EXIT_KEYS
        e2e_setup_hotkeys; e2e_reinit_hotkeys
        bash -c '[ -n \"\$EXIT_KEYS\" ] && echo hotkey || echo kill'")"
    [ "$out" = hotkey ]
}

@test "the restored message is only printed when the file really is the original" {
    bind_setup
    ctl 'Select = 10-196'
    cp "$CTL" "$T/orig"
    cfg_init_hotkeys "$CTL" save
    stash "$CTL"
    cfg_apply_hotkeys >/dev/null
    CFG_CTL="$CTL" run cfg_report_restore 1
    assert_output --partial "WARNING: controls.ini could NOT be restored"
    restore_files
    CFG_CTL="$CTL" run cfg_report_restore 1
    assert_output --partial "controls.ini restored"
    CFG_CTL="$CTL" run cfg_report_restore 0
    assert_output ""
}

@test "stash: a copy that is not identical (full SD card) is an error and is not recorded" {
    bind_setup
    ctl 'Select = 10-196'
    cp() { command cp "$@" && : >"$2"; } # a truncated copy
    run stash "$CTL"
    assert_failure
    assert_output --partial "could not back up"
    run grep -c . "$BAK/present"
    refute_output "1"
}

@test "guard: a settings file that is neither the backup nor what the tests left is kept under a unique name; the usual cases are silent" {
    bind_setup
    export INI="$T/ppsspp.ini"
    ctl 'Select = 10-196'
    printf '[General]\nA = 1\n' >"$INI"
    stash "$INI"
    stash "$CTL"
    # what the tests left
    printf '[General]\nA = 2\n' >"$INI"
    snapshot_left "$INI"
    run restore_files
    assert_output ""                                    # backup / left: no copy, no noise
    cmp "$INI" "$BAK$INI"
    # a user edit in between (neither the backup nor what the tests left)
    printf '[General]\nA = 3\n' >"$INI"
    run restore_files
    assert_output --partial "WARNING: $INI is neither the backup nor what the tests left"
    cmp "$INI" "$BAK$INI"
    run bash -c "cat '$INI'.replaced.*"
    assert_output --partial "A = 3"
    # a second one in the same second keeps its own name
    printf '[General]\nA = 4\n' >"$INI"
    restore_files 2>/dev/null
    set -- "$INI".replaced.*
    [ "$#" = 2 ]
}

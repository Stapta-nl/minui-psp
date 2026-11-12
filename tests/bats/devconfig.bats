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
    unset SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS
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

@test "the shipped controls.ini has no hotkeys: each needed one is a problem, no default is assumed" {
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cfg_init_hotkeys "$CTL"
    [ -z "$SAVE_KEYS" ] && [ -z "$NEXT_SLOT_KEYS" ] && [ -z "$EXIT_KEYS" ]
    [[ "$HOTKEY_PROBLEMS" == *"Save State hotkey (Save State) is not bound in controls.ini; PPSSPP has no default - bind it in PPSSPP's Controls > Hotkeys or set SAVE_KEYS"* ]]
    [[ "$HOTKEY_PROBLEMS" == *"set NEXT_SLOT_KEYS"* ]] && [[ "$HOTKEY_PROBLEMS" == *"set EXIT_KEYS"* ]]
}

@test "a missing controls.ini, or one without [ControlMapping], is reported once per needed hotkey" {
    cfg_init_hotkeys "$T/nope.ini" save
    [[ "$HOTKEY_PROBLEMS" == *"nope.ini not found"*"set SAVE_KEYS"* ]]
    [ "$(printf '%s\n' "$HOTKEY_PROBLEMS" | wc -l)" = 1 ]
    printf '[Other]\nx = 1\n' >"$CTL"
    unset SAVE_KEYS
    cfg_init_hotkeys "$CTL" save
    [[ "$HOTKEY_PROBLEMS" == *"no [ControlMapping] section"* ]]
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
    SAVE_KEYS="l1+r1" EXIT_KEYS="" NEXT_SLOT_KEYS="select+bogus"
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = l1+r1 ] && [ -z "$EXIT_KEYS" ]
    [[ "$HOTKEY_PROBLEMS" == *"NEXT_SLOT_KEYS='select+bogus' has a step the test cannot press: 'select+bogus'"* ]]
    [[ "$HOTKEY_PROBLEMS" != *"EXIT_KEYS"* ]]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: l1+r1 (set by the environment)"* ]]
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

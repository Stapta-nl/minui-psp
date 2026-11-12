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

@test "the shipped controls.ini has no hotkeys: the documented defaults are used and said so" {
    cp "$REPO_DIR/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini" "$CTL"
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = select+r1 ] && [ "$NEXT_SLOT_KEYS" = select+right ] && [ "$EXIT_KEYS" = select+start ]
    [ -z "$HOTKEY_PROBLEMS" ]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: select+r1 (not set in controls.ini"* ]]
}

@test "a missing controls.ini is the same as no hotkeys set" {
    cfg_init_hotkeys "$T/nope.ini"
    [ "$SAVE_KEYS" = select+r1 ] && [ -z "$HOTKEY_PROBLEMS" ]
}

@test "hotkeys are read from controls.ini through the button mapping (chords, other buttons)" {
    ctl 'SaveState = 10-197:10-193' 'NextSlot = 10-196:10-21' 'ExitApp = 10-197:10-196'
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = start+l1 ]
    [ "$NEXT_SLOT_KEYS" = select+left ]
    [ "$EXIT_KEYS" = start+select ]
    [ -z "$HOTKEY_PROBLEMS" ]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: start+l1 (from controls.ini)"* ]]
}

@test "names are matched without case, spaces, underscores; BOM and CRLF are fine" {
    { printf '\357\273\277'; printf '%s\r\n' '[ControlMapping]' 'Select = 10-196' 'R = 10-192' 'Save State = 10-196:10-192'; } >"$CTL"
    run cfg_hotkey_lookup "$CTL" SaveState
    assert_output "OK select+r1"
}

@test "alternatives: the first one the pad can press is used (keyboard ones are skipped)" {
    ctl 'SaveState = 1-133,10-197:10-192,10-196:10-192'
    run cfg_hotkey_lookup "$CTL" SaveState
    assert_output "OK start+r1"
}

@test "a hotkey bound only to a keyboard key or an unmapped code is a problem naming it and the override" {
    ctl 'SaveState = 1-133' 'ExitApp = 10-194:10-196'
    cfg_init_hotkeys "$CTL"
    [[ "$HOTKEY_PROBLEMS" == *"Save State hotkey is bound to '1-133'"*"set SAVE_KEYS"* ]]
    [[ "$HOTKEY_PROBLEMS" == *"Exit hotkey is bound to '10-194:10-196'"*"set EXIT_KEYS"* ]]
}

@test "only [ControlMapping] counts (a SaveState key elsewhere is ignored)" {
    { printf '%s\n' "$SHIPPED" '[Other]' 'SaveState = 10-197:10-193'; } >"$CTL"
    run cfg_hotkey_lookup "$CTL" SaveState
    assert_output "UNSET"
}

@test "environment overrides win, EXIT_KEYS=\"\" stays empty (kill mode), bad steps are reported" {
    ctl 'SaveState = 10-197:10-193'
    SAVE_KEYS="l1+r1" EXIT_KEYS="" NEXT_SLOT_KEYS="select+bogus"
    cfg_init_hotkeys "$CTL"
    [ "$SAVE_KEYS" = l1+r1 ] && [ -z "$EXIT_KEYS" ]
    [[ "$HOTKEY_PROBLEMS" == *"NEXT_SLOT_KEYS='select+bogus' has a step the test cannot press: 'select+bogus'"* ]]
    [[ "$HOTKEY_INFO" == *"Save State hotkey: l1+r1 (set by the environment)"* ]]
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

@test "cfg_start_mode_info: shows the start screen lines of minuisettings.txt, whatever the mode" {
    printf 'screentimeout=60\ndefaultView=1\nhaptics=1\n' >"$T/m.txt"
    run cfg_start_mode_info "$T/m.txt"
    assert_output --partial "defaultView=1"
    refute_output --partial "haptics"
    run cfg_start_mode_info "$T/none.txt"
    assert_output --partial "no start screen setting found"
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

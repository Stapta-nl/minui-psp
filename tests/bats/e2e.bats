#!/usr/bin/env bats
# bats file_tags=device,platform:tg5040,platform:tg5050
#
# End-to-end test of the Game Switcher preview on a real TrimUI device (ported from the old
# tests/device/e2e.sh).
#
# Unlike preview.bats (stub emulator, throw-away SD tree), this drives the REAL NextUI, the
# REAL PPSSPP pak and the real SD card, with no human at the buttons: buttons are injected by
# writing evdev events to the "TRIMUI Player1" pad, games are launched through NextUI's own
# /tmp/next hand-off, screenshots come from the "Screenshot Monitor" pak and are judged by the
# bundled pngcolor. See tests/helpers/e2e.bash.
#
# Requirements on the device: root, NextUI, this PSP pak installed in Emus/<platform>/<PAK_NAME>.pak (PSP),
# the Screenshot Monitor pak installed in Tools/<platform>/Screenshot Monitor.pak, and at
# least one file in a "...(PSP)" folder under Roms/. The test uses the FIRST file there.
#
# It temporarily changes recents / resume files of the test game and restores them at the end.
# The backup is kept on the SD card (/.userdata/shared/.psp-e2e-backup); if a run is cut
# short, the next run restores from it first. Do not touch the device while it runs.
#
# The tests run in order and share state (E2 builds on the game that E2's first test starts).
#
# Env overrides:
#   SDCARD_PATH (/mnt/SDCARD)  PLATFORM  ROM_DIR  ROM  OUT_DIR (this file uses OUT_DIR/e2e)
#   PSP_KEYS   space separated steps run inside PPSSPP after boot, to make save states.
#              Steps: up down left right a b x y l1 r1 select start | chords joined with +
#              (select+r1) | sleep<sec> | shot
#              Default: save, next slot, save, using the hotkeys of the DEVICE: the Save State,
#              Next Slot and Exit App bindings are read from the pak's controls.ini (see
#              tests/helpers/devconfig.bash). PPSSPP has no default for them: a hotkey that is
#              not bound there is reported by the preflight (bind it, or set the variables).
#              PSP_KEYS="" skips saving: then there must be no preview (NextUI shows No Preview).
#   SAVE_KEYS, NEXT_SLOT_KEYS  override the two hotkeys above (same step syntax, one chord).
#   EXIT_KEYS  how the emulator is quit (default: the Exit App hotkey; "" kills PPSSPP instead).
#   BOOT_WAIT (20)  UI_WAIT (6)  KEY_GAP (0.5)  CHORD_HOLD (0.3)
#
# The save states made by the test (new files in /.userdata/shared/PSP-ppsspp) are deleted
# at the end. A state that already existed in slot 0 or 1 of the test game is overwritten.

load '../helpers/common'
load '../helpers/e2e'
load '../helpers/devconfig'

setup_file() {
    require_tools awk cmp cp mv rm mkdir grep head tail tr find ls wc sed cat sleep touch basename dirname sync pgrep killall id printf

    SD="${SDCARD_PATH:-/mnt/SDCARD}"
    PLATFORM="$(psp_platform)"
    PAK_NAME="$(psp_pak_name)"
    PAK="$SD/Emus/$PLATFORM/$PAK_NAME.pak"
    MON="$SD/Tools/$PLATFORM/Screenshot Monitor.pak"
    SHARED="$SD/.userdata/shared"
    LOGS="$SD/.userdata/$PLATFORM/logs"
    OUT="$OUT_DIR/e2e"
    BOOT_WAIT="${BOOT_WAIT:-20}"
    UI_WAIT="${UI_WAIT:-6}"
    KEY_GAP="${KEY_GAP:-0.5}"
    STATE_DIR="$SD/.userdata/shared/PSP-ppsspp"
    PNGCOLOR="$TESTS_DIR/bin/pngcolor"
    BAK="$SD/.userdata/shared/.psp-e2e-backup" # on the SD card, so a power loss cannot lose it

    # --- preflight (the checks that need ROM etc. come after they are found, below) ---
    PAD="$(awk '/^N: Name="TRIMUI Player1"/{f=1} f&&/^H: Handlers=/{for(i=1;i<=NF;i++) if($i ~ /^event/){print "/dev/input/" $i; exit}}' /proc/bus/input/devices)"
    INI="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    CONTROLS="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    # The Exit hotkey is always needed (EXIT_KEYS="" kills PPSSPP instead); Save State and
    # Next Slot only when PSP_KEYS is not given.
    cfg_init_hotkeys "$CONTROLS" "exit$([ -z "${PSP_KEYS+x}" ] && echo ' save next')"
    if [ -z "${PSP_KEYS+x}" ]; then
        PSP_KEYS="$SAVE_KEYS sleep3 shot $NEXT_SLOT_KEYS sleep1 shot $SAVE_KEYS sleep3 shot"
    elif [ -n "$PSP_KEYS" ] && ! bad="$(cfg_keys_valid "$PSP_KEYS")"; then
        HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}PSP_KEYS has a step the test cannot press: '$bad'"
    fi

    if [ -z "${ROM_DIR:-}" ]; then
        for d in "$SD"/Roms/*"(PSP)"; do
            [ -d "$d" ] && ROM_DIR="$d" && break
        done
    fi
    if [ -z "${ROM:-}" ] && [ -d "${ROM_DIR:-}" ]; then
        for f in "$ROM_DIR"/*; do
            [ -f "$f" ] && ROM="$f" && break
        done
    fi
    [ -f "${ROM:-}" ] || ROM="" # reported by the preflight below

    # Same emu tag NextUI uses: the text in the last (...) of the Roms folder name.
    tag="${ROM%/*}"
    tag="${tag#"$SD"/Roms/}"
    tag="${tag%%/*}"
    case "$tag" in *"("*")"*)
        tag="${tag##*(}"
        tag="${tag%%)*}"
        ;;
    esac
    ROM_FILE="$(basename "${ROM:-none}")"
    MINUI="$SHARED/.minui/$tag"
    SLOT_FILE="$MINUI/$ROM_FILE.txt"
    PREVIEW="$MINUI/$ROM_FILE.0.bmp" # slot 0, used by E1; E2 uses whatever slot the game saved
    RECENT="$SHARED/.minui/recent.txt"
    PERSIST="$SHARED/.minui/game_switcher.txt"
    AUTORESUME="$SHARED/.minui/auto_resume.txt"
    SHOTDIR="$SD/Screenshots"

    # ONE message with everything that must change, before anything is touched.
    if ! problems="$(e2e_preflight_problems)"; then
        fail "the device is not set up for this test, change this and run again:
$problems"
    fi
    info "hotkeys (read from the device):"
    info "$(printf '%s' "$HOTKEY_INFO" | sed 's/^/  /')"
    info "NextUI start screen: $(cfg_start_mode_info "$SHARED/minuisettings.txt") (the tests work in either mode)"

    export INI CONTROLS SAVE_KEYS NEXT_SLOT_KEYS SD PLATFORM PAK MON SHARED LOGS OUT BOOT_WAIT UI_WAIT KEY_GAP PSP_KEYS EXIT_KEYS \
        STATE_DIR PNGCOLOR BAK PAD ROM_DIR ROM tag ROM_FILE MINUI SLOT_FILE PREVIEW RECENT \
        PERSIST AUTORESUME SHOTDIR

    mkdir -p "$OUT" "$BAK"

    # --- back up everything we will touch ---
    if [ -f "$BAK/active" ]; then
        info "found the backup of an aborted run: restoring those files first"
        restore_files
        rm -f "$BAK/active"
    fi
    rm -f "${OUT:?}"/*.png "${OUT:?}"/*.log "${OUT:?}"/*.shotname \
        "${BAK:?}/present" "${BAK:?}/absent" "${BAK:?}/states.before" "${BAK:?}/marker"
    info "device pad: $PAD"
    info "game:       $ROM"
    info "emu tag:    $tag"

    # "active" is set before anything is copied or changed, so an abort at any point from here
    # on (also halfway through the stashing) is restored by teardown_file or the next run.
    : >"$BAK/active"
    sync
    for f in "$RECENT" "$PERSIST" "$AUTORESUME" "$SLOT_FILE" "$PREVIEW"; do stash "$f"; done
    for f in "$MINUI/$ROM_FILE".*.bmp; do [ -f "$f" ] && stash "$f"; done # previews of other slots
    sync

    # E1 starts from: the game in recents, slot 0 chosen.
    mkdir -p "$MINUI"
    seed_recent
    printf 0 >"$SLOT_FILE"
}

# After every test: undo a preview that a test renamed to .off, even when the test aborted.
teardown() {
    local off
    [ -n "${MINUI:-}" ] && [ -n "${ROM_FILE:-}" ] || return 0
    for off in "$MINUI/$ROM_FILE".*.bmp.off; do
        [ -f "$off" ] || continue
        if [ -e "${off%.off}" ]; then rm -f "$off"; else mv "$off" "${off%.off}"; fi
    done
    return 0
}

teardown_file() {
    # Only when the backup was made (setup_file may have failed in the preflight).
    [ -n "${BAK:-}" ] && [ -f "$BAK/active" ] || return 0
    killall PPSSPPSDL_"$PLATFORM" 2>/dev/null
    restore_files
    rm -f "$BAK/active"
    kill_ui # relaunches NextUI with the restored files
    echo "# restored; results in $OUT" >&3
}

# --- E1: NextUI renders the BMP that jpg2bmp makes ------------------------------------------
@test "E1 NextUI shows the red converted thumbnail in the Game Switcher" {
    "$PAK/bin/jpg2bmp" "$FIX/thumb1.jpg" "$PREVIEW"
    open_switcher
    shot e1-red
    have_shot e1-red
    is_red "$OUT/e1-red.png"
}

@test "E1 NextUI shows the blue converted thumbnail in the Game Switcher" {
    "$PAK/bin/jpg2bmp" "$FIX/thumb2.jpg" "$PREVIEW"
    open_switcher
    shot e1-blue
    have_shot e1-blue
    is_blue "$OUT/e1-blue.png"
}

@test "E1 no preview file: switcher shows neither fixture colour" {
    rm -f "$PREVIEW"
    open_switcher
    shot e1-nopreview
    have_shot e1-nopreview
    not_fixture "$OUT/e1-nopreview.png"
}

# --- E2: real PPSSPP run, exit, preview written, switcher shows it -------------------------
@test "E2 real PPSSPP starts and the game screenshot is named after the game" {
    local f name
    rm -f "$SLOT_FILE" "$PERSIST"
    for f in "$MINUI/$ROM_FILE".*.bmp; do [ -f "$f" ] && rm -f "$f"; done
    seed_recent
    mkdir -p "$STATE_DIR"
    ls -1 "$STATE_DIR" >"$BAK/states.before" 2>/dev/null
    touch "$BAK/marker"
    sleep 2 # FAT mtimes have 2 s resolution
    printf "'%s/launch.sh' '%s'\n" "$PAK" "$ROM" >/tmp/next
    kill_ui # the launcher loop then runs /tmp/next
    wait_for 60 running PPSSPPSDL || fail "PPSSPP did not start within 60 s"
    sleep "$BOOT_WAIT"

    shot e2-game
    have_shot e2-game
    name="$(cat "$OUT/e2-game.shotname")"
    info "screenshot name: $name"
    case "$name" in Screenshot.*) fail "game screenshot is not named after the game ($name)" ;; esac
}

@test "E2 PPSSPP exits and NextUI is back" {
    local i=0 k exit_ok=1
    for k in $PSP_KEYS; do
        i=$((i + 1))
        case "$k" in
        sleep*) sleep "${k#sleep}" ;;
        shot) shot "e2-step$i" ;;
        *)
            press "$k"
            sleep "$KEY_GAP"
            ;;
        esac
    done

    if [ -n "$EXIT_KEYS" ]; then
        press "$EXIT_KEYS"
        wait_for 20 not_running PPSSPPSDL || exit_ok=0
    fi
    running PPSSPPSDL && killall PPSSPPSDL_"$PLATFORM" 2>/dev/null
    wait_for 30 not_running PPSSPPSDL || fail "PPSSPP was still running 30 s after it was killed"
    wait_for 90 running nextui.elf || fail "NextUI did not come back within 90 s"
    sleep "$UI_WAIT"
    ls -l --full-time "$STATE_DIR" >"$OUT/e2-states.txt" 2>/dev/null || ls -l "$STATE_DIR" >"$OUT/e2-states.txt" 2>&1
    cp "$LOGS/PSP.txt" "$OUT/e2-PSP.log" 2>/dev/null
    [ "$exit_ok" = 1 ] || fail "PPSSPP did not exit on the Exit hotkey ($EXIT_KEYS) and had to be killed. Hotkeys used:
$HOTKEY_INFO Check the Exit App binding in PPSSPP's Controls > Hotkeys (or set EXIT_KEYS)"
}

@test "E2 no save state: no slot file, no preview image" {
    [ -z "$PSP_KEYS" ] || skip "PSP_KEYS is set: states are saved"
    assert_file_not_exist "$SLOT_FILE"
    run find "$MINUI" -name "$ROM_FILE.*.bmp"
    assert_output ""
}

@test "E2 no save state: switcher shows No Preview (neither fixture colour)" {
    [ -z "$PSP_KEYS" ] || skip "PSP_KEYS is set: states are saved"
    open_switcher
    shot e2-switcher
    have_shot e2-switcher
    not_fixture "$OUT/e2-switcher.png"
}

@test "E2 two save states were written (slot hotkey worked)" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    local n
    n="$(new_state_thumbs | wc -l)"
    info "new states: $n"
    [ "$n" -ge 2 ] || fail "$n new state(s), expected 2: PPSSPP did not react to the keys that were pressed. Hotkeys used:
$HOTKEY_INFO Check the bindings in PPSSPP's Controls > Hotkeys (or set SAVE_KEYS/NEXT_SLOT_KEYS)"
}

@test "E2 slot file holds the newest state's slot" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    local slot
    slot="$(newest_state_slot)"
    info "newest state slot: $slot"
    [ -n "$slot" ]
    grep -qx "$slot" "$SLOT_FILE"
}

@test "E2 preview file is written for that slot and is a BMP/PNG" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    local preview
    preview="$MINUI/$ROM_FILE.$(newest_state_slot).bmp"
    assert_file_not_empty "$preview"
    is_image "$preview"
}

@test "E2 log: preview from save state" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    run sh -c "grep -v '^+' '$OUT/e2-PSP.log' | grep -q 'Game switcher preview from save state'"
    assert_success
}

@test "E2 preview is the newest state's thumbnail" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    local newest
    newest="$(newest_state_thumb)"
    [ -n "$newest" ] || fail "no new state thumbnail was found to compare the preview with"
    "$PAK/bin/jpg2bmp" "$newest" "$BAK/expected.bmp"
    info "thumbnail: $(basename "$newest")"
    assert_same "$MINUI/$ROM_FILE.$(newest_state_slot).bmp" "$BAK/expected.bmp"
}

@test "E2 the preview changes what the switcher shows" {
    [ -n "$PSP_KEYS" ] || skip "PSP_KEYS is empty: no states are saved"
    local preview
    preview="$MINUI/$ROM_FILE.$(newest_state_slot).bmp"
    open_switcher
    shot e2-switcher
    have_shot e2-switcher
    mv "$preview" "$preview.off" # put back by teardown (and restore_files) if this test aborts
    open_switcher
    shot e2-switcher-nopreview
    mv "$preview.off" "$preview"
    have_shot e2-switcher-nopreview
    assert_differ "$OUT/e2-switcher.png" "$OUT/e2-switcher-nopreview.png"
}

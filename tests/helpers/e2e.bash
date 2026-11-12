# shellcheck shell=bash
# Helpers for tests/bats/e2e.bats: drive the real NextUI on a TrimUI device.
#   - buttons are injected by writing evdev events to the "TRIMUI Player1" pad,
#   - games are launched through NextUI's own /tmp/next hand-off,
#   - screenshots are taken with the "Screenshot Monitor" pak's bin/screenshot,
#   - screenshots are judged by the bundled pngcolor (average colour of the screen centre).
# The settings (SD, PAD, ROM, OUT, BAK, ...) are exported by setup_file in e2e.bats.

# NEVER send SIGTERM to nextui.elf: SDL turns it into SDL_QUIT, which NextUI handles as
# PWR_powerOff(0) and the device shuts down. SIGKILL has no handler: NextUI just dies and the
# launcher loop in MinUI.pak starts it again (that is also what happens when it crashes).
kill_ui() { killall -9 nextui.elf 2>/dev/null; }

# --- back up everything the test touches, restore on exit ---------------------------------
# The backup lives on the SD card. If a run is cut short (power loss, SIGKILL), the next run
# first puts the files back from it.
restore_files() {
    local f
    rm -f /tmp/next
    # controls.ini: the tests may have bound hotkeys in it (devconfig.bash). If it is not what
    # they left (PPSSPP or the user changed it since) its current content is kept next to the
    # backup before the original is put back, so nothing is lost.
    if [ -f "$BAK/controls.written" ] && [ -n "${CONTROLS:-}" ]; then
        if [ -f "$CONTROLS" ] && ! cmp -s "$BAK/controls.written" "$CONTROLS"; then
            cp -p "$CONTROLS" "$BAK/controls.ini.replaced"
            echo "WARNING: $CONTROLS changed during the run; the original is restored, the changed file is kept as $BAK/controls.ini.replaced" >&2
        fi
        rm -f "$BAK/controls.written" "$BAK/controls.bound"
    fi
    if [ -f "$BAK/present" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && cp -p "$BAK$f" "$f"
        done <"$BAK/present"
    fi
    if [ -f "$BAK/absent" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && rm -f "$f"
        done <"$BAK/absent"
    fi
    rm -f "$PERSIST.tmp"
    # delete previews of other slots that the test created, and any preview a test renamed
    # to .bmp.off (the restore above has already put back the ones that existed before)
    for f in "$MINUI/$ROM_FILE".*.bmp "$MINUI/$ROM_FILE".*.bmp.off; do
        [ -f "$f" ] && ! grep -qxF "$f" "$BAK/present" 2>/dev/null && rm -f "$f"
    done
    # delete save states the test created (files that were not there before)
    if [ -f "$BAK/states.before" ]; then
        for f in "$STATE_DIR"/*; do
            [ -f "$f" ] && ! grep -qxF "$(basename "$f")" "$BAK/states.before" && rm -f "$f"
        done
    fi
    sync
    return 0
}

stash() {
    if [ -e "$1" ]; then
        mkdir -p "$BAK$(dirname "$1")"
        cp -p "$1" "$BAK$1"
        echo "$1" >>"$BAK/present"
    else
        echo "$1" >>"$BAK/absent"
    fi
}

# --- helpers ---------------------------------------------------------------------------
wait_for() { # wait_for <seconds> <command...>
    local n="$1"
    shift
    while [ "$n" -gt 0 ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 1
        n=$((n - 1))
    done
    return 1
}
running() { pgrep "$1" >/dev/null 2>&1; }
not_running() { ! pgrep "$1" >/dev/null 2>&1; }

octal_byte() { printf '\\%03o' $(($1 & 255)); }

# Write one evdev event (24 bytes: 16 zero timestamp bytes, type, code, value) to the pad.
pad() { # pad <type> <code> <value>
    local v=$(($3 & 4294967295))
    # shellcheck disable=SC2059 # the format is built from octal escapes on purpose
    printf "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0$(octal_byte "$1")$(octal_byte $(($1 >> 8)))$(octal_byte "$2")$(octal_byte $(($2 >> 8)))$(octal_byte "$v")$(octal_byte $((v >> 8)))$(octal_byte $((v >> 16)))$(octal_byte $((v >> 24)))" >"$PAD"
}
syn() { pad 0 0 0; }

# Sets ev_type, ev_code and ev_val (value while pressed) for a button name.
btn_set() {
    ev_val=1
    case "$1" in
    b) ev_type=1 ev_code=304 ;;
    a) ev_type=1 ev_code=305 ;;
    y) ev_type=1 ev_code=307 ;;
    x) ev_type=1 ev_code=308 ;;
    l1) ev_type=1 ev_code=310 ;;
    r1) ev_type=1 ev_code=311 ;;
    select) ev_type=1 ev_code=314 ;;
    start) ev_type=1 ev_code=315 ;;
    left) ev_type=3 ev_code=16 ev_val=-1 ;;
    right) ev_type=3 ev_code=16 ;;
    up) ev_type=3 ev_code=17 ev_val=-1 ;;
    down) ev_type=3 ev_code=17 ;;
    *)
        echo "unknown button: $1" >&2
        return 1
        ;;
    esac
}

# press <button>[+<button>...]: a tap, or a chord (all held together, then released).
press() {
    local keys k hold=0.05 # short, or NextUI's key repeat moves the selection more than once
    keys="$(printf '%s' "$1" | tr '+' ' ')"
    case "$1" in *+*) hold="${CHORD_HOLD:-0.3}" ;; esac
    for k in $keys; do
        btn_set "$k" || return 1
        pad "$ev_type" "$ev_code" "$ev_val"
        syn
    done
    sleep "$hold"
    for k in $keys; do
        btn_set "$k"
        pad "$ev_type" "$ev_code" 0
        syn
    done
}

colour() { "$PNGCOLOR" "$1" 2>/dev/null; } # prints "R G B"

# shot <label>: takes a screenshot with the Screenshot Monitor pak. The image is kept as
# $OUT/<label>.png and the name the pak gave it in $OUT/<label>.shotname.
shot() {
    local before newest
    sleep 1 # the pak names files by the second
    before="$(ls "$SHOTDIR" 2>/dev/null)"
    SDCARD_PATH="$SD" PATH="$MON/bin/$PLATFORM:$MON/bin:$PATH" sh "$MON/bin/screenshot" >"$OUT/$1.shot.log" 2>&1
    # shellcheck disable=SC2012 # names come from the screenshot pak (date based), ls -t is fine
    newest="$(ls -t "$SHOTDIR" 2>/dev/null | head -n 1)"
    rm -f "$OUT/$1.png" "$OUT/$1.shotname"
    if [ -n "$newest" ] && ! printf '%s\n' "$before" | grep -qxF "$newest"; then
        mv "$SHOTDIR/$newest" "$OUT/$1.png"
        echo "$newest" >"$OUT/$1.shotname"
        info "$1.png average colour (R G B): $(colour "$OUT/$1.png")"
    else
        info "$1: no screenshot was written (see $OUT/$1.shot.log)"
    fi
}

have_shot() {
    [ -s "$OUT/$1.png" ] || {
        echo "no screenshot named $1 was taken (missing or empty $OUT/$1.png)" >&2
        return 1
    }
}

# shellcheck disable=SC2046,SC2086 # word splitting of "R G B" is intended
_is_red() { set -- $(colour "$1"); [ -n "$3" ] && [ "$1" -gt $(($2 + 60)) ] && [ "$1" -gt $(($3 + 60)) ]; }
# shellcheck disable=SC2046,SC2086
_is_blue() { set -- $(colour "$1"); [ -n "$3" ] && [ "$3" -gt $(($1 + 60)) ] && [ "$3" -gt $(($2 + 60)) ]; }
is_red() { _is_red "$1" || { echo "the centre of $1 is not red (colour: $(colour "$1"))" >&2; return 1; }; }
is_blue() { _is_blue "$1" || { echo "the centre of $1 is not blue (colour: $(colour "$1"))" >&2; return 1; }; }
not_fixture() {
    if _is_red "$1" || _is_blue "$1"; then
        echo "$1 shows a fixture colour, expected No Preview (colour: $(colour "$1"))" >&2
        return 1
    fi
}

# NextUI keeps recents relative to the SD card ("/Roms/..."), so it works on every platform.
# An absolute path is not found and NextUI drops it, rewriting recent.txt empty.
seed_recent() { mkdir -p "$(dirname "$RECENT")" && printf '%s\n' "${ROM#"$SD"}" >"$RECENT"; }

restart_ui() {
    kill_ui
    sleep 1
    wait_for 40 running nextui.elf || {
        echo "NextUI did not come back within 40 s of being restarted" >&2
        return 1
    }
    sleep "$UI_WAIT"
}

open_switcher() { # restarts NextUI directly into the Game Switcher
    printf unused >"$PERSIST"
    restart_ui
}

is_image() {
    head -c 2 "$1" | grep -q BM || head -c 4 "$1" | tail -c 3 | grep -q PNG || {
        echo "$1 is neither a BMP nor a PNG" >&2
        return 1
    }
}

# The newest save state thumbnail made since the test marked its start ("" if none).
new_state_thumbs() { find "$STATE_DIR" -name '*.jpg' ! -name '*undo*' -newer "$BAK/marker"; }
newest_state_thumb() {
    local thumbs
    thumbs="$(new_state_thumbs)"
    [ -n "$thumbs" ] || return 0 # (ls with no argument would list the current directory)
    # shellcheck disable=SC2012,SC2086 # state names are PPSSPP's (no spaces); splitting is intended
    ls -t $thumbs 2>/dev/null | head -n 1
}
newest_state_slot() {
    local s
    s="$(newest_state_thumb)"
    s="${s%.jpg}"
    printf '%s' "${s##*_}"
}

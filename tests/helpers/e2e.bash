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
# ONE backup directory ($BAK, on the SD card) and ONE "active" flag are shared by e2e.bats and
# reboot.bats: a run that finds an active backup, whichever test made it, restores it first and
# then starts clean. psp_backup / psp_restore below are used by both.

cfg_stamp() { echo "$(date +%Y%m%dT%H%M%S 2>/dev/null)-$$-$RANDOM"; }

# stash <file>: copies it into $BAK byte for byte and records it as present (or as absent).
# Fails, recording nothing, when the copy is not identical (full SD card).
stash() {
    if [ -e "$1" ]; then
        if ! { mkdir -p "$BAK$(dirname "$1")" && cp -p "$1" "$BAK$1" && cmp -s "$1" "$BAK$1"; }; then
            echo "could not back up $1 into $BAK (SD card full?)" >&2
            return 1
        fi
        echo "$1" >>"$BAK/present"
    else
        echo "$1" >>"$BAK/absent"
    fi
}

# snapshot_left <file>: what the tests (or PPSSPP, after it stopped) left in a settings file.
snapshot_left() {
    mkdir -p "$BAK/left$(dirname "$1")" && cp -p "$1" "$BAK/left$1"
}

# guard_changed <file>: a settings file (controls.ini, ppsspp.ini) is only put back over what is
# there when that is the backup or what the tests left; anything else (the user edited it, an
# earlier run was cut short half way through) is kept next to it as <file>.replaced.<unique>.
guard_changed() {
    local f="$1"
    [ -f "$f" ] && grep -qxF -- "$f" "$BAK/present" 2>/dev/null || return 0
    cmp -s "$f" "$BAK$f" && return 0
    [ -f "$BAK/left$f" ] && cmp -s "$f" "$BAK/left$f" && return 0
    cp -p "$f" "$f.replaced.$(cfg_stamp)"
    echo "WARNING: $f is neither the backup nor what the tests left; the original is restored, the file as it was is kept as $f.replaced.*" >&2
}

restore_files() {
    local f rc=0
    rm -f /tmp/next
    [ -n "${CONTROLS:-}" ] && guard_changed "$CONTROLS"
    [ -n "${INI:-}" ] && guard_changed "$INI"
    if [ -f "$BAK/present" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            cp -p "$BAK$f" "$f" || { echo "could not restore $f from $BAK$f" >&2; rc=1; }
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
    return "$rc"
}

# Copies every save state file (a test overwrites a slot) into $BAK/states, checked.
backup_states() {
    local f
    mkdir -p "$STATE_DIR"
    ls -1 "$STATE_DIR" >"$BAK/states.before" 2>/dev/null
    rm -rf "$BAK/states"
    mkdir -p "$BAK/states" || return 1
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        if ! { cp -p "$f" "$BAK/states/" && cmp -s "$f" "$BAK/states/${f##*/}"; }; then
            echo "could not back up $f (SD card full?)" >&2
            return 1
        fi
    done
    sync
}
# Puts back the state files that were changed or deleted.
restore_states() {
    local f n rc=0
    [ -d "$BAK/states" ] || return 0
    for f in "$BAK/states"/*; do
        [ -f "$f" ] || continue
        n="$STATE_DIR/${f##*/}"
        cmp -s "$f" "$n" 2>/dev/null || cp -p "$f" "$n" || rc=1
    done
    sync
    return "$rc"
}

# Stops PPSSPP for good and waits (bounded: E2E_STOP_TIMEOUT, 90 s) until nothing of a game is
# left: PPSSPP is killed (SIGKILL, nothing is saved) whenever it shows up, and a game that is
# still starting or that launch.sh is still wrapping up counts as running because NextUI is only
# back once launch.sh has finished. PPSSPP rewrites its ini files when it exits, which must not
# happen after they are restored. Fails when it cannot get there.
e2e_stop_game() {
    local n=0 limit="${E2E_STOP_TIMEOUT:-90}"
    while :; do
        if pgrep PPSSPPSDL >/dev/null 2>&1; then
            killall -9 "PPSSPPSDL_${PLATFORM:-}" 2>/dev/null
        elif pgrep nextui.elf >/dev/null 2>&1; then
            return 0
        fi
        if [ "$n" -ge "$limit" ]; then
            echo "a game was still running or starting after ${limit}s (NextUI is not back)" >&2
            return 1
        fi
        sleep 1
        n=$((n + 1))
    done
}

# psp_backup: the backup of everything the tests touch (needs RECENT PERSIST AUTORESUME SLOT_FILE
# PREVIEW INI CONTROLS MINUI ROM_FILE STATE_DIR BAK). A leftover active backup, from whichever
# test, is restored first. "active" is set before anything is copied, so an abort at any point is
# restored by the next run; a backup that cannot be made completely leaves nothing behind and
# fails before anything was changed.
psp_backup() {
    local f
    mkdir -p "$BAK" "$MINUI" || return 1
    if [ -f "$BAK/active" ]; then
        echo "found the backup of an aborted run: restoring those files first"
        psp_restore recover || return 1
    fi
    rm -rf "$BAK/left" "$BAK/states"
    rm -f "$BAK/present" "$BAK/absent" "$BAK/states.before" "$BAK/marker" "$BAK/controls.bound"
    : >"$BAK/active"
    sync
    for f in "$RECENT" "$PERSIST" "$AUTORESUME" "$SLOT_FILE" "$PREVIEW" "$INI" "$CONTROLS"; do
        stash "$f" || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    done
    for f in "$MINUI/$ROM_FILE".*.bmp; do # previews of other slots
        [ -f "$f" ] || continue
        stash "$f" || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    done
    backup_states || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    sync
}

# psp_restore normal|recover: stops the game, then puts everything back. "normal" (the end of a
# run) first notes what PPSSPP left in the settings files after it stopped, so its own rewrite is
# not taken for a foreign change; "recover" (a cut-short run) keeps anything unexpected. On a
# failure the backup stays (active) so that the next run tries again, and says where it is.
psp_restore() {
    local f rc=0
    ${PSP_STOP_GAME:-e2e_stop_game} || {
        echo "WARNING: not restored (a game is still running); the backup stays in $BAK and is restored by the next run" >&2
        return 1
    }
    if [ "$1" = normal ]; then
        for f in "${CONTROLS:-}" "${INI:-}"; do
            [ -n "$f" ] && [ -f "$f" ] && snapshot_left "$f"
        done
    fi
    restore_files || rc=1
    restore_states || rc=1
    if [ "$rc" != 0 ]; then
        echo "WARNING: some files could not be restored; the backup stays in $BAK and is restored by the next run" >&2
        return 1
    fi
    # nothing may point at the stash any more: a later run must not copy it over the file again
    rm -f "$BAK/present" "$BAK/absent" "$BAK/active"
    rm -rf "$BAK/states" "$BAK/left"
    return 0
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

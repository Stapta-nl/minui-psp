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
# then starts clean. The "active" file holds the id of the run that made the backup
# (PSP_RUN_ID, known only once psp_backup succeeded): the end of a run restores NORMALLY only a
# backup that run made; any other backup is restored in the strict "recover" mode.
#
# Every restore is careful with the user's files: a file is put back over what is there only if
# that is the backup or what the tests left; anything else is kept as <file>.replaced.<unique>
# (with a warning) first, files are replaced atomically (copy next to it, compare, rename), nothing
# is deleted that the tests did not provably create, and the backup stays active until every
# file has been verified.

cfg_stamp() { echo "$(date +%Y%m%dT%H%M%S 2>/dev/null)-$$-$RANDOM"; }

# stash <file>: copies it into $BAK byte for byte and records it as present (or as absent).
# Fails, recording nothing, when the copy or the record cannot be made (full SD card).
stash() {
    if [ -e "$1" ]; then
        if ! { mkdir -p "$BAK$(dirname "$1")" && cp -p "$1" "$BAK$1" && cmp -s "$1" "$BAK$1" && echo "$1" >>"$BAK/present"; }; then
            echo "could not back up $1 into $BAK (SD card full?)" >&2
            return 1
        fi
    else
        echo "$1" >>"$BAK/absent" || {
            echo "could not write $BAK/absent (SD card full?)" >&2
            return 1
        }
    fi
}

# snapshot_left <file>: what the tests, or PPSSPP after it stopped, left in a file.
snapshot_left() {
    mkdir -p "$BAK/left$(dirname "$1")" && cp -p "$1" "$BAK/left$1"
}
# Notes the settings files as they are now (after the game was stopped; also when the tests wrote
# them): PPSSPP's own rewrite when it exits is then not mistaken for somebody else's change.
snapshot_settings() {
    local f
    [ -f "$BAK/active" ] || return 0
    for f in "${CONTROLS:-}" "${INI:-}"; do
        [ -n "$f" ] && [ -f "$f" ] && grep -qxF -- "$f" "$BAK/present" 2>/dev/null && snapshot_left "$f"
    done
    return 0
}
# Every backed up file (and every one that did not exist) as it is now, for a normal end of run.
snapshot_all() {
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] && snapshot_left "$f"
    done < <(cat "$BAK/present" "$BAK/absent" 2>/dev/null)
    return 0
}

# keep_copy <file>: keeps the file as it is under a unique name next to it.
keep_copy() {
    local c
    c="$1.replaced.$(cfg_stamp)"
    cp -p "$1" "$c" || {
        echo "could not keep a copy of $1 (SD card full?): it is left as it is" >&2
        return 1
    }
    echo "WARNING: $1 is neither the backup nor what the tests left; the file as it was is kept as $c" >&2
}

# guard_changed <file>: succeeds when the live file may be overwritten (or does not exist): it is
# the backup or what the tests left, or a copy of it was kept.
guard_changed() {
    local f="$1"
    [ -f "$f" ] || return 0
    [ -f "$BAK$f" ] && cmp -s "$f" "$BAK$f" && return 0
    [ -f "$BAK/left$f" ] && cmp -s "$f" "$BAK/left$f" && return 0
    keep_copy "$f"
}

# restore_one <file>: atomic and guarded.
restore_one() {
    local f="$1" tmp="$1.psp-restore.$$"
    guard_changed "$f" || return 1
    if cp -p "$BAK$f" "$tmp" && cmp -s "$tmp" "$BAK$f" && mv -f "$tmp" "$f"; then
        return 0
    fi
    rm -f "$tmp"
    echo "could not restore $f from $BAK$f (SD card full?): it is left as it is" >&2
    return 1
}

# remove_created <file>: removes a file that did not exist when the backup was made, after a copy
# is kept unless it is what the tests left.
remove_created() {
    [ -e "$1" ] || return 0
    guard_changed "$1" || return 1
    rm -f "$1" || return 1
}

# The files, the previews of the test game and (normal end of run only) the save states made
# since the backup. PSP_RESTORE_MODE is normal or recover (set by psp_restore; direct callers get
# the strict one).
restore_files() {
    local f rc=0 mode="${PSP_RESTORE_MODE:-recover}" n
    rm -f /tmp/next
    if [ -f "$BAK/present" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            restore_one "$f" || rc=1
        done <"$BAK/present"
    fi
    if [ -f "$BAK/absent" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            remove_created "$f" || rc=1
        done <"$BAK/absent"
    fi
    rm -f "$PERSIST.tmp"
    # previews of other slots that were made since (and any preview a test renamed to .bmp.off):
    # the files that existed before are in the backup
    for f in "$MINUI/$ROM_FILE".*.bmp "$MINUI/$ROM_FILE".*.bmp.off; do
        [ -f "$f" ] || continue
        grep -qxF -- "$f" "$BAK/present" 2>/dev/null && continue
        remove_created "$f" || rc=1
    done
    # save states made since the backup: only at a normal end of run (nobody else was at the
    # device), only files that are new (not in states.before and newer than the backup), never in
    # the strict mode: a state of another game that appeared after a cut-short run stays
    if [ "$mode" = normal ] && [ -f "$BAK/states.before" ] && [ -f "$BAK/active" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n="${f##*/}"
            grep -qxF -- "$n" "$BAK/states.before" && continue
            rm -f "$f" || rc=1
        done < <(find "$STATE_DIR" -maxdepth 1 -type f -newer "$BAK/active" 2>/dev/null)
    fi
    sync
    # verified: every backed up file is what the backup holds
    if [ -f "$BAK/present" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            cmp -s "$BAK$f" "$f" || { echo "NOT restored: $f" >&2; rc=1; }
        done <"$BAK/present"
    fi
    return "$rc"
}

# Copies every save state file (a test overwrites a slot) into $BAK/states, checked.
backup_states() {
    local f
    if ! { mkdir -p "$STATE_DIR" && ls -1 "$STATE_DIR" >"$BAK/states.before" 2>/dev/null; }; then
        echo "could not write $BAK/states.before" >&2
        return 1
    fi
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
# Puts back the state files that were changed or deleted (atomic; in the strict mode a state that
# is neither the backup nor what was there is kept as .replaced first).
restore_states() {
    local f n tmp rc=0
    [ -d "$BAK/states" ] || return 0
    for f in "$BAK/states"/*; do
        [ -f "$f" ] || continue
        n="$STATE_DIR/${f##*/}"
        cmp -s "$f" "$n" 2>/dev/null && continue
        if [ "${PSP_RESTORE_MODE:-recover}" != normal ] && [ -f "$n" ]; then
            keep_copy "$n" || { rc=1; continue; }
        fi
        tmp="$n.psp-restore.$$"
        if cp -p "$f" "$tmp" && cmp -s "$tmp" "$f" && mv -f "$tmp" "$n"; then :; else
            rm -f "$tmp"
            rc=1
        fi
    done
    sync
    return "$rc"
}

# Stops PPSSPP for good and waits (bounded: E2E_STOP_TIMEOUT, 90 s) until nothing of a game is
# left: PPSSPP is killed (SIGKILL, nothing is saved) whenever it shows up, and a game that is
# still starting or that launch.sh is still wrapping up counts as running because NextUI is only
# back once launch.sh has finished. PPSSPP rewrites its ini files when it exits, which must not
# happen after they are restored. Fails when it cannot get there. On success the settings files
# are noted as they are (see snapshot_settings).
e2e_stop_game() {
    local n=0 limit="${E2E_STOP_TIMEOUT:-90}"
    while :; do
        if pgrep PPSSPPSDL >/dev/null 2>&1; then
            killall -9 "PPSSPPSDL_${PLATFORM:-}" 2>/dev/null
        elif pgrep nextui.elf >/dev/null 2>&1; then
            # (not while recovering a cut-short run: what is there then must not become "expected")
            [ -n "${PSP_NO_SNAPSHOT:-}" ] || snapshot_settings
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

# psp_restore_dir <dir>: restores the backup in another directory (an older version's), strictly.
psp_restore_dir() {
    local saved="$BAK" rc=0
    BAK="$1"
    # the older versions kept what the tests left in controls.written / ini.written
    [ -f "$BAK/controls.written" ] && [ -n "${CONTROLS:-}" ] && { mkdir -p "$BAK/left$(dirname "$CONTROLS")" && cp -p "$BAK/controls.written" "$BAK/left$CONTROLS"; }
    [ -f "$BAK/ini.written" ] && [ -n "${INI:-}" ] && { mkdir -p "$BAK/left$(dirname "$INI")" && cp -p "$BAK/ini.written" "$BAK/left$INI"; }
    psp_restore recover || rc=1
    BAK="$saved"
    return "$rc"
}

# psp_backup: the backup of everything the tests touch (needs RECENT PERSIST AUTORESUME SLOT_FILE
# PREVIEW INI CONTROLS MINUI ROM_FILE STATE_DIR BAK SHARED). A leftover active backup, from
# whichever test or from an older version (the per-test directories), is restored first.
# "active" is set before anything is copied, so an abort at any point is restored by the next
# run; a backup that cannot be made completely leaves nothing behind and fails before anything
# was changed. Sets and exports PSP_RUN_ID only when it succeeded.
psp_backup() {
    local f d id
    mkdir -p "$BAK" "$MINUI" || return 1
    for d in "$SHARED/.psp-e2e-backup" "$SHARED/.psp-reboot-backup"; do
        [ -f "$d/active" ] || continue
        echo "found the backup of a cut-short run of an older version in $d: restoring those files first"
        if psp_restore_dir "$d"; then
            mv "$d" "$d.restored.$(cfg_stamp)" || rm -f "$d/active"
        else
            echo "could not restore $d: fix that (see above) or restore the files by hand and remove $d/active" >&2
            return 1
        fi
    done
    if [ -f "$BAK/active" ]; then
        echo "found the backup of an aborted run: restoring those files first"
        psp_restore recover || return 1
    fi
    rm -rf "$BAK/left" "$BAK/states"
    rm -f "$BAK/present" "$BAK/absent" "$BAK/states.before" "$BAK/marker" "$BAK/controls.bound"
    id="$(cfg_stamp)"
    printf '%s\n' "$id" >"$BAK/active" || {
        echo "could not write $BAK/active (SD card full?)" >&2
        return 1
    }
    sync
    for f in "$RECENT" "$PERSIST" "$AUTORESUME" "$SLOT_FILE" "$PREVIEW" "$INI" "$CONTROLS"; do
        stash "$f" || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    done
    for f in "$MINUI/$ROM_FILE".*.bmp; do # previews of other slots
        [ -f "$f" ] || continue
        stash "$f" || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    done
    backup_states || { rm -f "$BAK/active" "$BAK/present" "$BAK/absent"; return 1; }
    # the settings files as they are now: what the tests will start from
    snapshot_settings
    sync
    PSP_RUN_ID="$id"
    export PSP_RUN_ID
}

# psp_restore normal|recover: stops the game, then puts everything back. "normal" (the end of a
# run that made the backup) first notes the files as they are after PPSSPP stopped, so that
# PPSSPP's own rewrite is not taken for a foreign change; "recover" keeps anything unexpected as
# .replaced and never deletes save states. On a failure the backup stays active, so the next run
# tries again, and says where it is.
psp_restore() {
    local rc=0 PSP_RESTORE_MODE="$1" PSP_NO_SNAPSHOT=""
    [ "$1" = normal ] || PSP_NO_SNAPSHOT=1
    ${PSP_STOP_GAME:-e2e_stop_game} || {
        echo "WARNING: not restored (a game is still running or starting); the backup stays in $BAK and is restored by the next run" >&2
        return 1
    }
    [ "$PSP_RESTORE_MODE" = normal ] && snapshot_all
    restore_files || rc=1
    restore_states || rc=1
    if [ "$rc" != 0 ]; then
        echo "WARNING: some files could not be restored; the backup stays in $BAK and is restored by the next run" >&2
        return 1
    fi
    # nothing may point at the stash any more: a later run must not copy it over the file again
    if ! { rm -rf "$BAK/states" "$BAK/left" && rm -f "$BAK/present" "$BAK/absent" "$BAK/active"; }; then
        echo "WARNING: could not clean up $BAK; the files are restored" >&2
        return 1
    fi
    return 0
}

# psp_finish: the end of a run. A backup that THIS run made (its id is in PSP_RUN_ID) is restored
# normally; any other active backup (a leftover of a cut-short run, when this run failed before its
# own backup) strictly. Nothing to do without an active backup.
psp_finish() {
    [ -f "$BAK/active" ] || return 0
    if [ -n "${PSP_RUN_ID:-}" ] && [ "$(cat "$BAK/active" 2>/dev/null)" = "$PSP_RUN_ID" ]; then
        psp_restore normal
    else
        psp_restore recover
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

# --- deterministic "settled" signals (instead of fixed sleeps) ---------------------------------
# E2E_POLL_HOOK (a command, set by the reboot kit) runs on every poll of the settle loops, to keep
# the device awake. All loops poll every second; the limits are only backups.

# touch_marker <file>: touches the file and returns once the file system clock has moved past
# its mtime, so that anything written afterwards is NEWER than the file (FAT mtimes have 2 s
# resolution: a state written within the same 2 s would not count as new). Polls a second
# probe file instead of sleeping 2 s: ends as soon as the clock ticks (no wait at all on
# file systems with finer timestamps). The 10 s limit is a backup.
touch_marker() {
    local f="$1" p="$1.tick.$$" n=0
    touch "$f" || return 1
    while [ "$n" -lt 50 ]; do
        touch "$p"
        if [ "$p" -nt "$f" ]; then rm -f "$p"; return 0; fi
        sleep 0.2 # poll step of the loop above
        n=$((n + 1))
    done
    rm -f "$p"
    echo "the file system clock did not move past $f within 10 s" >&2
    return 1
}

# The lowest pid of the processes of that name ("" if none): pgrep lists them in pid order.
first_pid() { pgrep "$1" 2>/dev/null | head -n 1; }

# wait_ui_settled <stable s> <limit s>: NextUI is up, and it and its launcher are quiet: the SAME
# nextui.elf process for <stable> consecutive polls (a NextUI that restarts, or that exits to
# launch a game through /tmp/next, starts the count again) and no emulator. This is the "nothing
# happened" signal for the absence checks (no auto-launch, no marker): an auto-resume acts
# within a second or two of NextUI's start. Fails after <limit> s (the old fixed wait is the
# backup) and says what it saw.
wait_ui_settled() {
    local stable="$1" limit="$2" n=0 ok=0 pid last="" game=""
    while :; do
        "${E2E_POLL_HOOK:-:}" || true
        pid="$(first_pid nextui.elf)"
        game=""
        pgrep PPSSPPSDL >/dev/null 2>&1 && game=1
        if [ -n "$pid" ] && [ "$pid" = "$last" ] && [ -z "$game" ]; then ok=$((ok + 1)); else ok=0; fi
        last="$pid"
        [ "$ok" -ge "$stable" ] && return 0
        if [ "$n" -ge "$limit" ]; then
            echo "NextUI did not settle within ${limit}s (nextui.elf pid: ${pid:-none}${game:+, a game is running}; quiet polls: $ok of $stable)" >&2
            return 1
        fi
        sleep 1
        n=$((n + 1))
    done
}

# True if the emulator runs with the test ROM as its argument. The command lines are read from
# /proc and matched on argv[0] and the arguments, never on the whole text: the ssh call that
# runs this contains the ROM's name too.
rb_rom_running() {
    local p first line args
    for p in /proc/[0-9]*/cmdline; do
        [ -r "$p" ] || continue
        args="$(tr '\0' '\n' <"$p" 2>/dev/null)"
        first="${args%%$'\n'*}"
        case "${first##*/}" in PPSSPPSDL*) ;; *) continue ;; esac
        while IFS= read -r line; do
            [ "$line" = "$ROM" ] && return 0
        done <<<"$args"
    done
    return 1
}

# wait_game_settled <stable s> <limit s>: the emulator runs the test ROM and has done so, as the
# SAME process, for <stable> consecutive polls. There is no log line or file that says "PPSSPP can
# take hotkeys now", so the settle count stays (see BOOT_SETTLE in the README), but what the old
# fixed sleep could not do: a game that dies while starting ends the wait at once, with an error.
# Waits up to <limit> s for the game to appear (the old fixed wait is the backup).
wait_game_settled() {
    local stable="$1" limit="$2" n=0 ok=0 pid last="" seen=""
    while :; do
        "${E2E_POLL_HOOK:-:}" || true
        pid=""
        rb_rom_running && pid="$(first_pid PPSSPPSDL)"
        if [ -n "$pid" ]; then
            seen=1
            if [ "$pid" = "$last" ]; then ok=$((ok + 1)); else ok=0; fi
        else
            ok=0
            if [ -n "$seen" ]; then
                echo "the game exited or was restarted while it was starting (see PSP.txt)" >&2
                return 1
            fi
        fi
        last="$pid"
        [ "$ok" -ge "$stable" ] && return 0
        if [ "$n" -ge "$limit" ]; then
            echo "the game was not running steadily within ${limit}s (pid: ${pid:-none}; steady polls: $ok of $stable)" >&2
            return 1
        fi
        sleep 1
        n=$((n + 1))
    done
}

# e2e_settle_count <override> <wait>: how many quiet polls (seconds) a settle waits for: the explicit
# override (BOOT_SETTLE, UI_SETTLE, NOGAME_SETTLE) when it is a whole number, else the configured
# fixed wait itself (BOOT_WAIT, UI_WAIT, NOGAME_WAIT; a fraction is cut to whole seconds). So the
# old duration is the MINIMUM by default and a user who raises the WAIT gets at least that; only an
# explicit *_SETTLE lowers it. The upper bound of a settle is that count plus the WAIT again.
e2e_settle_count() {
    local o="$1" w="${2%%.*}"
    case "$w" in "" | *[!0-9]*) w=0 ;; esac
    case "$o" in "" | *[!0-9]*) echo "$w" ;; *) echo "$o" ;; esac
}
# e2e_whole <n>: the whole seconds of a wait ("6.5" gives 6, junk gives 0).
e2e_whole() {
    local w="${1%%.*}"
    case "$w" in "" | *[!0-9]*) w=0 ;; esac
    echo "$w"
}

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
    sleep "$hold" # input injection: the buttons must be down for a moment (a chord needs them together); no signal exists
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
    # The pak names files by the second, and the screen needs a moment to show what the last key
    # did: no signal exists for "drawn" (a frame-stable check would need two screenshots), so the
    # fixed second stays.
    sleep 1
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

# restart_ui: kills NextUI and waits until the NEW process is up and settled (the same pid for
# UI_SETTLE polls, default UI_WAIT: the old render delay is kept, no signal says "drawn"). The old process being gone is detected by its
# pid, not by a fixed pause.
restart_ui() {
    local old
    old="$(first_pid nextui.elf)"
    kill_ui
    wait_for 40 sh -c "p=\$(pgrep nextui.elf | head -n 1); [ -n \"\$p\" ] && [ \"\$p\" != '$old' ]" || {
        echo "NextUI did not come back within 40 s of being restarted" >&2
        return 1
    }
    ui_settle
}
# game_settle: the settle after a game start (BOOT_SETTLE, default BOOT_WAIT: the old duration).
game_settle() {
    local n
    n="$(e2e_settle_count "${BOOT_SETTLE:-}" "$BOOT_WAIT")"
    wait_game_settled "$n" "$((n + $(e2e_whole "$BOOT_WAIT")))"
}
# ui_settle: the settle after a NextUI start, with the default count and bound (see e2e_settle_count).
ui_settle() {
    local n
    n="$(e2e_settle_count "${UI_SETTLE:-}" "$UI_WAIT")"
    wait_ui_settled "$n" "$((n + $(e2e_whole "$UI_WAIT")))"
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

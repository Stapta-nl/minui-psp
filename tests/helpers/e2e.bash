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
    # Each copy is made under a hidden .part name and renamed once it compares equal: a backup that
    # is cut short (the ssh call dropped, the device suspended) never leaves a truncated copy that a
    # later restore (psp_backup restores a leftover backup first) would put over the real state.
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        if ! { cp -p "$f" "$BAK/states/.${f##*/}.part" && cmp -s "$f" "$BAK/states/.${f##*/}.part" &&
            mv -f "$BAK/states/.${f##*/}.part" "$BAK/states/${f##*/}"; }; then
            rm -f "$BAK/states/.${f##*/}.part"
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
# wait_for <seconds> <command...>: polls the command until it succeeds (0) or <seconds> of WALL-CLOCK
# time have passed (1). The poll step is E2E_WAIT_STEP (0.2 s): the signals waited for this way (a
# process that appears or is gone, a file) are cheap to read, and a 1 s step added up to a second per
# wait. E2E_POLL_HOOK (the keep-awake of the reboot kit) runs on every poll, at most as often as it
# allows itself.
wait_for() {
    local limit="$1" t0
    shift
    e2e_clock
    t0=$E2E_NOW
    while :; do
        "$@" >/dev/null 2>&1 && return 0
        e2e_clock
        [ $((E2E_NOW - t0)) -lt $((limit * 1000)) ] || return 1
        "${E2E_POLL_HOOK:-:}" >/dev/null 2>&1 || true
        sleep "${E2E_WAIT_STEP:-0.2}" 2>/dev/null || sleep 1 # poll step (a sleep without fractions: 1 s)
    done
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

# launch_sig <log file>: "<inode> <size> <first line>" of the pak log (PSP.txt), or "none". launch.sh
# deletes PSP.txt and starts it again with its own command line on EVERY start (rm -f, then exec >>),
# so a log with another inode, another first line or a SMALLER size than a reference taken before
# is a new launch.sh run; appended text (a running game logging on) is not.
launch_sig() {
    local f="$1" ino first
    [ -f "$f" ] || { echo none; return 0; }
    # shellcheck disable=SC2012 # one known file; BusyBox stat may lack -c
    ino="$(ls -i "$f" 2>/dev/null | awk '{ print $1 }')"
    IFS= read -r first <"$f" || first=""
    echo "$ino $(wc -c <"$f" | tr -d ' ') $first"
}
# launch_unchanged <reference sig> <log file>: true if no launch.sh ran since the reference was taken.
launch_unchanged() {
    local ref="$1" now ri rs rf ni ns nf
    now="$(launch_sig "$2")"
    [ "$ref" = "$now" ] && return 0
    [ "$ref" = none ] || [ "$now" = none ] && return 1
    ri="${ref%% *}" rs="${ref#* }" rf="${rs#* }" rs="${rs%% *}"
    ni="${now%% *}" ns="${now#* }" nf="${ns#* }" ns="${ns%% *}"
    [ "$ri" = "$ni" ] && [ "$rf" = "$nf" ] && [ "$ns" -ge "$rs" ]
}

# e2e_clock: sets E2E_NOW to the wall clock in ms (bash's EPOCHREALTIME, else `date`; no fork with the former).
# E2E_COARSE=1 with the `date` fallback: its 1 s resolution could cut a quiet time short by up to 1 s, so
# e2e_quiet_left then asks for one second more.
# The quiet times and limits of the settles below are WALL-CLOCK seconds, not poll counts: a poll that takes
# longer than usual (a slow /proc scan, a keep-awake tap) does not stretch the wait.
e2e_clock() {
    local t
    if [ -n "${EPOCHREALTIME:-}" ]; then
        t="${EPOCHREALTIME/[.,]/}"
        E2E_NOW=$((t / 1000)) E2E_COARSE=""
    else
        E2E_NOW=$(($(date +%s) * 1000)) E2E_COARSE=1
    fi
}
# e2e_poll_sleep <ms left>: the poll step of the settles (1 s), shorter when the quiet time ends sooner.
e2e_poll_sleep() {
    if [ "$1" -gt 0 ] && [ "$1" -lt 1000 ]; then
        sleep "0.$(printf '%03d' "$1")" 2>/dev/null || sleep 1 # the rest of the quiet time (whole seconds: a sleep without fractions)
    else
        sleep 1 # poll step
    fi
}
# e2e_quiet_left <since ms> <quiet s>: sets E2E_LEFT to the ms of quiet time still to go (no since: not
# quiet, a whole poll step) and E2E_QUIET to the whole seconds of quiet so far.
e2e_quiet_left() {
    if [ -z "$1" ]; then
        E2E_LEFT=1000 E2E_QUIET=0
    else
        E2E_LEFT=$((($2 + ${E2E_COARSE:-0}) * 1000 - (E2E_NOW - $1))) E2E_QUIET=$(((E2E_NOW - $1) / 1000))
    fi
}

# wait_ui_settled <quiet s> <limit s>: NextUI is up, and it and its launcher are quiet. Why this proves
# "nothing launches by itself" (the absence checks of R1/R2/R6/R7: after a normal quit, a crash or a
# forced reboot the device must come back to NextUI's menu and must NOT start the game: no auto-resume
# marker is consumed and no PPSSPP appears): NextUI's main() calls autoResume() FIRST, before any
# graphics or input init (nextui.c). With a marker it deletes it, queues the game in /tmp/next and
# EXITS; without one it returns at once and NextUI goes on to its menu. So the decision is made within
# moments of nextui.elf starting, and a nextui.elf that is the SAME process for <quiet> seconds (wall
# clock, counted from the first poll that saw it so) has not exited to launch anything. Quiet means, at
# every poll: the same nextui.elf pid, no emulator process, no auto-resume marker ($AUTORESUME, if set:
# NextUI deletes it first thing, so it still being there is a bug or a NextUI that has not run yet). If
# E2E_LAUNCH_REF is set (launch_sig of the pak log before the event under test, log: E2E_LAUNCH_LOG,
# default $LOGS/PSP.txt) a rewritten log (launch.sh ran) fails the wait AT ONCE: a positive "no launch"
# check next to the waiting. Fails after <limit> s (wall clock) and says what it saw.
wait_ui_settled() {
    local quiet="$1" limit="$2" t0 since="" pid last="" game="" marker="" log="${E2E_LAUNCH_LOG:-${LOGS:-}/PSP.txt}"
    e2e_clock
    t0=$E2E_NOW
    while :; do
        "${E2E_POLL_HOOK:-:}" || true
        if [ -n "${E2E_LAUNCH_REF:-}" ] && ! launch_unchanged "$E2E_LAUNCH_REF" "$log"; then
            echo "launch.sh was started (the pak log was rewritten: before: '$E2E_LAUNCH_REF', now: '$(launch_sig "$log")')" >&2
            return 1
        fi
        pid="$(first_pid nextui.elf)"
        game=""
        marker=""
        pgrep PPSSPPSDL >/dev/null 2>&1 && game=1
        [ -n "${AUTORESUME:-}" ] && [ -e "$AUTORESUME" ] && marker=1
        e2e_clock
        if [ -n "$pid" ] && [ -z "$game" ] && [ -z "$marker" ]; then
            if [ "$pid" != "$last" ] || [ -z "$since" ]; then since=$E2E_NOW; fi
        else
            since=""
        fi
        last="$pid"
        e2e_quiet_left "$since" "$quiet"
        [ -n "$since" ] && [ "$E2E_LEFT" -le 0 ] && return 0
        if [ $((E2E_NOW - t0)) -ge $((limit * 1000)) ]; then
            echo "NextUI did not settle within ${limit}s (nextui.elf pid: ${pid:-none}${game:+, a game is running}${marker:+, the auto-resume marker exists}; quiet for $E2E_QUIET of ${quiet} s)" >&2
            return 1
        fi
        e2e_poll_sleep "$E2E_LEFT"
    done
}

# True if the emulator runs with the test ROM as its argument. The command lines are read from
# /proc and matched on argv[0] and the arguments, never on the whole text: the ssh call that
# runs this contains the ROM's name too. Only bash builtins per process (no fork): this runs on every
# poll of a settle, and a `$(tr ...)` per process made each poll take about a second on the device.
rb_rom_running() {
    local p first arg
    for p in /proc/[0-9]*/cmdline; do
        first=""
        { IFS= read -r -d '' first || true; } 2>/dev/null <"$p" || continue
        case "${first##*/}" in PPSSPPSDL*) ;; *) continue ;; esac
        while IFS= read -r -d '' arg || [ -n "$arg" ]; do
            [ "$arg" = "$ROM" ] && return 0
        done 2>/dev/null <"$p"
    done
    return 1
}

# wait_game_settled <quiet s> <limit s>: the emulator runs the test ROM (its argv, from /proc: the
# positive signal that the game was started) and has done so, as the SAME process, for <quiet> seconds
# (wall clock, counted from the first poll that saw it). If minui-power-control's launch script has
# written /tmp/emulator_pid (it does so once it has found the PPSSPP pid, and removes it at the end) that
# file must name this process before the quiet time starts: an extra signal, never required, because not
# every power-control version writes it. A game that dies while starting ends the wait at once. No log
# line of the pak or of this repository says "PPSSPP takes hotkeys now" (and the auto-load of a state
# leaves no file when there is no state), so the quiet time is a fixed settle: see BOOT_SETTLE. Waits up
# to <limit> s (wall clock) in all.
wait_game_settled() {
    local quiet="$1" limit="$2" t0 since="" pid last="" seen="" epid=""
    e2e_clock
    t0=$E2E_NOW
    while :; do
        "${E2E_POLL_HOOK:-:}" || true
        pid=""
        rb_rom_running && pid="$(first_pid PPSSPPSDL)"
        e2e_clock
        if [ -n "$pid" ]; then
            seen=1
            epid=""
            [ -f "${E2E_EMULATOR_PID_FILE:-/tmp/emulator_pid}" ] && IFS= read -r epid <"${E2E_EMULATOR_PID_FILE:-/tmp/emulator_pid}"
            if [ -n "$epid" ] && [ "$epid" != "$pid" ]; then
                since=""
            elif [ "$pid" != "$last" ] || [ -z "$since" ]; then
                since=$E2E_NOW
            fi
        else
            since=""
            if [ -n "$seen" ]; then
                echo "the game exited or was restarted while it was starting (see PSP.txt)" >&2
                return 1
            fi
        fi
        last="$pid"
        e2e_quiet_left "$since" "$quiet"
        [ -n "$since" ] && [ "$E2E_LEFT" -le 0 ] && return 0
        if [ $((E2E_NOW - t0)) -ge $((limit * 1000)) ]; then
            echo "the game was not running steadily within ${limit}s (pid: ${pid:-none}${epid:+, /tmp/emulator_pid: $epid}; steady for $E2E_QUIET of ${quiet} s)" >&2
            return 1
        fi
        e2e_poll_sleep "$E2E_LEFT"
    done
}

# The default quiet times (seconds), chosen from the maintainer's observations (a game starts, state load
# included, within about 5 s; the Game Switcher loads in about 1 s; a save state takes about 3 s) and from
# NextUI's source (autoResume() runs first thing in main()); NOT measured by the tests. BOOT_SETTLE / UI_SETTLE / NOGAME_SETTLE override them (raise
# or lower); BOOT_WAIT / UI_WAIT / NOGAME_WAIT are the upper bounds (and cap a default that is larger).
E2E_DEFAULT_BOOT_SETTLE=6
E2E_DEFAULT_UI_SETTLE=2
E2E_DEFAULT_NOGAME_SETTLE=6

# e2e_whole <n>: the whole seconds of a wait ("6.5" gives 6, junk gives 0).
e2e_whole() {
    local w="${1%%.*}"
    case "$w" in "" | *[!0-9]*) w=0 ;; esac
    echo "$w"
}
# e2e_settle_count <override> <default> <wait>: the quiet time: the explicit override when it is a whole
# number, else the default, but never more than the configured upper bound <wait>.
e2e_settle_count() {
    local o="$1" d="$2" w
    w="$(e2e_whole "$3")"
    case "$o" in "" | *[!0-9]*) [ "$d" -le "$w" ] && echo "$d" || echo "$w" ;; *) echo "$o" ;; esac
}
# game_settle / ui_settle / nogame_settle: the settles with their variables. The upper bound of a settle
# is its quiet time plus the *_WAIT value (time for the game / NextUI to show up, then the quiet time).
game_settle() {
    local n
    n="$(e2e_settle_count "${BOOT_SETTLE:-}" "$E2E_DEFAULT_BOOT_SETTLE" "${BOOT_WAIT:-20}")"
    wait_game_settled "$n" "$((n + $(e2e_whole "${BOOT_WAIT:-20}")))"
}
ui_settle() {
    local n
    n="$(e2e_settle_count "${UI_SETTLE:-}" "$E2E_DEFAULT_UI_SETTLE" "${UI_WAIT:-6}")"
    wait_ui_settled "$n" "$((n + $(e2e_whole "${UI_WAIT:-6}")))"
}
# ui_game_settle: a game that was started by NextUI itself (auto-resume) keeps running: the quiet time of a
# NextUI settle (UI_SETTLE), applied to the game process.
ui_game_settle() {
    local n
    n="$(e2e_settle_count "${UI_SETTLE:-}" "$E2E_DEFAULT_UI_SETTLE" "${UI_WAIT:-6}")"
    wait_game_settled "$n" "$((n + $(e2e_whole "${BOOT_WAIT:-20}")))"
}
nogame_settle() {
    local n
    n="$(e2e_settle_count "${NOGAME_SETTLE:-}" "$E2E_DEFAULT_NOGAME_SETTLE" "${NOGAME_WAIT:-25}")"
    wait_ui_settled "$n" "$((n + $(e2e_whole "${NOGAME_WAIT:-25}")))"
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
    local before newest t0
    # The pak names files by the second, and the screen needs a moment to show what the last key
    # did: no signal exists for "drawn" (a frame-stable check would need two screenshots), so the
    # fixed second stays.
    sleep 1
    e2e_clock
    t0=$E2E_NOW
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
    e2e_phase_since "shot $1 (after the fixed 1 s)" "$t0"
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

# e2e_phase <label> <seconds>: one wait of this test, in the TAP output (fd 3 under bats) and in
# $OUT/timings.txt, so that a report shows where a test spends its time.
e2e_phase() {
    { [ -w /dev/fd/3 ] && echo "# wait: $1 ${2}s" >&3; } 2>/dev/null || true
    [ -z "${OUT:-}" ] || echo "$(date '+%H:%M:%S') wait: $1 ${2}s" >>"$OUT/timings.txt" 2>/dev/null || true
}
# e2e_secs <ms>: "3.2"
e2e_secs() { printf '%s.%s' $(($1 / 1000)) $((($1 % 1000) / 100)); }
# e2e_phase_since <label> <start ms> [note]: e2e_phase for a step that began at <start ms> (e2e_clock).
e2e_phase_since() {
    e2e_clock
    e2e_phase "$1${3:+ ($3)}" "$(e2e_secs $((E2E_NOW - $2)))"
}
# e2e_timed <label> <command...>: runs the command and records how long it took (and its status if not 0).
e2e_timed() {
    local label="$1" t0 rc=0
    shift
    e2e_clock
    t0=$E2E_NOW
    "$@" || rc=$?
    if [ "$rc" = 0 ]; then e2e_phase_since "$label" "$t0"; else e2e_phase_since "$label" "$t0" "rc $rc"; fi
    return "$rc"
}

# nextui_replaced <old pid>: a nextui.elf runs and it is not <old pid>.
nextui_replaced() {
    local p
    p="$(first_pid nextui.elf)"
    [ -n "$p" ] && [ "$p" != "$1" ]
}

# restart_ui: kills NextUI and waits until the NEW process is up and settled (the same pid for
# UI_SETTLE seconds, default 2: the maintainer sees the Game Switcher load in about 1 s; the screenshot
# after it has its own 1 s delay). No "NextUI has drawn" signal is verified on a device, so this is
# the observed time plus margin. The old process being gone is detected by its pid.
restart_ui() {
    local old t0
    e2e_clock
    t0=$E2E_NOW
    old="$(first_pid nextui.elf)"
    kill_ui
    wait_for 40 nextui_replaced "$old" || {
        echo "NextUI did not come back within 40 s of being restarted" >&2
        return 1
    }
    e2e_phase_since "NextUI restarted (new pid)" "$t0"
    ui_settle
    e2e_phase_since "restart_ui total" "$t0"
}

# --- the save state hotkey's result: the files PPSSPP writes ----------------------------------
# new_state_count: how many save state thumbnails were written since the test's marker ($BAK/marker).
new_state_count() { new_state_thumbs | wc -l | tr -d ' '; }
# new_state_files_sig: name, size and time of every state file (.ppst and .jpg, no undo copies) written
# since the marker: it stops changing once PPSSPP has finished writing.
new_state_files_sig() {
    local f
    find "$STATE_DIR" -type f -newer "$BAK/marker" ! -name '*undo*' 2>/dev/null | sort | while IFS= read -r f; do
        # shellcheck disable=SC2012 # one known file; BusyBox stat may lack -c
        ls -ln "$f" 2>/dev/null | awk '{ print $5, $6, $7, $8 }'
        echo "${f##*/}"
    done
}
# wait_state_saved <count before the save hotkey> [limit s]: the positive signal that a save state hotkey
# worked: a NEW state thumbnail (one more than <count> since the marker; a save into another slot) and the
# state files written since the marker unchanged over E2E_SAVE_STABLE (0.5 s). Fails after <limit> s
# (SAVE_WAIT, 10): the caller goes on, and "two save states were written" says what is missing.
wait_state_saved() {
    local before="$1" limit="${2:-${SAVE_WAIT:-10}}" t0 a b
    e2e_clock
    t0=$E2E_NOW
    while :; do
        if [ "$(new_state_count)" -gt "$before" ]; then
            a="$(new_state_files_sig)"
            sleep "${E2E_SAVE_STABLE:-0.5}" 2>/dev/null || sleep 1
            b="$(new_state_files_sig)"
            [ "$a" = "$b" ] && return 0
        else
            sleep "${E2E_WAIT_STEP:-0.2}" 2>/dev/null || sleep 1 # poll step
        fi
        e2e_clock
        if [ $((E2E_NOW - t0)) -ge $((limit * 1000)) ]; then
            echo "no new save state was written (and finished) within ${limit}s of the save hotkey (new states: $(new_state_count), before: $before)" >&2
            return 1
        fi
    done
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

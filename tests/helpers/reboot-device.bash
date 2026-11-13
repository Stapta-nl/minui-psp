# shellcheck shell=bash
# shellcheck disable=SC2016 # patterns that must stay literal
# shellcheck disable=SC2034 # settings are read by the functions of e2e.bash, which is sourced next to this file
# Device-side half of tests/bats/reboot.bats.
#
# reboot.bats runs on the HOST (a reboot would kill a bats that runs on the device), and
# runs everything that has to happen on the device through ssh. The host streams this file,
# together with e2e.bash, to /tmp/psp-reboot-kit.sh on the device (after every boot: /tmp is
# cleared) and each ssh call sources that kit, runs rb_init and then one function from here.
# Everything is bash and BusyBox friendly (no GNU only tools).
#
# Settings (env; the host passes them): SD (/mnt/SDCARD)  PLATFORM  PAK_NAME  ROM_DIR  ROM
#   SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS (read from controls.ini when unset)  UI_WAIT  CHORD_HOLD  KEEPAWAKE_KEY (l1)  POWER_DEV_NAME  SLEEP_PROBE
#   SET_HOTKEYS (1; 0 = never bind a missing hotkey in controls.ini)
# Test hooks (host unit tests only): RB_TMP (/tmp)  RB_REBOOT_CMD  RB_HARD_REBOOT_CMD  BOOT_ID_FILE

# The files e2e.bash's backup/restore helpers use ($BAK/present, absent, states.before, marker,
# active) are the same, with this test's own backup directory on the SD card.

# e2e.bash's shot() reports through these; on the device there is no bats and no pngcolor.
info() { echo "$*" >&2; }
colour() { echo "n/a"; }

rb_init() {
    SD="${SD:-${SDCARD_PATH:-/mnt/SDCARD}}"
    PLATFORM="${PLATFORM:?PLATFORM must be set}"
    PAK_NAME="${PAK_NAME:-PSP}"
    PAK="$SD/Emus/$PLATFORM/$PAK_NAME.pak"
    MON="$SD/Tools/$PLATFORM/Screenshot Monitor.pak"
    SHARED="$SD/.userdata/shared"
    LOGS="$SD/.userdata/$PLATFORM/logs"
    STATE_DIR="$SHARED/PSP-ppsspp"
    BAK="$SHARED/.psp-test-backup" # on the SD card: survives the reboots and a cut-short run; shared with e2e.bats
    PSP_STOP_GAME=rb_stop_game
    INI="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    CONTROLS="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    SHOTDIR="$SD/Screenshots"
    OUT="${RB_OUT:-${RB_TMP:-/tmp}/psp-reboot-out}"
    RB_TMP="${RB_TMP:-/tmp}"
    # the kit's files, for a detached job that loads them again (rb_detach)
    RB_KIT_SOURCES="${RB_KIT_SOURCES:-${RB_KIT_PATH:-}}"
    NEXT="$RB_TMP/next"
    WRAPPER="$RB_TMP/psp-test-poweroff"
    UI_WAIT="${UI_WAIT:-6}"
    E2E_POLL_HOOK=rb_keepawake_dev # the settle loops of e2e.bash keep the device awake through this
    [ -n "${EXIT_KEYS:-}" ] || unset EXIT_KEYS # empty = not set here (there is no kill mode)
    # The hotkeys of the DEVICE (controls.ini), the documented defaults where unset: devconfig.bash
    cfg_init_hotkeys "$CONTROLS" "save exit" # Next Slot is never pressed here
    mkdir -p "$OUT" 2>/dev/null

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
    ROM="${ROM:-}"
    ROM_FILE="$(basename "${ROM:-none}")"
    # Same emu tag NextUI uses: the text in the last (...) of the Roms folder name.
    tag="${ROM%/*}"
    tag="${tag#"$SD"/Roms/}"
    tag="${tag%%/*}"
    case "$tag" in *"("*")"*)
        tag="${tag##*(}"
        tag="${tag%%)*}"
        ;;
    esac
    MINUI="$SHARED/.minui/$tag"
    SLOT_FILE="$MINUI/$ROM_FILE.txt"
    PREVIEW="$MINUI/$ROM_FILE.0.bmp"
    RECENT="$SHARED/.minui/recent.txt"
    PERSIST="$SHARED/.minui/game_switcher.txt"
    AUTORESUME="$SHARED/.minui/auto_resume.txt"
    # The pad's event number can change with a reboot, so it is looked up every time.
    PAD="$(awk '/^N: Name="TRIMUI Player1"/{f=1} f&&/^H: Handlers=/{for(i=1;i<=NF;i++) if($i ~ /^event/){print "/dev/input/" $i; exit}}' /proc/bus/input/devices 2>/dev/null)"
    return 0
}

# Prints what the host needs to pin for the later calls.
rb_discover() {
    printf 'ROM=%s\n' "$ROM"
}

# What the tests read from the device, for the log (hotkeys, start screen).
rb_config_info() {
    printf '%s' "$HOTKEY_INFO"
    [ -s "$BAK/controls.bound" ] && printf 'bound by the tests in controls.ini (restored at the end):\n%s' "$(cat "$BAK/controls.bound")"
    echo "NextUI start screen: $(cfg_start_mode_info "$SHARED/minuisettings.txt") (the tests work in either mode)"
}

# The command that reboots (never "poweroff"): the first that exists.
rb_reboot_cmd() {
    local c
    if [ -n "${RB_REBOOT_CMD:-}" ]; then
        printf '%s' "$RB_REBOOT_CMD"
        return 0
    fi
    for c in /sbin/reboot /bin/reboot /usr/sbin/reboot; do
        [ -x "$c" ] && printf '%s' "$c" && return 0
    done
    [ -x /bin/busybox ] && printf '%s' "/bin/busybox reboot" && return 0
    return 1
}

# --- preflight -------------------------------------------------------------------------
# True if the shim reads PSP_POWEROFF_REAL and PSP_POWEROFF_TMP in a non-comment line
# (bin/poweroff: REAL_POWEROFF="${PSP_POWEROFF_REAL:-/sbin/poweroff}").
rb_shim_honours_override() {
    local code
    code="$(grep -v '^[[:space:]]*#' "$1" 2>/dev/null)"
    case "$code" in *'${PSP_POWEROFF_REAL'*) ;; *) return 1 ;; esac
    case "$code" in *'${PSP_POWEROFF_TMP'*) ;; *) return 1 ;; esac
    case "$code" in *'exec "$REAL_POWEROFF"'*) ;; *) return 1 ;; esac
}

# Prints one "FAIL: ..." line per problem and returns 1 if there is any.
rb_preflight() {
    local bad=0 tmp p
    fail_() { echo "FAIL: $*"; bad=1; }
    [ "$(id -u)" = 0 ] || fail_ "not root (needed to write to /dev/input and to reboot)"
    [ -d "$PAK" ] || fail_ "the pak is not installed at $PAK"
    [ -f "$PAK/launch.sh" ] || fail_ "$PAK/launch.sh missing"
    [ -f "$INI" ] || fail_ "$INI missing (start a game once so PPSSPP writes it)"
    while IFS= read -r p; do
        [ -n "$p" ] && fail_ "$p"
    done <<<"${HOTKEY_PROBLEMS:-}"
    p="$(rb_keepawake_key_clash)" && fail_ "$p"
    [ -x "$PAK/bin/jpg2bmp" ] || fail_ "$PAK/bin/jpg2bmp missing (install a pak built by CI or make build)"
    [ -f "$PAK/bin/poweroff" ] || fail_ "$PAK/bin/poweroff (the shim) is missing: this pak has no auto-resume"
    # The shim must USE the override in code (not just mention it in a comment). If it does not,
    # nothing below may run: the probe would reach the real /sbin/poweroff.
    if [ -f "$PAK/bin/poweroff" ] && ! rb_shim_honours_override "$PAK/bin/poweroff"; then
        echo "FAIL: the shim does not use \${PSP_POWEROFF_REAL} and \${PSP_POWEROFF_TMP} in code: the test cannot turn the power-off into a reboot, so it must not run"
        return 1
    fi
    [ -f "$RB_TMP/nextui_exec" ] || fail_ "NextUI launcher not running ($RB_TMP/nextui_exec missing)"
    [ -c "${PAD:-}" ] || fail_ "TRIMUI Player1 input device not found"
    [ -d "${ROM_DIR:-}" ] || fail_ "no Roms/*(PSP) folder found (set ROM_DIR)"
    [ -f "${ROM:-}" ] || fail_ "no game file found (set ROM)"
    rb_reboot_cmd >/dev/null || fail_ "no reboot command found"
    for p in pgrep killall sync awk find cmp cp mv sort mkdir cat tr; do
        command -v "$p" >/dev/null 2>&1 || fail_ "$p is missing"
    done
    case "$SD$BAK$ROM" in *"'"*) fail_ "paths with a single quote are not supported" ;; esac
    # The shim must call the program named in PSP_POWEROFF_REAL: prove it with a harmless one,
    # in a private temp dir so that no pid file makes the shim wait or touch the real ones.
    if [ -f "$PAK/bin/poweroff" ] && tmp="$(mktemp -d "$RB_TMP/psp-probe.XXXXXX" 2>/dev/null)"; then
        printf '#!/bin/sh\necho "$*" >"%s/probe-called"\n' "$tmp" >"$tmp/fake"
        chmod +x "$tmp/fake"
        PSP_POWEROFF_TMP="$tmp" PSP_POWEROFF_REAL="$tmp/fake" sh "$PAK/bin/poweroff" --probe >/dev/null 2>&1 </dev/null
        grep -qx -- '--probe' "$tmp/probe-called" 2>/dev/null ||
            fail_ "the shim did not call PSP_POWEROFF_REAL (a real power-off would not be turned into a reboot)"
        rm -rf "$tmp"
    fi
    return "$bad"
}

# rb_keepawake_key_clash: the keep-awake key (KEEPAWAKE_KEY, l1) must not be part of any hotkey of controls.ini:
# a tap that lands while a test holds a chord is avoided by the input lock, but a hotkey OF the key itself (or a
# chord with it that a user presses) would fire on every tap. Allowed: the plain PSP button mappings (one key).
# Prints the problem and succeeds when there is one.
rb_keepawake_key_clash() {
    local code hits
    [ "${KEEPAWAKE_INTERVAL:-3}" != 0 ] || return 1
    code="$(cfg_button_code "${KEEPAWAKE_KEY:-l1}")" || { echo "KEEPAWAKE_KEY=${KEEPAWAKE_KEY:-} is not a pad button the tests can press"; return 0; }
    [ -f "$CONTROLS" ] || return 1
    hits="$(awk -v code="$code" '
        { sub(/^\357\273\277/, ""); sub(/\r$/, "") }
        /^[ \t]*\[/ { sec = ($0 ~ /^[ \t]*\[ControlMapping\][ \t]*$/); next }
        sec && /=/ {
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            psp = (tolower(k) ~ /^(up|down|left|right|circle|cross|square|triangle|start|select|l|r|an\.(up|down|left|right)|analog limiter)$/)
            n = split(v, alt, ",")
            for (i = 1; i <= n; i++) {
                m = split(alt[i], c, ":"); found = 0
                for (j = 1; j <= m; j++) if (c[j] == code) found = 1
                if (found && (m > 1 || !psp)) print k " = " alt[i]
            }
        }' "$CONTROLS")"
    [ -n "$hits" ] || return 1
    echo "the keep-awake key ${KEEPAWAKE_KEY:-l1} ($code) is part of hotkeys in $CONTROLS: $(printf '%s' "$hits" | tr '\n' ';' | sed 's/;$//; s/;/; /g'). A keep-awake tap would trigger them: set KEEPAWAKE_KEY to a button no hotkey uses"
    return 0
}

# --- backup / restore ------------------------------------------------------------------
# The backup is the one of e2e.bash (psp_backup / psp_restore, shared with e2e.bats): the same
# files, plus controls.ini (the hotkeys the tests bind), ppsspp.ini and a copy of every save state.
# "active" is set first, so an abort at any point is restored by rb_restore (this run) or by the
# next run, of either test file.
rb_backup() {
    local rc=0
    rb_lock backup "${RB_BACKUP_LOCK_WAIT:-10}" || return 1
    rb_backup_steps || rc=$?
    rb_unlock
    return "$rc"
}
rb_backup_steps() {
    psp_backup || return 1
    rm -f "$BAK"/evidence-* "$BAK/wrapper.log" "$BAK/trigger.log"
    # What a cut-short run had bound is gone again: resolve the hotkeys from the restored file.
    cfg_reinit_hotkeys
    if [ -n "$HOTKEY_PROBLEMS" ]; then
        echo "$HOTKEY_PROBLEMS" >&2
        return 1
    fi
    # PPSSPP reads controls.ini when it starts: the hotkeys are bound before any game is launched,
    # and stay in place (the file is on the SD card) until rb_restore at the very end.
    cfg_apply_hotkeys || return 1
    # a fallback chord the tests bound may use the keep-awake key
    local clash
    if clash="$(rb_keepawake_key_clash)"; then
        echo "$clash" >&2
        return 1
    fi
}

# The size of the save state folder in KB (the host sizes the backup's timeout with it).
rb_state_kb() { du -sk "$STATE_DIR" 2>/dev/null | cut -f 1; }

# Puts back the state files backed up by rb_backup that were changed or deleted.
rb_restore_states() { restore_states; }

# Stops the emulator without saving anything, waits for NextUI to be back (bounded). Fails if a
# game is still running or starting then.
rb_game_up() { pgrep PPSSPPSDL >/dev/null 2>&1; }
rb_kill_game() { killall -9 "PPSSPPSDL_$PLATFORM" 2>/dev/null; }

rb_stop_game() {
    local rc=0
    e2e_stop_game || rc=1
    rm -f "$NEXT"
    return "$rc"
}

# Puts everything back. Also used at the end of the run, after a reboot that cut it short: the SD
# card and NextUI may not be up yet, so with RB_EXPECT_BACKUP=1 (the caller knows a backup was made)
# it waits (RB_SD_WAIT, 120 s) for the backup and fails loudly instead of returning silently.
rb_restore() {
    local rc=0
    # never next to a backup that still runs (a detached job the host gave up on: see rb_job_start)
    rb_lock restore "${RB_LOCK_WAIT:-300}" || {
        echo "NOT restored: the backup stays in $BAK and is restored by the next run" >&2
        return 1
    }
    rb_restore_steps || rc=$?
    rb_unlock
    return "$rc"
}
rb_restore_steps() {
    local had_hotkeys=0
    if [ ! -f "$BAK/active" ]; then
        [ -n "${RB_EXPECT_BACKUP:-}" ] || return 0
        wait_for "${RB_SD_WAIT:-120}" test -f "$BAK/active" || {
            echo "no backup found at $BAK (is the SD card mounted?): NOTHING WAS RESTORED" >&2
            return 1
        }
    fi
    [ -f "$BAK/controls.bound" ] && had_hotkeys=1
    # normal for the backup THIS run made (PSP_RUN_ID, from the host), strict for any other
    psp_finish || return 1
    rm -f "$WRAPPER"
    cfg_report_restore "$had_hotkeys"
    kill_ui || true # NextUI starts again with the restored recents and without a marker
    return 0
}

# Makes sure no game runs, NextUI is up and the test's own leftovers are gone.
rb_settle() {
    rb_stop_game
    rm -f "$AUTORESUME" "$WRAPPER"
    wait_for 60 running nextui.elf
}

# --- ppsspp.ini ------------------------------------------------------------------------
# rb_ini_set <key> <value>: sets the key in [General] (adds it when missing). PPSSPP rewrites
# the file when it exits, so only call this while no game runs.
rb_ini_set() {
    local tmp="$INI.tmp.$$"
    awk -v key="$1" -v val="$2" '
        NR == 1 && /\r$/ { cr = "\r" }
        /\[[^]]*\][ \t\r]*$/ {
            if (g && !done) { print key " = " val cr; done = 1 }
            g = ($0 ~ /\[General\][ \t\r]*$/)
            print; next
        }
        g && $0 ~ ("^" key "[ \t]*=") { if (!done) print key " = " val cr; done = 1; next }
        { print }
        END { if (g && !done) print key " = " val cr }
    ' "$INI" >"$tmp" && cat "$tmp" >"$INI"
    rm -f "$tmp"
    # what the tests left, so that a later change is noticed (guard_changed in e2e.bash)
    [ -f "$BAK/active" ] && snapshot_left "$INI"
    sync
}

# rb_ini_get <key>: the value in [General] (empty if missing).
rb_ini_get() {
    awk -v key="$1" '
        { sub(/\r$/, "") }
        /\[[^]]*\][ \t]*$/ { g = ($0 ~ /\[General\][ \t]*$/); next }
        g && $0 ~ ("^" key "[ \t]*=") { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }
    ' "$INI"
}

# --- the game ----------------------------------------------------------------------------
# Marks "now" (states newer than this are new); returns when the file clock has moved past the mark (touch_marker).
rb_mark() {
    touch_marker "$BAK/marker"
}

# Starts the game the way NextUI does: /tmp/next, then NextUI is restarted (SIGKILL, never SIGTERM).
rb_launch_game() {
    seed_recent
    mkdir -p "$MINUI"
    printf "'%s/launch.sh' '%s'\n" "$PAK" "$ROM" >"$NEXT"
    kill_ui
}

rb_ppsspp_pid() { pgrep PPSSPPSDL 2>/dev/null | head -n 1; }

rb_nextui_up() { pgrep nextui.elf >/dev/null 2>&1; }
rb_no_game() { ! pgrep PPSSPPSDL >/dev/null 2>&1; }

rb_quit_game() { press "$EXIT_KEYS"; }
rb_save_state() { press "$SAVE_KEYS"; }

rb_marker_exists() { [ -e "$AUTORESUME" ]; }
rb_marker_content() { cat "$AUTORESUME" 2>/dev/null; }
# The path NextUI/launch.sh store in the marker: the ROM relative to the SD card.
rb_expected_marker() { printf '%s' "${ROM#"$SD"}"; }

# --- save states -----------------------------------------------------------------------
# The states PPSSPP wrote (.ppst, not the undo copies); "new" = newer than the marker file.
# ONE definition of "a real state": every undo copy PPSSPP writes has "undo" in its name
# (<game>_<slot>.undo.ppst, load_undo.ppst, *.undo.jpg). load_undo.ppst is written at the start
# of a game that auto-loads a state, so it is newer than the marker without any state being saved.
RB_STATE_FIND="-name *.ppst ! -name *undo*"
rb_all_states() {
    # shellcheck disable=SC2086 # the expression is split on purpose (globs are quoted by find's own parsing: set -f)
    ( set -f; find "$STATE_DIR" $RB_STATE_FIND 2>/dev/null )
}
rb_new_states() {
    [ -f "$BAK/marker" ] || return 0
    # shellcheck disable=SC2086
    ( set -f; find "$STATE_DIR" $RB_STATE_FIND -newer "$BAK/marker" 2>/dev/null )
}
# The slot of the newest new state ("" if none): <game>_<version>_<slot>.ppst
rb_newest_new_slot() {
    local new newest s
    new="$(rb_new_states)"
    [ -n "$new" ] || return 0
    # shellcheck disable=SC2012,SC2086 # PPSSPP's own names (no spaces); ls -t gives the newest
    newest="$(ls -t $new 2>/dev/null | head -n 1)"
    s="${newest%.ppst}"
    printf '%s' "${s##*_}"
}
rb_slot_file_slot() { cat "$SLOT_FILE" 2>/dev/null; }
rb_preview_exists() { [ -s "$MINUI/$ROM_FILE.$1.bmp" ]; }
rb_has_new_state() { [ -n "$(rb_new_states)" ]; }
rb_has_new_preview() {
    local slot
    slot="$(rb_newest_new_slot)"
    [ -n "$slot" ] && rb_preview_exists "$slot"
}
# A checksum of a file's content: md5sum, else cksum, else sha1sum, else only the size.
rb_sum() {
    local out
    if out="$(md5sum "$1" 2>/dev/null)"; then :
    elif out="$(cksum "$1" 2>/dev/null)"; then :
    elif out="$(sha1sum "$1" 2>/dev/null)"; then :
    else out="size-only"
    fi
    printf '%s' "${out%% *}"
}
# One line per state file (.ppst and .jpg, no undo copies): "<name> <size> <checksum>".
rb_snapshot_states() {
    local f
    for f in "$STATE_DIR"/*.ppst "$STATE_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        case "$f" in *undo*) continue ;; esac
        printf '%s %s %s\n' "${f##*/}" "$(wc -c <"$f" | tr -d ' ')" "$(rb_sum "$f")"
    done | sort
}
# One line per state file (.ppst and .jpg, no undo copies): "<name> <size>": cheap (no checksum), for
# watching whether PPSSPP still writes.
rb_state_sizes() {
    local f
    for f in "$STATE_DIR"/*.ppst "$STATE_DIR"/*.jpg; do
        [ -f "$f" ] || continue
        case "$f" in *undo*) continue ;; esac
        printf '%s %s\n' "${f##*/}" "$(wc -c <"$f" | tr -d ' ')"
    done | sort
}
# Waits (up to ~30 s) until the names and sizes of the state files are the same in two consecutive
# one second reads: PPSSPP may still be writing (this IS the signal; the 30 s are the backup). The
# expensive checksums are made once afterwards, by the caller: reading every state file for each poll
# (several MB each, on an SD card) used to cost seconds per poll.
rb_wait_states_stable() {
    local a b n=0
    a="$(rb_state_sizes)"
    while [ "$n" -lt 30 ]; do
        sleep 1
        b="$(rb_state_sizes)"
        [ "$a" = "$b" ] && return 0
        a="$b"
        n=$((n + 1))
    done
    echo "the state files kept changing for 30 s" >&2
    return 1
}
rb_save_snapshot() {
    rb_wait_states_stable || return 1
    rb_snapshot_states >"$BAK/evidence-states-before"
    sync
}
rb_states_intact() {
    local line now
    [ -s "$BAK/evidence-states-before" ] || { echo "no snapshot of the states" >&2; return 1; }
    now="$(rb_snapshot_states)"
    while IFS= read -r line; do
        printf '%s\n' "$now" | grep -qxF -- "$line" || {
            echo "state changed or gone: $line" >&2
            return 1
        }
    done <"$BAK/evidence-states-before"
}

# --- the power-off ------------------------------------------------------------------------
# The test's replacement for the FINAL poweroff of the shim (bin/poweroff runs the program
# named in PSP_POWEROFF_REAL instead of /sbin/poweroff): it records evidence on the SD card
# (what launch.sh had armed and saved at that moment, which a reboot would otherwise erase),
# syncs and reboots. It is only ever given to the shim through the environment of one call
# (rb_trigger_poweroff); nothing in the system is replaced, and /tmp is cleared by the reboot.
rb_install_wrapper() {
    local reboot_cmd
    reboot_cmd="$(rb_reboot_cmd)" || return 1
    cat >"$WRAPPER" <<WRAP
#!/bin/sh
# Test only (tests/helpers/reboot-device.bash): stands in for the final poweroff.
B='$BAK'
echo "poweroff replaced by reboot: called with '\$*' at \$(date)" >>"\$B/wrapper.log"
echo "\$*" >"\$B/evidence-called"
[ -f '$AUTORESUME' ] && cp '$AUTORESUME' "\$B/evidence-marker"
cp '$LOGS/PSP.txt' "\$B/evidence-PSP.txt" 2>/dev/null
( set -f; find '$STATE_DIR' $RB_STATE_FIND -newer "\$B/marker" ) >"\$B/evidence-new-states" 2>/dev/null
sync
exec $reboot_cmd
WRAP
    chmod +x "$WRAPPER"
}

# Requests a power-off the way the power button's shutdown script does: SIGTERM to the
# emulator, then `poweroff` (the shim in the pak) with the final poweroff swapped for the
# wrapper. Runs detached: the ssh session ends with the reboot.
rb_trigger_poweroff() {
    local pid
    pid="$(rb_ppsspp_pid)"
    [ -n "$pid" ] || { echo "PPSSPP is not running" >&2; return 1; }
    [ -x "$WRAPPER" ] || { echo "the reboot wrapper is not installed" >&2; return 1; }
    rm -f "$BAK/evidence-called" "$BAK/evidence-marker" "$BAK/evidence-PSP.txt" "$BAK/evidence-new-states"
    (
        trap '' HUP # the ssh session that started this ends with the reboot
        kill -TERM "$pid"
        PSP_POWEROFF_TMP="$RB_TMP" PSP_POWEROFF_REAL="$WRAPPER" sh "$PAK/bin/poweroff" >>"$BAK/trigger.log" 2>&1
    ) >/dev/null 2>&1 </dev/null &
}

# A power cut analogue: no SIGTERM, no shim, no handshake. Everything is synced first so
# that the SD card is not left dirty; then the reboot is forced (BusyBox "reboot -f").
rb_hard_reboot() {
    local c
    c="${RB_HARD_REBOOT_CMD:-$(rb_reboot_cmd) -f}"
    sync
    (
        trap '' HUP
        sleep 1 # lets the calling ssh session return (status 0) before the reboot cuts it; the sync above already ran
        # shellcheck disable=SC2086 # command and its flag
        $c
    ) >/dev/null 2>&1 </dev/null &
}

# --- keeping the device awake ------------------------------------------------------------
# What NextUI does when the idle time is up (NextUI's workspace/all/common/api.c, PWR_update/PWR_sleep): after
# screentimeout s without input it enters "hybrid sleep" (PWR_enterSleep: backlight to 0 through the /dev/disp
# ioctl on the tg5040, NOT through /sys/class/backlight, then `killall -STOP keymon.elf batmon.elf audiomon.elf`)
# and waits in PWR_waitForWake for the release of the POWER key (BTN_WAKE; any other button is ignored, so a
# keep-awake tap of L1 does NOT end it); after suspendTimeout s more it suspends the device (deep sleep: ssh
# drops). On waking it sends SIGCONT to those daemons again (PWR_exitSleep). So a keymon.elf in the stopped
# state ("T" in /proc/<pid>/stat) is NextUI's screen-off state: nothing else in NextUI stops it.
#
# rb_keymon_state: the state letter of keymon.elf (R, S, T, ...), empty when it does not run. RB_KEYMON_STAT
# (host unit tests): a stat file to read instead.
rb_keymon_state() {
    local p st=""
    if [ -n "${RB_KEYMON_STAT:-}" ]; then
        { IFS= read -r st <"$RB_KEYMON_STAT"; } 2>/dev/null || st=""
    else
        p="$(pgrep keymon.elf 2>/dev/null | head -n 1)"
        [ -n "$p" ] && { IFS= read -r st <"/proc/$p/stat"; } 2>/dev/null
    fi
    [ -n "$st" ] || return 0
    st="${st##*) }"
    printf '%s' "${st%% *}"
}
# rb_screen_state: one line for the logs: what the screen-off state looks like on this device (keymon's state,
# every backlight's bl_power and brightness, fb0's blank). Read only.
rb_screen_state() {
    local f v out
    out="keymon=$(rb_keymon_state)"
    for f in "${RB_BACKLIGHT_DIR:-/sys/class/backlight}"/*; do
        [ -d "$f" ] || continue
        v=""; { read -r v <"$f/bl_power"; } 2>/dev/null
        out="$out ${f##*/}:bl_power=$v"
        v=""; { read -r v <"$f/brightness"; } 2>/dev/null
        out="$out,brightness=$v"
    done
    v=""; { read -r v <"${RB_FB_DIR:-/sys/class/graphics/fb0}/blank"; } 2>/dev/null
    printf '%s fb0_blank=%s' "$out" "$v"
}
# True if the screen is off. Only clear signals count: SLEEP_PROBE (a command, true when asleep) when given;
# else keymon.elf stopped (NextUI's hybrid sleep, see above), or a backlight node that says "powered down"
# (bl_power != 0, the FB_BLANK values). A brightness of 0 proves nothing (it can be the user's setting, and NextUI
# does not use the sysfs node on the tg5040). A DIAGNOSIS: it is logged loudly, and acted on (a power tap) only
# when RB_POWER_WAKE=1 (rb_wake_guarded).
rb_asleep() {
    local f v
    if [ -n "${SLEEP_PROBE:-}" ]; then
        sh -c "$SLEEP_PROBE" >/dev/null 2>&1
        return
    fi
    [ "$(rb_keymon_state)" = T ] && return 0
    for f in "${RB_BACKLIGHT_DIR:-/sys/class/backlight}"/*/bl_power; do
        [ -r "$f" ] || continue
        read -r v <"$f"
        [ "$v" = 0 ] || return 0
    done
    return 1
}
RB_SCREEN_OFF_MSG="the screen is OFF (keymon stopped by NextUI: its screen-off before the idle suspend): press the power button"

# rb_keymon_orphan: a keymon.elf left STOPPED with no NextUI (nextui.elf) or minarch running cannot be NextUI's
# screen-off: its NextUI was killed (kill -9) while the screen was off, and nobody sends it SIGCONT any more. It
# is sent SIGCONT here (and logged). 0 when it did so.
rb_keymon_orphan() {
    local p
    [ -z "${RB_KEYMON_STAT:-}" ] || return 1 # (host unit tests: a fake state, no process)
    [ "$(rb_keymon_state)" = T ] || return 1
    running nextui.elf && return 1
    running minarch.elf && return 1
    p="$(pgrep keymon.elf 2>/dev/null | head -n 1)"
    [ -n "$p" ] || return 1
    kill -CONT "$p" 2>/dev/null || return 1
    rb_keepawake_log "keymon.elf (pid $p) was STOPPED with no NextUI running (its NextUI was killed while the screen was off): sent SIGCONT"
    return 0
}

# Taps KEY_POWER (code 116, a short tap, well under the 2 s long press that powers off) on the
# power key's input device: POWER_DEV_NAME (regex) is matched against the device names. The raw tap: callers
# use rb_wake_guarded.
rb_wake() {
    local dev
    dev="$(awk -v re="${POWER_DEV_NAME:-axp|pek|power|gpio-keys}" '
        /^N: Name=/ { name = $0; sub(/^N: Name="/, "", name); sub(/"$/, "", name); use = (name ~ re && name !~ /TRIMUI Player/) }
        use && /^H: Handlers=/ { for (i = 1; i <= NF; i++) if ($i ~ /^event/) { print "/dev/input/" $i; exit } }
    ' /proc/bus/input/devices 2>/dev/null)"
    [ -c "$dev" ] || { echo "no power key device found (POWER_DEV_NAME)" >&2; return 1; }
    PAD="$dev" pad 1 116 1
    PAD="$dev" syn
    sleep 0.2 # a short key tap (input injection): no signal exists
    PAD="$dev" pad 1 116 0
    PAD="$dev" syn
}

# rb_wake_guarded: a power tap ONLY when it was asked for (RB_POWER_WAKE=1: off by default, a power tap at the
# wrong moment is harmful: in a running PPSSPP game minui-power-control takes a short press for deep sleep, on an
# awake NextUI it is the manual sleep) and every condition holds: NextUI (nextui.elf) runs and no PPSSPP and no
# minui-power-control; the screen is off on two reads at least 1.5 s apart; and the persistent stamp
# (RB_TMP/psp-wake.stamp, the time of every tap, never removed) allows it: at least 10 s since the last tap and
# at most 2 taps in the last 60 s. Under a lock (mkdir; a lock older than 10 s is stale) that is taken BEFORE
# the stamp and the screen are checked again. Prints what it did or why not; 0 only when it tapped.
rb_wake_guarded() {
    local lk="${RB_TMP:-/tmp}/psp-wake.lock" stamp="${RB_TMP:-/tmp}/psp-wake.stamp" now t n=0 last=0 rc=0
    [ "${RB_POWER_WAKE:-0}" = 1 ] || { echo "automatic power taps are off (RB_POWER_WAKE=1 turns them on)"; return 1; }
    running nextui.elf || { echo "no power tap: NextUI does not run"; return 1; }
    if running PPSSPPSDL || running minui-power-control; then echo "no power tap: a game or minui-power-control runs"; return 1; fi
    rb_asleep || { echo "no power tap: the screen is on"; return 1; }
    sleep 1.5 2>/dev/null || sleep 2
    rb_asleep || { echo "no power tap: the screen was on again at the second read"; return 1; }
    if ! mkdir "$lk" 2>/dev/null; then
        t="$(date -r "$lk" +%s 2>/dev/null)"
        case "$t" in "" | *[!0-9]*) t=0 ;; esac
        [ $(($(date +%s) - t)) -ge 10 ] || { echo "no power tap: another one is being sent"; return 1; }
        rm -rf "$lk"
        mkdir "$lk" 2>/dev/null || { echo "no power tap: another one is being sent"; return 1; }
    fi
    now="$(date +%s)"
    while read -r t; do
        case "$t" in "" | *[!0-9]*) continue ;; esac
        [ "$t" -le "$last" ] || last="$t"
        [ $((now - t)) -ge 60 ] || n=$((n + 1))
    done <"$stamp" 2>/dev/null
    if [ $((now - last)) -lt 10 ] || [ "$n" -ge 2 ]; then
        rm -rf "$lk"
        echo "no power tap: the last one was $((now - last)) s ago, $n in the last 60 s (at least 10 s apart, at most 2 a minute)"
        return 1
    fi
    if ! rb_asleep; then
        rm -rf "$lk"
        echo "no power tap: the screen is on again"
        return 1
    fi
    echo "$now" >>"$stamp"
    rb_wake || rc=$?
    rm -rf "$lk"
    echo "power tap sent (rc $rc)"
    [ "$rc" = 0 ]
}

# rb_keepawake_log <line>: appended to the device's keep-awake log (RB_TMP/psp-keepawake.log; kept short).
rb_keepawake_log() {
    local f="${RB_TMP:-/tmp}/psp-keepawake.log"
    if [ -f "$f" ] && [ "$(wc -c <"$f" 2>/dev/null || echo 0)" -gt 300000 ]; then
        tail -n 500 "$f" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    fi
    echo "$(date '+%H:%M:%S' 2>/dev/null) $*" >>"$f" 2>/dev/null
    return 0
}

# One keep-awake step: a harmless tap on the pad (any input restarts the idle timer of NextUI's auto sleep),
# never in the middle of a test's key press (the input lock of e2e.bash: the tap is then skipped). A screen
# that is off anyway (rb_asleep) is logged LOUDLY ("press the power button"); a power tap is sent only when
# RB_POWER_WAKE=1 (rb_wake_guarded). A keymon left stopped without NextUI is sent SIGCONT (rb_keymon_orphan).
# Prints, and logs, the screen state and what was done (the host's waits put it in reboot-timings.txt).
rb_tick() {
    local st line rc=0 w
    rb_keymon_orphan || true
    st="$(rb_screen_state)"
    if rb_asleep; then
        w="$(rb_wake_guarded 2>&1)" || rc=$?
        line="tick: $st -> $RB_SCREEN_OFF_MSG ($w)"
    elif input_trylock; then
        press_raw "${KEEPAWAKE_KEY:-l1}" || rc=$?
        input_unlock
        line="tick: $st -> ${KEEPAWAKE_KEY:-l1} tap"
    else
        line="tick: $st -> skipped (a test is pressing keys)"
    fi
    rb_keepawake_log "$line"
    echo "$line"
    return "$rc"
}

# rb_keepawake_dev: rb_tick at most every KEEPAWAKE_INTERVAL seconds (0 = never, RB_TICK=0 = never);
# called on every poll of a settle loop that runs on the device. Never fails.
rb_keepawake_dev() {
    local every="${KEEPAWAKE_INTERVAL:-3}"
    [ "${RB_TICK:-1}" = 1 ] || return 0
    case "$every" in "" | *[!0-9]*) return 0 ;; esac
    [ "$every" -gt 0 ] || return 0
    [ $((SECONDS - ${RB_DEV_LAST_TICK:--99999})) -ge "$every" ] || return 0
    RB_DEV_LAST_TICK=$SECONDS
    rb_tick >/dev/null 2>&1 || true
    return 0
}

# rb_awake <script>: runs the script (eval'd: a function name or a short command line) with the device kept
# awake: one keep-awake step at once and then one every KEEPAWAKE_INTERVAL seconds from a background loop on
# the device, until the script ends. For the calls that can take long WITHOUT polling anything (the backup
# copies every save state, the restore, stopping a game): NextUI suspends the device after its idle time
# (minuisettings.txt: screentimeout, then suspendTimeout) and a suspended device drops the ssh connection.
# The loop ends with the script (cooperatively: never in the middle of a tap), or by itself within a second
# when the shell that runs the script is gone (a cut ssh call; under rb_job_start: the detached job's shell,
# not the ssh session that started it). Returns the script's status.
rb_awake() {
    local parent="${BASHPID:-$$}" tp="" rc=0 every="${KEEPAWAKE_INTERVAL:-3}"
    rb_keepawake_dev
    case "$every" in "" | *[!0-9]* | 0) ;; *)
        if [ "${RB_TICK:-1}" = 1 ]; then
            # Stopped COOPERATIVELY: SIGTERM only sets a flag (bash runs the trap after the command in
            # progress), so a tap always ends with its release; a power key held down would be NextUI's
            # long press (power off). The 1 s pause is interruptible (a background sleep and wait).
            (
                stop=0
                trap 'stop=1' TERM
                while [ "$stop" = 0 ] && kill -0 "$parent" 2>/dev/null; do
                    sleep 1 &
                    wait $! 2>/dev/null
                    [ "$stop" = 0 ] || break
                    rb_keepawake_dev
                done
            ) >/dev/null 2>&1 </dev/null &
            tp=$!
        fi
        ;;
    esac
    eval "$1" || rc=$?
    if [ -n "$tp" ]; then
        kill -TERM "$tp" 2>/dev/null
        wait "$tp" 2>/dev/null
    fi
    return "$rc"
}

# --- running detached from the ssh session -------------------------------------------------------
# rb_detach <log> <function> [args...]: runs a kit function in the background, DETACHED from the ssh session
# that started it (a dropped connection must not end it): stdin from /dev/null, stdout and stderr appended to
# <log>, SIGHUP and SIGPIPE ignored, and, when the device has `setsid` and the kit's files are known
# (RB_KIT_SOURCES, set by rb_init from RB_KIT_PATH), in a session of its own (a new bash that loads the kit
# again). Returns at once.
rb_detach() {
    local log="$1"
    shift
    (
        trap '' HUP PIPE
        if [ -n "${RB_KIT_SOURCES:-}" ] && command -v setsid >/dev/null 2>&1; then
            # shellcheck disable=SC2086 # the kit's files, split on spaces on purpose
            RB_KIT_SOURCES="$RB_KIT_SOURCES" exec setsid bash -c 'for f in $RB_KIT_SOURCES; do . "$f" || exit 97; done; rb_init || exit 98; "$@"' rb-detached "$@"
        fi
        "$@"
    ) </dev/null >>"$log" 2>&1 3>&- &
}

# Long calls run as JOBS: started detached on the device (rb_job_start), under rb_awake so that the device is
# kept awake by the job itself, and polled by the host with short ssh calls (rb_job in reboot.bash). A Wi-Fi
# drop of 15-30 s then only costs a few failed polls; the job goes on. A job lives in RB_TMP/psp-test-jobs/<id>:
# script, log (its stdout and stderr), pid (its shell) and, once it ended, status (its exit status, written
# atomically). A job that the host gave up on keeps running and, for a backup or restore, keeps the lock
# (psp-test.lock): the next backup or restore waits for it or refuses to run next to it.
rb_job_dir() { echo "${RB_TMP:-/tmp}/psp-test-jobs/$1"; }

# rb_job_start <id> <script>: starts the job, idempotent per id (the directory is claimed with mkdir: a start
# whose answer was lost can be sent again). Returns once the job runs (its pid file) or has ended.
rb_job_start() {
    local id="$1" d t0=$SECONDS
    case "$id" in "" | *[!A-Za-z0-9._-]*) echo "bad job id: $id" >&2; return 2 ;; esac
    d="$(rb_job_dir "$id")"
    mkdir -p "${d%/*}" || return 1
    if mkdir "$d" 2>/dev/null; then
        date +%s >"$d/started"
        printf '%s' "$2" >"$d/script" || return 1
        : >"$d/log"
        rb_detach "$d/log" rb_job_run "$id"
    fi
    # up to 10 s (the host's call has 20 s); a job that has not written its pid yet is "starting": rb_job_poll
    # counts it as running for RB_JOB_START_GRACE s (30)
    while [ ! -s "$d/pid" ] && [ ! -f "$d/status" ]; do
        if [ $((SECONDS - t0)) -ge 10 ]; then
            echo "the job $id is still starting"
            return 0
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    return 0
}
# rb_job_run <id>: the job itself (in the detached shell): rb_awake <script>, then the status file.
rb_job_run() {
    local d rc=0
    d="$(rb_job_dir "$1")"
    trap '' HUP PIPE
    echo "${BASHPID:-$$}" >"$d/pid"
    rb_awake "$(cat "$d/script")" || rc=$?
    echo "$rc" >"$d/status.part" && mv "$d/status.part" "$d/status"
}
# rb_job_poll <id>: 0 when the job ended (prints its status on the first line, then its log), 3 while it
# runs, 4 when it is gone without a status (killed, or a reboot cleared /tmp: then the directory is gone too).
rb_job_poll() {
    local d p="" t
    d="$(rb_job_dir "$1")"
    [ -d "$d" ] || { echo "no job $1 on the device (a reboot clears /tmp)"; return 4; }
    if [ ! -f "$d/status" ]; then
        { read -r p <"$d/pid"; } 2>/dev/null
        [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 3
        if [ -z "$p" ]; then # starting (no pid yet), for a while
            { read -r t <"$d/started"; } 2>/dev/null
            case "$t" in "" | *[!0-9]*) t=0 ;; esac
            [ $(($(date +%s) - t)) -ge "${RB_JOB_START_GRACE:-30}" ] || return 3
        fi
        [ -f "$d/status" ] || { echo "the job ended without a status (killed?); its log:"; cat "$d/log" 2>/dev/null; return 4; }
    fi
    cat "$d/status"
    cat "$d/log" 2>/dev/null
    return 0
}
# rb_job_log <id>: the log so far.  rb_job_clean <id>: removes an ENDED job's directory.
rb_job_log() { cat "$(rb_job_dir "$1")/log" 2>/dev/null; }
rb_job_clean() {
    local d
    d="$(rb_job_dir "$1")"
    [ -f "$d/status" ] && rm -rf "$d"
    return 0
}

# --- a keep-awake loop for a whole run ----------------------------------------------------------
# rb_keepawake_start [lease s]: makes sure ONE detached keep-awake loop runs on the device (run-device.sh starts
# it before the on-device tests, reboot.bats keeps it and starts it again after every boot) and gives it a LEASE
# of <lease s> (RB_KEEPAWAKE_LEASE, 600) from now: the loop ends by itself when the lease runs out, so it never
# outlives a run whose host went away by more than that. The host renews the lease while it works
# (rb_keepawake_renew: its waits, every test's setup, run-device.sh during the on-device tests). The loop taps
# KEEPAWAKE_KEY every RB_KEEPAWAKE_EVERY seconds (default: a third of NextUI's screentimeout, 3..20 s; 5 s while
# minuisettings.txt cannot be read yet, e.g. before the SD card is mounted after a boot, and read again every
# step until it can) and looks at the screen every second (rb_tick: logged; see rb_wake_guarded).
# KEEPAWAKE_INTERVAL=0 turns it off. It ends cooperatively (rb_keepawake_stop, or SIGTERM: never in the middle of
# a tap), at the end of its lease, or when another loop claimed the device. Log: RB_TMP/psp-keepawake.log.
# The claim: the directory RB_TMP/psp-keepawake.d (mkdir) with the loop's pid; a claim whose pid is gone is stale.
rb_keepawake_dir() { echo "${RB_TMP:-/tmp}/psp-keepawake.d"; }
rb_keepawake_pid() {
    local p=""
    { read -r p <"$(rb_keepawake_dir)/pid"; } 2>/dev/null
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"
    return 0
}
rb_keepawake_every() {
    local st
    case "${RB_KEEPAWAKE_EVERY:-}" in "" | *[!0-9]*) ;; *) echo "$RB_KEEPAWAKE_EVERY"; return ;; esac
    [ -r "$SHARED/minuisettings.txt" ] || { echo 5; return; }
    st="$(grep -E '^screentimeout=[0-9]+' "$SHARED/minuisettings.txt" 2>/dev/null | head -n 1 | tr -d '\r')"
    st="${st#screentimeout=}"
    case "$st" in "" | *[!0-9]* | 0) echo 10; return ;; esac
    st=$((st / 3))
    [ "$st" -ge 3 ] || st=3
    [ "$st" -le 20 ] || st=20
    echo "$st"
}
# rb_keepawake_renew [lease s]: moves the end of a RUNNING loop's lease (a stopped loop stays stopped).
rb_keepawake_renew() {
    local f="${RB_TMP:-/tmp}/psp-keepawake.until"
    [ -f "$f" ] && echo $(($(date +%s) + ${1:-${RB_KEEPAWAKE_LEASE:-600}})) >"$f"
    return 0
}
rb_keepawake_start() {
    local lease="${1:-${RB_KEEPAWAKE_LEASE:-600}}" p n=0
    [ "${KEEPAWAKE_INTERVAL:-3}" != 0 ] || { echo "keep-awake loop: off (KEEPAWAKE_INTERVAL=0)"; return 0; }
    echo $(($(date +%s) + lease)) >"${RB_TMP:-/tmp}/psp-keepawake.until"
    p="$(rb_keepawake_pid)"
    if [ -n "$p" ]; then
        echo "keep-awake loop: already running (pid $p), lease ${lease}s"
        return 0
    fi
    rb_detach /dev/null rb_keepawake_loop
    while [ -z "$(rb_keepawake_pid)" ] && [ "$n" -lt 30 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        n=$((n + 1))
    done
    echo "keep-awake loop: started (pid $(rb_keepawake_pid); a tap every $(rb_keepawake_every) s, lease ${lease}s, renewed by the host)"
}
rb_keepawake_loop() {
    local stop=0 until every last=-99999 d me="${BASHPID:-$$}" p="" known=0
    d="$(rb_keepawake_dir)"
    # the claim: one loop per device; a stale claim (its pid gone) is taken over
    if ! mkdir "$d" 2>/dev/null; then
        { read -r p <"$d/pid"; } 2>/dev/null
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then return 0; fi
        rm -rf "$d"
        mkdir "$d" 2>/dev/null || return 0
    fi
    echo "$me" >"$d/pid"
    trap 'stop=1' TERM
    trap '' HUP PIPE
    every="$(rb_keepawake_every)"
    rb_keepawake_log "keep-awake loop $me: started, a ${KEEPAWAKE_KEY:-l1} tap every ${every} s, the screen looked at every second"
    while [ "$stop" = 0 ]; do
        [ "$(cat "$d/pid" 2>/dev/null)" = "$me" ] || { rb_keepawake_log "keep-awake loop $me: another loop has the claim, ending"; return 0; }
        { read -r until <"${RB_TMP:-/tmp}/psp-keepawake.until"; } 2>/dev/null
        case "$until" in "" | *[!0-9]*) until=0 ;; esac
        [ "$(date +%s)" -lt "$until" ] || { rb_keepawake_log "keep-awake loop $me: lease ended (not renewed)"; break; }
        if [ "$known" = 0 ] && [ -r "$SHARED/minuisettings.txt" ]; then
            known=1
            every="$(rb_keepawake_every)"
            rb_keepawake_log "keep-awake loop $me: a tap every ${every} s (minuisettings.txt)"
        fi
        if rb_asleep || [ $((SECONDS - last)) -ge "$every" ]; then
            rb_tick >/dev/null 2>&1
            last=$SECONDS
        fi
        [ "$stop" = 0 ] || break
        sleep 1 &
        wait $! 2>/dev/null
    done
    [ "$stop" = 0 ] || rb_keepawake_log "keep-awake loop $me: stopped"
    [ "$(cat "$d/pid" 2>/dev/null)" != "$me" ] || rm -rf "$d"
}
# rb_keepawake_stop [wait s]: ends the lease and stops the loop cooperatively, waiting (5 s) for it. 0 when none runs.
rb_keepawake_stop() {
    local p n=0
    rm -f "${RB_TMP:-/tmp}/psp-keepawake.until"
    p="$(rb_keepawake_pid)"
    [ -n "$p" ] || return 0
    kill -TERM "$p" 2>/dev/null
    while kill -0 "$p" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -le $((${1:-5} * 5)) ] || { echo "the keep-awake loop (pid $p) did not stop" >&2; return 1; }
        sleep 0.2 2>/dev/null || sleep 1
    done
    rm -rf "$(rb_keepawake_dir)"
}

# --- the suspend counter -------------------------------------------------------------------------
# rb_debugfs_mount: debugfs is often not mounted: mount it (only when the mount point exists, is empty and nothing
# is mounted there; logged; never fails). RB_DEBUGFS_DIR (/sys/kernel/debug); RB_MOUNT_DEBUGFS=0 never mounts.
rb_debugfs_mount() {
    local dir="${RB_DEBUGFS_DIR:-/sys/kernel/debug}"
    [ "${RB_MOUNT_DEBUGFS:-1}" != 0 ] || return 0
    [ -d "$dir" ] || return 0
    grep -q " $dir debugfs " /proc/mounts 2>/dev/null && return 0
    [ -z "$(ls -A "$dir" 2>/dev/null)" ] || return 0
    if mount -t debugfs none "$dir" 2>/dev/null; then
        echo "mounted debugfs on $dir (for its suspend_stats)" >&2
    fi
    return 0
}
# rb_dmesg_pm: the power-management lines of dmesg (the ones that count suspends, of old and new kernels).
RB_PM_PATTERN='PM: suspend entry|PM: Syncing filesystems|Freezing user space processes|Restarting tasks|PM: suspend exit|PM: resume'
rb_dmesg_pm() { dmesg 2>/dev/null | grep -E "$RB_PM_PATTERN"; }
# rb_suspend_count: "<count> <source>": how often the kernel suspended since the boot: /sys/power/suspend_stats/
# success (newer kernels), the "success:" line of debugfs suspend_stats (mounted when it is not), else from dmesg:
# the most of "PM: suspend entry" (newer kernels), "PM: Syncing filesystems" and "Freezing user space processes"
# (each suspend prints them; 4.9 prints no "suspend entry"). dmesg's ring buffer can wrap (the count can then go
# DOWN). A dmesg with NO power-management line is "unknown" (source dmesg-nopm: this kernel may not log them, or
# it did not suspend); a count > 0 later still proves suspends. Fails (prints nothing) when no source works.
# RB_SUSPEND_STATS / RB_SUSPEND_DEBUGFS (host unit tests): other paths.
rb_suspend_count() {
    local f v="" pm a b c
    f="${RB_SUSPEND_STATS:-/sys/power/suspend_stats/success}"
    if [ -r "$f" ] && { read -r v <"$f"; } 2>/dev/null; then
        case "$v" in "" | *[!0-9]*) ;; *) echo "$v sysfs"; return 0 ;; esac
    fi
    [ -n "${RB_SUSPEND_DEBUGFS:-}" ] || rb_debugfs_mount
    f="${RB_SUSPEND_DEBUGFS:-${RB_DEBUGFS_DIR:-/sys/kernel/debug}/suspend_stats}"
    if [ -r "$f" ]; then
        v="$(sed -n 's/^success:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -n 1)"
        [ -z "$v" ] || { echo "$v debugfs"; return 0; }
    fi
    if command -v dmesg >/dev/null 2>&1 && v="$(dmesg 2>/dev/null)" && [ -n "$v" ]; then
        pm="$(printf '%s\n' "$v" | grep -E "$RB_PM_PATTERN")"
        if [ -z "$pm" ]; then
            echo "0 dmesg-nopm"
            return 0
        fi
        a="$(printf '%s\n' "$pm" | grep -c 'PM: suspend entry')"
        b="$(printf '%s\n' "$pm" | grep -c 'PM: Syncing filesystems')"
        c="$(printf '%s\n' "$pm" | grep -c 'Freezing user space processes')"
        [ "$b" -le "$a" ] || a="$b"
        [ "$c" -le "$a" ] || a="$c"
        echo "$a dmesg"
        return 0
    fi
    return 1
}
# rb_power_info: "<boot id> <suspend count or -> <source or none>" on the first line, for the host's ledger;
# then "screen: ..." (and the warning when it is off) and the last power-management lines of dmesg ("pm: ..."),
# so that a report shows what this kernel prints.
rb_power_info() {
    local id c l
    id="$(cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
    c="$(rb_suspend_count 2>/dev/null)" || c="- none"
    echo "${id:-?} $c"
    if rb_asleep; then echo "screen: $(rb_screen_state): $RB_SCREEN_OFF_MSG"; else echo "screen: $(rb_screen_state)"; fi
    command -v dmesg >/dev/null 2>&1 || return 0
    rb_dmesg_pm | tail -n 6 | while IFS= read -r l; do echo "pm: $l"; done
    return 0
}

# --- one backup or restore at a time ------------------------------------------------------------
# rb_backup and rb_restore hold a lock: the directory $RB_TMP/psp-test.lock with the pid of the shell that
# holds it (and what it does) in "pid". A backup runs as a detached job (rb_job_start): when the host gave up
# on it (its time limit, an unreachable device) it goes on; a restore (teardown_file) or a second backup next to it
# could interleave their copies (e.g. leave controls.ini with the test hotkeys and no active backup). A lock
# whose holder is gone (a killed shell, a reboot clears /tmp anyway) is stale and taken over.
rb_lock_dir() { echo "${RB_TMP:-/tmp}/psp-test.lock"; }
# rb_lock_holder: the pid (and what) of a LIVE holder of the lock, else nothing.
rb_lock_holder() {
    local d p="" w=""
    d="$(rb_lock_dir)"
    [ -r "$d/pid" ] && read -r p w <"$d/pid" 2>/dev/null
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p $w"
    return 0
}
# rb_lock <what> <wait s>: takes the lock, waiting up to <wait s> for a live holder to finish.
rb_lock() {
    local what="$1" limit="${2:-0}" d p="" w="" me="${BASHPID:-$$}" t0=$SECONDS
    d="$(rb_lock_dir)"
    while :; do
        if mkdir "$d" 2>/dev/null; then
            echo "$me $what" >"$d/pid"
            return 0
        fi
        p="" w=""
        [ -r "$d/pid" ] && read -r p w <"$d/pid" 2>/dev/null
        if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then # stale: the holder is gone
            rm -rf "$d"
            continue
        fi
        if [ -z "$p" ] && [ $((SECONDS - t0)) -ge 3 ]; then # the holder died between mkdir and writing its pid
            rm -rf "$d"
            continue
        fi
        if [ $((SECONDS - t0)) -ge "$limit" ]; then
            echo "a ${w:-backup or restore} of the test files is still running on the device (pid ${p:-?}): the $what does not run next to it" >&2
            return 1
        fi
        sleep 1
    done
}
rb_unlock() {
    local d p=""
    d="$(rb_lock_dir)"
    [ -r "$d/pid" ] && read -r p _ <"$d/pid" 2>/dev/null
    [ "$p" = "${BASHPID:-$$}" ] && rm -rf "$d"
    return 0
}
# rb_idle_settings: NextUI's idle times from minuisettings.txt, as "screentimeout=60 suspendTimeout=30"
# (only those two keys; the file also holds credentials). Empty when there is no such file or key.
rb_idle_settings() {
    grep -E '^(screentimeout|suspendTimeout)=[0-9]+' "$SHARED/minuisettings.txt" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/ $//'
}

# --- evidence about a boot ---------------------------------------------------------------
# rb_boot_report: what the device looks like now, relative to its boot, for a report (was a game launched
# after the boot, and when): the uptime, the boot id, the auto-resume marker (only when the SD card is
# mounted), the pak log (launch_sig, and how long ago it was written) and every process of NextUI,
# launch.sh, minui-power-control and PPSSPP with its start time in seconds after the boot (field 22 of
# /proc/<pid>/stat, in clock ticks). Read only, never fails.
rb_boot_report() {
    local up hz p first arg args st t log="$LOGS/PSP.txt" now mt
    read -r up _ </proc/uptime 2>/dev/null || up="?"
    hz="$(getconf CLK_TCK 2>/dev/null)"
    case "$hz" in "" | *[!0-9]*) hz=100 ;; esac
    echo "uptime: ${up} s"
    if rb_asleep; then echo "screen: $(rb_screen_state): $RB_SCREEN_OFF_MSG"; else echo "screen: $(rb_screen_state)"; fi
    echo "boot_id: $(cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)"
    if [ -d "$SHARED" ]; then
        if [ -e "$AUTORESUME" ]; then echo "auto-resume marker: PRESENT: $(cat "$AUTORESUME" 2>/dev/null)"; else echo "auto-resume marker: absent"; fi
        now="$(date +%s 2>/dev/null)"
        mt="$(date -r "$log" +%s 2>/dev/null)"
        echo "pak log: $(launch_sig "$log")${mt:+ (written $((now - mt)) s ago)}"
    else
        echo "auto-resume marker, pak log: unknown (the SD card is not mounted yet)"
    fi
    for p in /proc/[0-9]*; do
        first="" args=""
        while IFS= read -r -d '' arg || [ -n "$arg" ]; do
            [ -n "$first" ] || first="$arg"
            args="$args$arg "
        done 2>/dev/null <"$p/cmdline" || continue
        case "${first##*/} $args" in
        nextui.elf* | PPSSPPSDL* | minui-power-control* | *"/launch.sh"*) ;;
        *) continue ;;
        esac
        { IFS= read -r st <"$p/stat"; } 2>/dev/null || continue
        st="${st##*) }"
        # shellcheck disable=SC2086 # the fields of /proc/<pid>/stat after the command name
        set -- $st
        t="${20:-0}"
        echo "process ${p#/proc/}: started $((t / hz)).$(((t % hz) * 10 / hz)) s after the boot: ${args% }"
    done
    return 0
}

# Best-effort screenshot kept as evidence (the Screenshot Monitor pak is optional here).
rb_evidence_shot() { # rb_evidence_shot <label>
    [ -f "$MON/bin/screenshot" ] || return 0
    shot "$1"
    [ -s "$OUT/$1.png" ] && cat "$OUT/$1.png"
}

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
    BAK="$SHARED/.psp-reboot-backup" # on the SD card: survives the reboots and a cut-short run
    INI="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"
    CONTROLS="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/controls.ini"
    SHOTDIR="$SD/Screenshots"
    OUT="${RB_OUT:-${RB_TMP:-/tmp}/psp-reboot-out}"
    RB_TMP="${RB_TMP:-/tmp}"
    NEXT="$RB_TMP/next"
    WRAPPER="$RB_TMP/psp-test-poweroff"
    UI_WAIT="${UI_WAIT:-6}"
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
    for p in pgrep killall sync awk find; do
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

# --- backup / restore ------------------------------------------------------------------
# Like e2e.bats, plus ppsspp.ini. "active" is set first, so an abort at any point is restored
# by rb_restore (this run) or by the next run.
rb_backup() {
    local f
    mkdir -p "$BAK" "$MINUI"
    if [ -f "$BAK/active" ]; then
        echo "found the backup of an aborted run: restoring those files first"
        rb_stop_game
        restore_files
        rb_restore_states
        rm -f "$BAK/active"
    fi
    rm -f "$BAK/present" "$BAK/absent" "$BAK/states.before" "$BAK/marker" "$BAK"/evidence-* "$BAK/wrapper.log" "$BAK/trigger.log"
    : >"$BAK/active"
    sync
    for f in "$RECENT" "$PERSIST" "$AUTORESUME" "$SLOT_FILE" "$PREVIEW" "$INI"; do stash "$f"; done
    for f in "$MINUI/$ROM_FILE".*.bmp; do [ -f "$f" ] && stash "$f"; done
    mkdir -p "$STATE_DIR"
    ls -1 "$STATE_DIR" >"$BAK/states.before" 2>/dev/null
    # The tests save states (a slot of the test game is overwritten), so keep copies of every
    # existing state file and put them back in rb_restore.
    rm -rf "$BAK/states"
    mkdir -p "$BAK/states"
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        cp -p "$f" "$BAK/states/" || return 1
    done
    sync
}

# Puts back the state files backed up by rb_backup that were changed or deleted.
rb_restore_states() {
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

# Stops the emulator without saving anything, waits for NextUI to be back.
rb_game_up() { pgrep PPSSPPSDL >/dev/null 2>&1; }
rb_kill_game() { killall -9 "PPSSPPSDL_$PLATFORM" 2>/dev/null; }

rb_stop_game() {
    if rb_game_up; then
        rb_kill_game
        wait_for 30 rb_no_game
        # launch.sh (which writes the slot file and preview after the emulator) is done when
        # the launcher has started NextUI again.
        wait_for 90 running nextui.elf
    fi
    rm -f "$NEXT"
    return 0
}

# Puts everything back (also called at the start of a run that finds a backup).
rb_restore() {
    [ -f "$BAK/active" ] || return 0
    rb_stop_game
    rm -f "$WRAPPER"
    restore_files
    rb_restore_states
    rm -rf "$BAK/states"
    rm -f "$BAK/active"
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
# Marks "now" (states newer than this are new). FAT mtimes have 2 s resolution.
rb_mark() {
    touch "$BAK/marker"
    sleep 2
}

# Starts the game the way NextUI does: /tmp/next, then NextUI is restarted (SIGKILL, never SIGTERM).
rb_launch_game() {
    seed_recent
    mkdir -p "$MINUI"
    printf "'%s/launch.sh' '%s'\n" "$PAK" "$ROM" >"$NEXT"
    kill_ui
}

rb_ppsspp_pid() { pgrep PPSSPPSDL 2>/dev/null | head -n 1; }

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
# Waits (up to ~30 s) until two reads one second apart are equal: PPSSPP may still be writing.
rb_wait_states_stable() {
    local a b n=0
    a="$(rb_snapshot_states)"
    while [ "$n" -lt 30 ]; do
        sleep 1
        b="$(rb_snapshot_states)"
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
        sleep 1
        # shellcheck disable=SC2086 # command and its flag
        $c
    ) >/dev/null 2>&1 </dev/null &
}

# --- keeping the device awake ------------------------------------------------------------
# True if the screen looks off (backlight at 0 or powered down). SLEEP_PROBE (a command, true
# when asleep) overrides this for devices where the sysfs guess is wrong.
rb_asleep() {
    local f v found=0
    if [ -n "${SLEEP_PROBE:-}" ]; then
        sh -c "$SLEEP_PROBE" >/dev/null 2>&1
        return
    fi
    # One clear signal only: a backlight node that says "powered down" (bl_power != 0, the
    # FB_BLANK values). A brightness of 0 proves nothing (it can be the user's setting), and
    # without a bl_power node the answer is "awake": the power key is never tapped on a guess.
    for f in "${RB_BACKLIGHT_DIR:-/sys/class/backlight}"/*/bl_power; do
        [ -r "$f" ] || continue
        found=1
        read -r v <"$f"
        [ "$v" = 0 ] || return 0
    done
    [ "$found" = 1 ] && return 1
    return 1
}

# Taps KEY_POWER (code 116, a short tap, well under the 2 s long press that powers off) on the
# power key's input device: POWER_DEV_NAME (regex) is matched against the device names.
rb_wake() {
    local dev
    dev="$(awk -v re="${POWER_DEV_NAME:-axp|pek|power|gpio-keys}" '
        /^N: Name=/ { name = $0; sub(/^N: Name="/, "", name); sub(/"$/, "", name); use = (name ~ re && name !~ /TRIMUI Player/) }
        use && /^H: Handlers=/ { for (i = 1; i <= NF; i++) if ($i ~ /^event/) { print "/dev/input/" $i; exit } }
    ' /proc/bus/input/devices 2>/dev/null)"
    [ -c "$dev" ] || { echo "no power key device found (POWER_DEV_NAME)" >&2; return 1; }
    PAD="$dev" pad 1 116 1
    PAD="$dev" syn
    sleep 0.2
    PAD="$dev" pad 1 116 0
    PAD="$dev" syn
}

# One keep-awake step: wake the device if it sleeps, otherwise a harmless tap on the pad (any
# input restarts the idle timer of NextUI's auto sleep).
rb_tick() {
    if rb_asleep; then
        rb_wake
    else
        press "${KEEPAWAKE_KEY:-l1}"
    fi
}

# Best-effort screenshot kept as evidence (the Screenshot Monitor pak is optional here).
rb_evidence_shot() { # rb_evidence_shot <label>
    [ -f "$MON/bin/screenshot" ] || return 0
    shot "$1"
    [ -s "$OUT/$1.png" ] && cat "$OUT/$1.png"
}

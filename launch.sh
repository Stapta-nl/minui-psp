#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
[ -f "$USERDATA_PATH/PSP-ppsspp/debug" ] && set -x

# shellcheck disable=SC2153 # LOGS_PATH is set by NextUI/MinUI
rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/PSP-ppsspp"

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export PAK_DIR="$SDCARD_PATH/Emus/$PLATFORM/$PAK_NAME.pak"
export EMU_DIR="$PAK_DIR/PPSSPP"

export PATH="$EMU_DIR:$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
export HOME="$EMU_DIR"
export LD_LIBRARY_PATH="$EMU_DIR:$PAK_DIR/lib:/usr/trimui/lib:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG_FILE="$EMU_DIR/assets/gamecontrollerdb.txt"

PPSSPP_BIN="PPSSPPSDL"
PPSSPP_SYSTEM_DIR="$EMU_DIR/.config/ppsspp/PSP/SYSTEM"
PPSSPP_INI="$PPSSPP_SYSTEM_DIR/ppsspp.ini"

# shellcheck source=scripts/ini.sh
. "$PAK_DIR/scripts/ini.sh"
# shellcheck source=scripts/retroachievements.sh
. "$PAK_DIR/scripts/retroachievements.sh"

# Teardown runs once: arm_auto_resume_and_wait calls it before its wait, and
# the EXIT trap calls it again.
CLEANED=""
MOUNTED_SAVEDATA=""
MOUNTED_STATE=""
cleanup() {
    [ -z "$CLEANED" ] || return 0
    CLEANED=1
    write_game_switcher_preview
    rm -f /tmp/stay_awake
    # Only our own pid file (a newer launch.sh may have replaced it).
    [ "$(cat "$PAK_PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PAK_PID_FILE"
    # Temp files left behind if a signal interrupted an ini/token write.
    rm -f "$PPSSPP_INI.tmp.$$" "$PPSSPP_RA_TOKEN_FILE.tmp.$$"
    
    restore_cpu_settings 0
    restore_cpu_settings 4

    # Only what we mounted. States, marker and preview are synced by now.
    if [ -n "$MOUNTED_SAVEDATA" ]; then
        umount "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA" 2>/dev/null || echo "Could not unmount SAVEDATA."
    fi
    if [ -n "$MOUNTED_STATE" ]; then
        umount "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE" 2>/dev/null || echo "Could not unmount PPSSPP_STATE."
    fi
}

# Succeeds (and says so) when the user opted out of config changes.
config_changes_disabled() {
    [ -f "$USERDATA_PATH/PSP-ppsspp/no-config-changes" ] || return 1
    echo "${1}Config changes disabled via no-config-changes flag."
}

# Set one setting in [SECTION] of ppsspp.ini; a missing setting is added:
#   update_ppsspp_setting SECTION NAME VALUE
update_ppsspp_setting() {
    section="$1"
    setting_name="$2"
    setting_value="$3"

    # Allow users to disable config changes
    config_changes_disabled && return

    if [ ! -f "$PPSSPP_INI" ]; then
        echo "Error: $PPSSPP_INI not found."
        exit 1
    fi

    set_ini_values "$PPSSPP_INI" "$section" "$setting_name" "$setting_value"
}

save_cpu_settings() {
    cpu_num="$1"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    cat "${cpu_path}/scaling_governor" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt"
    cat "${cpu_path}/scaling_min_freq" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt"
    cat "${cpu_path}/scaling_max_freq" >"$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt"
}

restore_cpu_settings() {
    cpu_num="$1"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt" >"${cpu_path}/scaling_governor"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_governor.txt"
    fi
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt" >"${cpu_path}/scaling_min_freq"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_min_freq.txt"
    fi
    if [ -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt" ]; then
        cat "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt" >"${cpu_path}/scaling_max_freq"
        rm -f "$USERDATA_PATH/PSP-ppsspp/cpu${cpu_num}_max_freq.txt"
    fi
}

set_cpu_settings() {
    cpu_num="$1"
    governor="$2"
    min_freq="$3"
    max_freq="$4"
    cpu_path="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq"
    
    echo "$governor" >"${cpu_path}/scaling_governor"
    echo "$min_freq" >"${cpu_path}/scaling_min_freq"
    echo "$max_freq" >"${cpu_path}/scaling_max_freq"
}

# Auto-resume after shutdown.
# NextUI/MinUI read $SHARED_USERDATA_PATH/.minui/auto_resume.txt on boot
# (autoResume()): it holds the ROM path relative to $SDCARD_PATH, is deleted
# as soon as it is read, and the ROM is relaunched through its Emu Pak.
# minarch writes it only right before it powers the device off, so a crash,
# a forced power-off or a dead battery never resumes. We follow the same
# rule: the marker is written only once a power-off has been positively
# detected, never while the game is running.
#
# The game itself is resumed by PPSSPP, not by us: with "Save state on exit"
# ([General] SaveStateOnExit) on, PPSSPP saves a state when it is stopped,
# also on SIGTERM (power-off), within 5 s; with "Auto load savestate"
# ([General] AutoLoadSaveState, 2 = newest) it loads it again on the next
# start. We never pass --state: the pak only decides whether to relaunch.
AUTO_RESUME_PATH="$SHARED_USERDATA_PATH/.minui/auto_resume.txt"
# Written by NextUI/MinUI on an auto-resume (slot 9) for minarch, which reads
# and deletes it. PPSSPP never reads it, so we remove it ourselves, otherwise
# the next built-in core started in this boot would load its slot 9 state.
RESUME_SLOT_PATH="/tmp/resume_slot.txt"

set_auto_resume() {
    rom_path="$1"
    case "$rom_path" in
        "$SDCARD_PATH"/*) ;;
        *) return 1 ;;
    esac
    mkdir -p "$(dirname "$AUTO_RESUME_PATH")"
    printf '%s' "${rom_path#"$SDCARD_PATH"}" >"$AUTO_RESUME_PATH.tmp" &&
        mv -f "$AUTO_RESUME_PATH.tmp" "$AUTO_RESUME_PATH"
    sync
}

# Seconds since the epoch (0 if date cannot tell).
now() {
    date +%s 2>/dev/null || echo 0
}

# Runs next to PPSSPP. PPSSPP promises to quit within ~5 s of the SIGTERM, but
# if it hangs the poweroff shim gives up after 15 s and the device goes off
# without a marker. So: once the shim has asked for the power-off and PPSSPP
# is still running after PSP_PPSSPP_WAIT seconds (default 8), arm the marker
# and release the shim right away; PPSSPP may still finish its save, and the
# newest state is loaded either way.
# If PPSSPP is still running PSP_REQ_MAX_AGE seconds (default 20: the shim's
# cap plus a margin) after the request, the power-off did not happen (aborted:
# poweroff would have killed us): the marker, request and ok file are withdrawn,
# so a later crash or a later normal quit is not taken for a power-off.
# $1 PPSSPP pid, $2 ROM path.
poweroff_watchdog() {
    wd_pid="$1"
    wd_rom="$2"
    wd_wait="${PSP_PPSSPP_WAIT:-8}"
    case "$wd_wait" in "" | *[!0-9]*) wd_wait=8 ;; esac
    wd_max="${PSP_REQ_MAX_AGE:-20}"
    case "$wd_max" in "" | *[!0-9]*) wd_max=20 ;; esac
    # The shim must have time to see the ok file.
    [ "$wd_max" -ge $((wd_wait + 2)) ] || wd_max=$((wd_wait + 2))
    while kill -0 "$wd_pid" 2>/dev/null; do
        if [ -f "$POWEROFF_REQ" ]; then
            i=0
            while [ "$i" -lt "$wd_wait" ]; do
                sleep 1
                i=$((i + 1))
                kill -0 "$wd_pid" 2>/dev/null || return 0
            done
            echo "PPSSPP still running ${wd_wait}s after the power-off request: arming auto-resume without waiting for it."
            set_auto_resume "$wd_rom" && echo "Auto-resume armed for $wd_rom."
            : >"$POWEROFF_OK"
            while [ "$i" -lt "$wd_max" ]; do
                sleep 1
                i=$((i + 1))
                kill -0 "$wd_pid" 2>/dev/null || return 0
            done
            echo "PPSSPP still running ${i}s after the power-off request: the power-off did not happen, withdrawing the auto-resume marker."
            rm -f "$AUTO_RESUME_PATH" "$POWEROFF_REQ" "$POWEROFF_OK"
            sync
            continue
        fi
        sleep 1
    done
}

# Power-off handshake with bin/poweroff (see that script). The power button's
# shutdown script runs `poweroff` from our PATH; the shim creates
# $POWEROFF_REQ and waits (at most ~15 s) for us to create $POWEROFF_OK, which
# we do only once the auto-resume marker is on disk. $PAK_PID_FILE tells the
# shim that we are alive. The request file may not exist yet when PPSSPP has
# exited: the shutdown script signals PPSSPP, then syncs and shows its
# "Powering off" message, and only then runs `poweroff`. That is fine: the
# pgrep check in shutdown_in_progress() sees the shutdown script, and a shim
# that arrives after the ok file exists does not wait at all.
#
# Time budget (the shim waits at most 15 s from its start, which is at or after
# the SIGTERM; PPSSPP exits at most ~7 s after the SIGTERM: 5 s hard limit for
# the save, then its shutdown):
#   - PPSSPP still running 8 s after the request appears: poweroff_watchdog()
#     arms the marker and releases the shim anyway (ok at ~9-10 s, cap 15 s).
#   - PPSSPP exited on a signal but no power-off is visible yet: up to
#     PSP_SHUTDOWN_GRACE seconds (default 3) of polling, see
#     shutdown_in_progress(). This is spent before the shim's request exists
#     (once it does, the first poll sees it), and it counts as time since
#     PPSSPP exited, so it can only make the preview be skipped, never delay
#     the ok file past the numbers below.
#   - after PPSSPP exits: marker + sync first; the preview only if that was
#     quick (PSP_PREVIEW_BUDGET, default 3 s), so the ok file is given at most
#     ~7 s + 3 s + 3 s after the SIGTERM; nothing slow happens after it.
POWEROFF_REQ="/tmp/psp-poweroff-req"
POWEROFF_OK="/tmp/psp-poweroff-ok"
PAK_PID_FILE="/tmp/psp-pak.pid"

# Logs the global save-on-exit/auto-load settings (a per-game config of
# PPSSPP may override them). Read only, for diagnosing resumes.
log_resume_settings() {
    [ -f "$PPSSPP_INI" ] || return 0
    awk '
        { sub(/\r$/, "") }
        # The shipped ini starts with a UTF-8 BOM, so do not anchor at the start.
        /\[[^]]*\]$/ { general = ($0 ~ /\[General\]$/); next }
        general && /^(SaveStateOnExit|AutoLoadSaveState|StateSlot)[ \t]*=/ {
            key = $0; sub(/[ \t]*=.*/, "", key)
            val = $0; sub(/^[^=]*=[ \t]*/, "", val)
            v[key] = val
        }
        END {
            printf "PPSSPP settings: SaveStateOnExit=%s AutoLoadSaveState=%s StateSlot=%s\n",
                ("SaveStateOnExit" in v ? v["SaveStateOnExit"] : "(unset, off)"),
                ("AutoLoadSaveState" in v ? v["AutoLoadSaveState"] : "(unset, off)"),
                ("StateSlot" in v ? v["StateSlot"] : "(unset)")
        }' "$PPSSPP_INI"
}

# True if $POWEROFF_REQ is older than PSP_REQ_MAX_AGE seconds (default 20,
# the shim's 15 s cap plus a margin). The shim writes the epoch into it; a
# file without a number (older shim, tests) counts as fresh.
request_is_stale() {
    max_age="${PSP_REQ_MAX_AGE:-20}"
    case "$max_age" in "" | *[!0-9]*) max_age=20 ;; esac
    req_ts=""
    read -r req_ts <"$POWEROFF_REQ" 2>/dev/null
    case "$req_ts" in "" | *[!0-9]*) return 1 ;; esac
    req_now="$(now)"
    [ "$req_now" -gt 0 ] || return 1
    [ $((req_now - req_ts)) -gt "$max_age" ]
}

# One look for signs of a power-off; says which one it found.
power_off_visible() {
    # Written by our poweroff shim (bin/poweroff): the primary signal.
    if [ -f "$POWEROFF_REQ" ]; then
        if request_is_stale; then
            # A power-off that never happened (the watchdog normally clears it).
            echo "Ignoring a stale power-off request ($POWEROFF_REQ is older than the shim's wait)."
            rm -f "$POWEROFF_REQ" "$POWEROFF_OK"
        else
            echo "Power-off detected: $POWEROFF_REQ exists."
            return 0
        fi
    fi
    # Set by NextUI and by minui-power-control 3.0.0+.
    if [ -f /tmp/poweroff ]; then
        echo "Power-off detected: /tmp/poweroff exists."
        return 0
    fi
    # minui-power-control 1.x/2.x: button-handler runs its `shutdown` script
    # by absolute path (/tmp/selfgz*/shutdown). That script kills the
    # emulator first, then syncs, shows "Powering off" and only then runs
    # `poweroff`, so this can lose the race against it (hence the shim, and
    # the grace period in shutdown_in_progress). Match the command line only:
    # the selfgz dir itself is deleted as soon as power-control's launcher
    # notices the emulator is gone.
    if pgrep -f '/shutdown$|^([^ ]*/)?poweroff( |$)' >/dev/null 2>&1; then
        echo "Power-off detected: shutdown/poweroff process found."
        return 0
    fi
    return 1
}

# True if the device is powering off (rather than the user quitting PPSSPP).
# Called once, right after PPSSPP exits. $1: grace period in seconds (0: look
# once). When PPSSPP was stopped by a signal the shutdown script is at work
# and its `poweroff` (our shim, which creates $POWEROFF_REQ) usually comes a
# moment later, so look again for that long. A user quit passes 0: no delay.
shutdown_in_progress() {
    grace="$1"
    case "$grace" in "" | *[!0-9]*) grace=0 ;; esac
    ticks=0
    while :; do
        if power_off_visible; then
            [ "$ticks" -eq 0 ] || echo "(found after waiting $((ticks / 2)).$((ticks % 2 * 5))s)"
            return 0
        fi
        [ "$ticks" -lt $((grace * 2)) ] || break
        # Half-second steps; a sleep without fractions takes a whole second.
        if sleep 0.5 2>/dev/null; then
            ticks=$((ticks + 1))
        else
            sleep 1
            ticks=$((ticks + 2))
        fi
    done
    if [ "$grace" -gt 0 ]; then
        echo "No power-off detected within ${grace}s (no request file, no /tmp/poweroff, no shutdown process; pgrep: $(command -v pgrep || echo missing)): treating this as a normal exit."
    fi
    return 1
}

# minui-power-control's shutdown script draws "Powering off" (minui-presenter,
# forever) before PPSSPP's save is known to be done. Like NextUI's minarch
# cores, say "Quicksave created, powering off" instead, but only once a state
# really was saved during this launch (newer than $STATE_MARKER). Best effort:
# show_message runs in the background and is never waited for; it times out
# by itself if the device does not power off. A state counts as saved if it is
# newer than the launch, so a state the player saved by hand counts too when
# save-on-exit is off (no cheap reliable way to tell the two apart here).
show_quicksave_message() {
    saved=""
    for ppst in "$STATE_DIR"/*.ppst; do
        case "$ppst" in *.undo.ppst) continue ;; esac
        # shellcheck disable=SC3013 # -nt is supported by BusyBox ash and dash
        if [ -f "$ppst" ] && [ "$ppst" -nt "$STATE_MARKER" ]; then
            saved=1
            break
        fi
    done
    [ -n "$saved" ] || return 0
    command -v show_message >/dev/null 2>&1 || return 0
    # The shim creates the request file only after the shutdown script has
    # started its "Powering off" presenter: wait for it (at most 2 s, then go
    # on anyway) so that our killall below cannot come too early.
    waited=0
    while [ ! -f "$POWEROFF_REQ" ] && [ "$waited" -lt 4 ]; do
        sleep 0.5 2>/dev/null || sleep 1
        waited=$((waited + 1))
    done
    echo "Showing the quicksave message."
    # Replace the "Powering off" screen instead of drawing over it.
    killall minui-presenter >/dev/null 2>&1 || true
    show_message "Quicksave created, powering off" 10 >/dev/null 2>&1 &
}

# Arm auto-resume, tell the poweroff shim it may go ahead, then wait for the
# power-off to finish. We must not return to NextUI/MinUI here: on its next
# start it would read (and delete) the marker before the device is off.
# PPSSPP has already exited, so its save on exit (state and thumbnail) is
# complete or was given up; the marker is armed either way, and PPSSPP then
# loads the newest state it has for the game.
arm_auto_resume_and_wait() {
    rom_path="$1"

    armed=0
    if set_auto_resume "$rom_path"; then
        armed=1
        echo "Auto-resume armed for $rom_path."
    else
        echo "Auto-resume not armed ($rom_path is not on the SD card)."
    fi
    # set_auto_resume already synced (marker and the state PPSSPP just wrote).
    [ "$armed" = 1 ] || sync
    # The marker comes first, so a slow preview can never cost the resume.
    # The preview (one small JPEG conversion, then sync) is only made when the
    # steps since PPSSPP exited were quick: it is best effort, and the shim's
    # window must not be eaten by it.
    budget="${PSP_PREVIEW_BUDGET:-3}"
    case "$budget" in "" | *[!0-9]*) budget=3 ;; esac
    used=$(($(now) - ${PPSSPP_EXIT_TS:-0}))
    if [ -n "$PPSSPP_EXIT_TS" ] && [ "$used" -gt "$budget" ]; then
        echo "Skipping the Game Switcher preview and the quicksave message: ${used}s since PPSSPP exited."
        PREVIEW_ROM=""
    else
        [ "$armed" = 1 ] && show_quicksave_message
        write_game_switcher_preview
    fi
    : >"$POWEROFF_OK"
    echo "Told the poweroff shim to go ahead."
    # Marker, states and preview are synced and PPSSPP is gone: release the
    # bind mounts (poweroff would anyway) and restore CPU settings now; the
    # EXIT trap's cleanup is then a no-op.
    cleanup
    # Nothing armed: nothing to protect, return as before PR #6.
    [ "$armed" = 1 ] || return 0
    # The caller ignores INT/TERM/HUP/QUIT (trap "") and children inherit
    # that, so one sleep cannot be cut short; poweroff ends us with SIGKILL.
    # If the device has not powered off after a minute (PSP_AUTORESUME_WAIT,
    # for tests), drop the marker and go back to the menu.
    wait_secs="${PSP_AUTORESUME_WAIT:-60}"
    case "$wait_secs" in "" | *[!0-9]*) wait_secs=60 ;; esac
    sleep "$wait_secs"
    echo "Device did not power off, removing auto-resume marker."
    rm -f "$AUTO_RESUME_PATH" "$POWEROFF_REQ" "$POWEROFF_OK"
    sync
}

# Game switcher preview.
# NextUI's game switcher shows $SHARED_USERDATA_PATH/.minui/<EMU>/<rom file>.<slot>.bmp,
# but only when $SHARED_USERDATA_PATH/.minui/<EMU>/<rom file>.txt exists and holds <slot>
# (see readyResumePath() in NextUI's nextui.c). The image is opened with IMG_Load, so the
# content may be BMP or PNG regardless of the .bmp name (minarch itself writes PNG there).
# The stock TrimUI SDL2_image cannot decode JPEG, so PPSSPP's save-state thumbnails are
# converted to BMP with the bundled jpg2bmp.
#
# Like minarch, the image only ever comes from a save state: the newest state saved during
# this launch, with its slot written to <rom file>.txt. No save state, no preview (NextUI
# then shows "No Preview"). Resume handling is not changed by this.
STATE_DIR="$SHARED_USERDATA_PATH/PSP-ppsspp"
PREVIEW_ROM=""
# Touched at launch: states saved afterwards have a newer mtime. Only the shell's own
# test (-nt) is used, because the device's BusyBox has no cksum and few other tools.
# (The SD card is FAT with 2 s mtime resolution; a save is never made within 2 s of launch.)
STATE_MARKER="/tmp/psp-ppsspp-launch-marker"

# Prints the NextUI emu tag of a ROM the way NextUI's getEmuName() does: the Roms folder
# name, then the text in its last (...). Falls back to the pak name, then "PSP".
game_switcher_emu_tag() {
    emu_tag=""
    if [ -n "$ROMS_PATH" ]; then
        case "$1" in
        "$ROMS_PATH"/*/*)
            emu_tag="${1#"$ROMS_PATH"/}"
            emu_tag="${emu_tag%%/*}"
            ;;
        esac
    fi
    case "$emu_tag" in
    *"("*")"*)
        emu_tag="${emu_tag##*(}"
        emu_tag="${emu_tag%%)*}"
        ;;
    esac
    [ -n "$emu_tag" ] || emu_tag="$PAK_NAME"
    [ -n "$emu_tag" ] || emu_tag="PSP"
    printf '%s' "$emu_tag"
}

# Converts JPEG $1 to $2 through a temp file, so a partial file never replaces the preview.
install_preview() {
    jpg2bmp "$1" "$2.tmp" && mv -f "$2.tmp" "$2" && return 0
    rm -f "$2.tmp"
    return 1
}

# Called after PPSSPP exits and from cleanup(), so it also runs when the script is
# signalled (e.g. SIGTERM on power-off). Does its work at most once per launch.
write_game_switcher_preview() {
    rom_path="$PREVIEW_ROM"
    PREVIEW_ROM=""
    [ -n "$rom_path" ] && [ -n "$SHARED_USERDATA_PATH" ] || return 0

    # Thumbnails saved since launch. Only the launched game ran, so they all belong to it;
    # take the newest (undo thumbnails excluded).
    thumb=""
    for jpg in "$STATE_DIR"/*.jpg; do
        case "$jpg" in *.undo.jpg) continue ;; esac
        [ -f "$jpg" ] || continue
        # shellcheck disable=SC3013 # -nt is supported by BusyBox ash and dash
        [ "$jpg" -nt "$STATE_MARKER" ] || continue
        # shellcheck disable=SC3013
        if [ -z "$thumb" ] || [ "$jpg" -nt "$thumb" ]; then
            thumb="$jpg"
        fi
    done
    [ -n "$thumb" ] || return 0

    # PPSSPP names states <DISC_ID>_<DISC_VERSION>_<slot>.ppst/.jpg
    slot="$(basename "$thumb" .jpg)"
    slot="${slot##*_}"
    case "$slot" in "" | *[!0-9]*) return 0 ;; esac

    rom_file="$(basename "$rom_path")"
    minui_dir="$SHARED_USERDATA_PATH/.minui/$(game_switcher_emu_tag "$rom_path")"
    mkdir -p "$minui_dir" || return 0

    # Image first, then the slot file that makes NextUI look for it.
    if install_preview "$thumb" "$minui_dir/$rom_file.$slot.bmp"; then
        echo "Game switcher preview from save state: $thumb"
        printf '%s' "$slot" >"$minui_dir/$rom_file.txt.tmp" &&
            mv -f "$minui_dir/$rom_file.txt.tmp" "$minui_dir/$rom_file.txt"
        sync
    fi
}

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT
    trap "exit 1" INT TERM HUP QUIT

    # Power-off handshake: drop leftovers of a previous run, announce ourselves.
    rm -f "$POWEROFF_REQ" "$POWEROFF_OK"
    echo "$$" >"$PAK_PID_FILE"

    # NextUI/MinUI already consumed the marker if this is an auto-resume and
    # left the slot it chose here: 9 for an auto-resume, 8 for a normal open.
    # Read it before it is dropped (minarch is its only real consumer).
    resume_slot=""
    [ -f "$RESUME_SLOT_PATH" ] && read -r resume_slot <"$RESUME_SLOT_PATH"
    echo "Resume slot: '$resume_slot'"
    rm -f "$RESUME_SLOT_PATH" "$AUTO_RESUME_PATH"

    if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
        export PLATFORM="tg5040"
    fi

    if [ "$PLATFORM" = "tg5040" ]; then

        # Detect Trimui model (Brick or Smart Pro)
        trimui_model=$(strings /usr/trimui/bin/MainUI | grep ^Trimui)
        if [ "$trimui_model" = "Trimui Brick" ]; then
            update_ppsspp_setting "Graphics" "DisplayAspectRatio" "0.848000"
        else
            update_ppsspp_setting "Graphics" "DisplayAspectRatio" "1.000000"
        fi

        update_ppsspp_setting "Graphics" "GraphicsBackend" "0 (OPENGL)"
        export SDL_VIDEODRIVER=mali
        setalpha 0
        rm -f "$EMU_DIR/.config/ppsspp/PSP/SYSTEM/FailedGraphicsBackends.txt"
        save_cpu_settings 0
        set_cpu_settings 0 ondemand 1608000 1800000

    elif [ "$PLATFORM" = "tg5050" ]; then
        update_ppsspp_setting "Graphics" "DisplayAspectRatio" "1.000000"
        update_ppsspp_setting "Graphics" "GraphicsBackend" "3 (VULKAN)"
        save_cpu_settings 0
        save_cpu_settings 4
        set_cpu_settings 0 ondemand 1416000 1416000
        set_cpu_settings 4 performance 1992000 2160000
    fi

    if ! command -v minui-power-control >/dev/null 2>&1; then
        show_message "Minui-power-control not found." 3
        exit 1
    fi

    chmod +x "$PAK_DIR/bin/minui-power-control"
    # Without the exec bit the poweroff shim is skipped and the marker may be written too late.
    chmod +x "$PAK_DIR/bin/poweroff" 2>/dev/null

    allowed_platforms="tg5040 tg5050"
    if ! echo "$allowed_platforms" | grep -q "$PLATFORM"; then
        echo "$PLATFORM is not a supported platform."
        exit 1
    fi

    sync_retroachievements

    mkdir -p "$SDCARD_PATH/Saves/PSP"
    mkdir -p "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA"
    mount -o bind "$SDCARD_PATH/Saves/PSP" "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA" && MOUNTED_SAVEDATA=1

    mkdir -p "$SHARED_USERDATA_PATH/PSP-ppsspp"
    mkdir -p "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE"
    mount -o bind "$SHARED_USERDATA_PATH/PSP-ppsspp" "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE" && MOUNTED_STATE=1

    touch "$STATE_MARKER"
    # One ROM variable (NextUI passes the path as the argument(s)).
    rom_arg="$*"
    PREVIEW_ROM="$rom_arg"

    # An auto-resume (slot 9) starts like any other launch: PPSSPP's own
    # "Auto load savestate" loads the state it saved on exit.
    [ "$resume_slot" = "9" ] && echo "Auto-resume launch: PPSSPP loads the game's save state itself."
    log_resume_settings

    # Launch emulator
    minui-power-control "${PPSSPP_BIN}_${PLATFORM}" &
    # PPSSPP runs in the background so that poweroff_watchdog can bound the
    # wait; signals are only noted until it is gone, like with a foreground
    # child: a SIGTERM must not end this script while PPSSPP is still saving.
    got_signal=""
    trap 'got_signal=1' INT TERM HUP QUIT
    "${PPSSPP_BIN}_${PLATFORM}" "$rom_arg" --fullscreen --pause-menu-exit &
    ppsspp_pid=$!
    poweroff_watchdog "$ppsspp_pid" "$rom_arg" &
    watchdog_pid=$!
    ppsspp_rc=0
    while kill -0 "$ppsspp_pid" 2>/dev/null; do
        wait "$ppsspp_pid" 2>/dev/null
        ppsspp_rc=$?
    done
    PPSSPP_EXIT_TS="$(now)"
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null

    # PPSSPP exited (after its save on exit, if that is on). A SIGTERM from
    # here on most likely comes from poweroff tearing everything down: finish
    # the decision instead of dying halfway.
    trap "" INT TERM HUP QUIT
    # Exit status above 128: killed by a signal (the shutdown script's SIGTERM
    # if PPSSPP does not handle it itself). A user Exit is not delayed.
    grace=0
    if [ "$ppsspp_rc" -gt 128 ] || [ -n "$got_signal" ]; then
        grace="${PSP_SHUTDOWN_GRACE:-3}"
        echo "PPSSPP stopped by a signal (status $ppsspp_rc): looking for a power-off for up to ${grace}s."
    fi
    if shutdown_in_progress "$grace"; then
        # Marker, then preview, then ok (see arm_auto_resume_and_wait).
        arm_auto_resume_and_wait "$rom_arg"
    else
        write_game_switcher_preview
    fi
    trap "exit 1" INT TERM HUP QUIT
    # Signalled while PPSSPP ran and it was no power-off: end as a signal does.
    [ -z "$got_signal" ] || exit 1
}

main "$@"

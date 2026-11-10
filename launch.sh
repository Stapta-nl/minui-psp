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

cleanup() {
    write_game_switcher_preview
    rm -f /tmp/stay_awake
    # Only our own pid file (a newer launch.sh may have replaced it).
    [ "$(cat "$PAK_PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PAK_PID_FILE"
    # Temp files left behind if a signal interrupted an ini/token write.
    rm -f "$PPSSPP_INI.tmp.$$" "$PPSSPP_RA_TOKEN_FILE.tmp.$$"
    
    restore_cpu_settings 0
    restore_cpu_settings 4

    umount "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA" || true
    umount "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE" || true
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

# Power-off handshake with bin/poweroff (see that script). The power button's
# shutdown script runs `poweroff` from our PATH; the shim creates
# $POWEROFF_REQ and waits (at most ~15 s) for us to create $POWEROFF_OK, which
# we do only once the auto-resume marker is on disk. $PAK_PID_FILE tells the
# shim that we are alive. By the time PPSSPP has exited (after its save on
# exit) the request file exists, since the shutdown script signals PPSSPP and
# then runs `poweroff`.
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

# True if the device is powering off (rather than the user quitting PPSSPP).
# Called once, right after PPSSPP exits.
shutdown_in_progress() {
    # Written by our poweroff shim (bin/poweroff): the primary signal.
    if [ -f "$POWEROFF_REQ" ]; then
        echo "Power-off detected: $POWEROFF_REQ exists."
        return 0
    fi
    # Set by NextUI and by minui-power-control 3.0.0+.
    if [ -f /tmp/poweroff ]; then
        echo "Power-off detected: /tmp/poweroff exists."
        return 0
    fi
    # minui-power-control 1.x/2.x: button-handler runs its `shutdown` script
    # by absolute path (/tmp/selfgz*/shutdown). That script kills the
    # emulator first, then runs `poweroff` and sleeps until the system kills
    # it. This check can lose the race against it, hence the shim above.
    # Match the command line only: the selfgz dir itself is deleted as soon as
    # power-control's launcher notices the emulator is gone.
    if pgrep -f '/shutdown$|^([^ ]*/)?poweroff( |$)' >/dev/null 2>&1; then
        echo "Power-off detected: shutdown/poweroff process found."
        return 0
    fi
    return 1
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
    sync
    # The marker comes first, so a slow preview can never cost the resume.
    # The preview (one small JPEG conversion, then sync) is quick, so it fits
    # in the shim's window and is on the card before power is cut.
    write_game_switcher_preview
    : >"$POWEROFF_OK"
    echo "Told the poweroff shim to go ahead."
    cleanup
    # Nothing armed: nothing to protect, return as before PR #6.
    [ "$armed" = 1 ] || return 0
    # Signals are ignored by the caller; poweroff ends us with SIGKILL. If
    # the device has not powered off after a minute (PSP_AUTORESUME_WAIT, for
    # tests), drop the marker and go back to the menu.
    wait_secs="${PSP_AUTORESUME_WAIT:-60}"
    case "$wait_secs" in "" | *[!0-9]*) wait_secs=60 ;; esac
    i=0
    while [ "$i" -lt "$wait_secs" ]; do
        sleep 1
        i=$((i + 1))
    done
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
    mount -o bind "$SDCARD_PATH/Saves/PSP" "$EMU_DIR/.config/ppsspp/PSP/SAVEDATA"

    mkdir -p "$SHARED_USERDATA_PATH/PSP-ppsspp"
    mkdir -p "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE"
    mount -o bind "$SHARED_USERDATA_PATH/PSP-ppsspp" "$EMU_DIR/.config/ppsspp/PSP/PPSSPP_STATE"

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
    "${PPSSPP_BIN}_${PLATFORM}" "$rom_arg" --fullscreen --pause-menu-exit

    # PPSSPP exited (after its save on exit, if that is on). A SIGTERM from
    # here on most likely comes from poweroff tearing everything down: finish
    # the decision instead of dying halfway.
    trap "" INT TERM HUP QUIT
    if shutdown_in_progress; then
        # Marker, then preview, then ok (see arm_auto_resume_and_wait).
        arm_auto_resume_and_wait "$rom_arg"
    else
        write_game_switcher_preview
    fi
    trap "exit 1" INT TERM HUP QUIT
}

main "$@"

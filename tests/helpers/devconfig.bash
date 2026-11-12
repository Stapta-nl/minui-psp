# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the files that source this one
# What the on-device tests need to know about the device's configuration, read from the device
# instead of assumed. Used by tests/bats/e2e.bats (on the device) and by the kit of
# tests/bats/reboot.bats (streamed to the device). Needs awk (BusyBox is fine) and, for the
# key checks, btn_set from e2e.bash. Nothing here changes anything on the device.
#
# Hotkeys: PPSSPP keeps its hotkey bindings in controls.ini, next to ppsspp.ini, in the
# [ControlMapping] section, under the names PPSSPP writes ("Save State", "Next Slot",
# "Exit App"; keys are matched without regard to case, the first line wins, like PPSSPP's
# IniFile). "Save State = 10-196:10-192" is a chord (":") of two buttons; "," separates
# alternatives; "10" is the pad device and the number is PPSSPP's key code. PPSSPP has NO
# default binding for these hotkeys: a hotkey that is not in the file does not exist, so it
# is a problem to report (or to override with SAVE_KEYS, NEXT_SLOT_KEYS, EXIT_KEYS).
# The key codes of the pad are fixed (SDL game controller -> PPSSPP key codes, the same on
# every device, whatever the user mapped the PSP buttons to), so a code is turned into the
# button of the TRIMUI pad that the test can press through this table only.

# cfg_code_button <code>: the pad button for a PPSSPP key code of device 10 ("10-196").
cfg_code_button() {
    case "$1" in
    10-19) echo up ;;
    10-20) echo down ;;
    10-21) echo left ;;
    10-22) echo right ;;
    10-189) echo b ;;
    10-190) echo a ;;
    10-191) echo y ;;
    10-188) echo x ;;
    10-193) echo l1 ;;
    10-192) echo r1 ;;
    10-196) echo select ;;
    10-197) echo start ;;
    *) return 1 ;;
    esac
}

# cfg_hotkey_lookup <controls.ini> <name>: prints one line:
#   NOFILE | NOSECTION    the file or its [ControlMapping] section is not there
#   UNSET                 the hotkey is not in the section, or has an empty value
#   OK <chord>            e.g. "OK select+r1" (the first alternative that can be pressed)
#   BAD <value>           bound, but to nothing the test can press (keyboard, another pad,
#                         an axis, a button the pad injection does not have, ...)
cfg_hotkey_lookup() {
    local raw alt tok chord ok btn
    [ -f "$1" ] || { echo NOFILE; return 0; }
    raw="$(awk -v want="$2" '
        { sub(/^\357\273\277/, ""); sub(/\r$/, "") }
        /^[ \t]*\[/ { sec = ($0 ~ /^[ \t]*\[ControlMapping\][ \t]*$/); if (sec) seen = 1; next }
        sec && /=/ && !done {
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
            if (tolower(k) == tolower(want)) {
                v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
                print "V" v; done = 1
            }
        }
        END { if (!done) print (seen ? "UNSET" : "NOSECTION") }
    ' "$1")"
    case "$raw" in
    V) echo UNSET; return 0 ;;
    V*) raw="${raw#V}" ;;
    *) echo "$raw"; return 0 ;;
    esac
    while IFS= read -r alt; do
        chord="" ok=1
        for tok in $(printf '%s' "$alt" | tr ':' ' '); do
            btn="$(cfg_code_button "$tok")" || { ok=0; break; }
            chord="$chord${chord:+ +}$btn"
        done
        if [ "$ok" = 1 ] && [ -n "$chord" ]; then
            echo "OK $(printf '%s' "$chord" | tr -d ' ')"
            return 0
        fi
    done < <(printf '%s\n' "$raw" | tr ',' '\n')
    echo "BAD $raw"
}

# cfg_keys_valid <steps>: every step is a button/chord that btn_set knows, sleepN or shot.
# Prints the first bad step.
cfg_keys_valid() {
    local step k
    set -f
    for step in $1; do
        case "$step" in
        shot) continue ;;
        sleep*)
            case "${step#sleep}" in "" | *[!0-9.]*) echo "$step"; set +f; return 1 ;; esac
            continue
            ;;
        esac
        for k in $(printf '%s' "$step" | tr '+' ' '); do
            btn_set "$k" 2>/dev/null || { echo "$step"; set +f; return 1; }
        done
    done
    set +f
    return 0
}

# cfg_init_hotkeys <controls.ini> [needs]: sets SAVE_KEYS, NEXT_SLOT_KEYS and EXIT_KEYS, for
# the consumer that needs the hotkeys named in "needs" (words of: save next exit; default all).
# A value already set in the environment wins (it is validated); EXIT_KEYS="" is kill mode and
# stays. Otherwise the value comes from controls.ini; a hotkey that is not bound there is a
# problem (no default is assumed: PPSSPP has none). HOTKEY_INFO says where each value came
# from; HOTKEY_PROBLEMS (newline separated) lists what stops the test, only for hotkeys in
# "needs". Hotkeys that are not needed are still resolved when they can be (for the log).
cfg_init_hotkeys() {
    local ctl="$1" needs="${2:-save next exit}" r val bad
    HOTKEY_INFO="" HOTKEY_PROBLEMS=""
    cfg_prob() { HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}$*"; }
    cfg_one() { # cfg_one <var> <need word> <label> <ppsspp name> <env set?>
        local var="$1" label="$3" nm="$4" v src need=0
        case " $needs " in *" $2 "*) need=1 ;; esac
        if [ "$5" = 1 ]; then
            eval "v=\${$var}"
            src="set by the environment"
            if [ -z "$v" ] && [ "$var" != EXIT_KEYS ] && [ "$need" = 1 ]; then
                cfg_prob "$var is empty: give a button chord (e.g. select+r1) or unset it to read the $label from controls.ini"
            fi
        else
            r="$(cfg_hotkey_lookup "$ctl" "$nm")"
            v="" src=""
            case "$r" in
            "OK "*) v="${r#OK }" src="from $ctl" ;;
            NOFILE)
                src="$ctl not found"
                [ "$need" = 1 ] && cfg_prob "$ctl not found: start a game once so PPSSPP writes it, or set $var"
                ;;
            NOSECTION)
                src="no [ControlMapping] section in $ctl"
                [ "$need" = 1 ] && cfg_prob "$ctl has no [ControlMapping] section, so $label is not bound: PPSSPP has no default - bind it in PPSSPP's Controls > Hotkeys or set $var"
                ;;
            UNSET)
                src="not bound in $ctl"
                [ "$need" = 1 ] && cfg_prob "$label ($nm) is not bound in controls.ini; PPSSPP has no default - bind it in PPSSPP's Controls > Hotkeys or set $var"
                ;;
            *)
                src="UNUSABLE binding '${r#BAD }'"
                [ "$need" = 1 ] && cfg_prob "$label ($nm) is bound to '${r#BAD }' in controls.ini, which the test cannot press (it needs buttons of the TRIMUI pad: d-pad, A B X Y, L1 R1, select, start): rebind it in PPSSPP's Controls > Hotkeys or set $var"
                ;;
            esac
        fi
        eval "$var=\$v"
        HOTKEY_INFO="$HOTKEY_INFO$label: ${v:-(none)} ($src)
"
    }
    cfg_one SAVE_KEYS save "Save State hotkey" "Save State" "$([ -n "${SAVE_KEYS+x}" ] && echo 1 || echo 0)"
    cfg_one NEXT_SLOT_KEYS next "Next Slot hotkey" "Next Slot" "$([ -n "${NEXT_SLOT_KEYS+x}" ] && echo 1 || echo 0)"
    cfg_one EXIT_KEYS exit "Exit hotkey" "Exit App" "$([ -n "${EXIT_KEYS+x}" ] && echo 1 || echo 0)"
    for r in SAVE_KEYS:save NEXT_SLOT_KEYS:next EXIT_KEYS:exit; do
        eval "val=\${${r%%:*}}"
        case " $needs " in *" ${r##*:} "*) ;; *) continue ;; esac
        [ -n "$val" ] || continue
        if ! bad="$(cfg_keys_valid "$val")"; then
            cfg_prob "${r%%:*}='$val' has a step the test cannot press: '$bad' (buttons: up down left right a b x y l1 r1 select start)"
        fi
    done
    unset -f cfg_one cfg_prob
    return 0
}

# NextUI's start-up screen setting. The tests do not depend on it (every check of the Game
# Switcher goes through open_switcher, the rest looks at processes and files), so this only
# reports key=value lines of minuisettings.txt that look like a start screen setting, for the
# log. Only those keys are printed, never the rest of the file (it holds RetroAchievements
# credentials).
cfg_start_mode_info() { # cfg_start_mode_info <minuisettings.txt>
    local lines
    lines="$(grep -i -E '^[A-Za-z_]*(view|startup|boot|switcher)[A-Za-z_]*=' "$1" 2>/dev/null |
        grep -v -i -E 'token|password|user|auth' | tr -d '\r' | tr '\n' ' ')"
    printf '%s' "${lines:-no start screen setting found in $1 (NextUI default)}"
}

# cfg_ini_general <ppsspp.ini> <key>: the value in [General] (empty if missing).
cfg_ini_general() {
    awk -v key="$2" '
        { sub(/^\357\273\277/, ""); sub(/\r$/, "") }
        /\[[^]]*\][ \t]*$/ { g = ($0 ~ /\[General\][ \t]*$/); next }
        g && $0 ~ ("^" key "[ \t]*=") { v = $0; sub(/^[^=]*=[ \t]*/, "", v); print v; exit }
    ' "$1" 2>/dev/null
}

# e2e_preflight_problems: prints one "FAIL: ..." line per problem with the setup of
# e2e.bats and returns 1 if there is any. Needs SD PAK MON PNGCOLOR PAD ROM ROM_DIR and the
# hotkeys (cfg_init_hotkeys has run, with the controls file in CONTROLS and ppsspp.ini in INI).
e2e_preflight_problems() {
    local bad=0 line
    f_() { echo "FAIL: $*"; bad=1; }
    [ "$(id -u)" = 0 ] || f_ "run as root (needed to write to /dev/input)"
    [ -d "$PAK" ] || f_ "the pak is not installed at $PAK"
    [ -x "$PAK/bin/jpg2bmp" ] || f_ "$PAK/bin/jpg2bmp missing (install a pak built by CI or make build)"
    [ -f "$INI" ] || f_ "$INI missing (start a game once so PPSSPP writes it)"
    [ -f "$MON/bin/screenshot" ] || f_ "Screenshot Monitor pak not found at $MON (install it in Tools/<platform>)"
    [ -x "$PNGCOLOR" ] || f_ "$PNGCOLOR missing (use the bundle from make test-bundle)"
    [ -f /tmp/nextui_exec ] || f_ "NextUI launcher not running (/tmp/nextui_exec missing)"
    [ -c "${PAD:-}" ] || f_ "TRIMUI Player1 input device not found"
    [ -d "${ROM_DIR:-}" ] || f_ "no Roms/*(PSP) folder found (set ROM_DIR)"
    [ -f "${ROM:-}" ] || f_ "no game file found (set ROM)"
    while IFS= read -r line; do
        [ -n "$line" ] && f_ "$line"
    done <<<"${HOTKEY_PROBLEMS:-}"
    return "$bad"
}

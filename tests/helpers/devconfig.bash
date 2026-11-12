# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are read by the files that source this one
# What the on-device tests need to know about the device's configuration, read from the device
# instead of assumed. Used by tests/bats/e2e.bats (on the device) and by the kit of
# tests/bats/reboot.bats (streamed to the device). Needs awk (BusyBox is fine) and, for the
# key checks, btn_set from e2e.bash. Nothing here changes anything on the device.
#
# Hotkeys: PPSSPP keeps its hotkey bindings in controls.ini, next to ppsspp.ini, in the
# [ControlMapping] section: "SaveState = 10-196:10-192" is a chord (":") of two pad
# buttons ("10" is the pad, the number is PPSSPP's key code); "," separates alternatives.
# The same section maps PSP buttons to the same codes ("Select = 10-196", "R = 10-192"), so a
# code is turned back into a button of the TRIMUI pad through that mapping. A hotkey that is
# not in the file is unset: the documented default is used (and said so).

CFG_DEFAULT_SAVE_KEYS="select+r1"
CFG_DEFAULT_NEXT_SLOT_KEYS="select+right"
CFG_DEFAULT_EXIT_KEYS="select+start"

# cfg_hotkey_lookup <controls.ini> <alias>[,<alias>...]: looks the hotkey up (names compared
# without case, spaces, "_" and "-", so "Save State" = "SaveState") and prints one line:
#   UNSET                 the hotkey (or the file) is not there
#   OK <chord>            e.g. "OK select+r1" (the first alternative that can be pressed)
#   BAD <value>           it is bound, but to nothing the test can press (keyboard, an
#                         unmapped code, an axis, ...)
cfg_hotkey_lookup() {
    [ -f "$1" ] || { echo UNSET; return 0; }
    awk -v aliases="$2" '
        function norm(s) { s = tolower(s); gsub(/[ _\-]/, "", s); return s }
        BEGIN {
            n = split(aliases, a, ","); for (i = 1; i <= n; i++) want[norm(a[i])] = 1
            pad["Up"] = "up"; pad["Down"] = "down"; pad["Left"] = "left"; pad["Right"] = "right"
            pad["Circle"] = "a"; pad["Cross"] = "b"; pad["Square"] = "y"; pad["Triangle"] = "x"
            pad["Start"] = "start"; pad["Select"] = "select"; pad["L"] = "l1"; pad["R"] = "r1"
        }
        { sub(/^\357\273\277/, ""); sub(/\r$/, "") }
        /^[ \t]*\[/ { sec = ($0 ~ /^[ \t]*\[ControlMapping\]/); next }
        !sec || $0 !~ /=/ { next }
        {
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            if (k in pad) {
                m = split(v, alt, ",")
                for (i = 1; i <= m; i++) if (alt[i] ~ /^10-[0-9]+$/ && !(alt[i] in code)) code[alt[i]] = pad[k]
            } else if (norm(k) in want) { hot = v; found = 1 }
        }
        END {
            if (!found) { print "UNSET"; exit }
            m = split(hot, alt, ",")
            for (i = 1; i <= m; i++) {
                c = split(alt[i], tok, ":"); chord = ""; ok = (c > 0)
                for (j = 1; j <= c; j++) {
                    if (!(tok[j] in code)) { ok = 0; break }
                    chord = chord (j > 1 ? "+" : "") code[tok[j]]
                }
                if (ok) { print "OK " chord; exit }
            }
            print "BAD " hot
        }' "$1"
}

# cfg_hotkey <controls.ini> <aliases> <default>: prints the chord to press (the default when
# the hotkey is unset). Returns 1 and prints nothing when it is bound to something unpressable.
cfg_hotkey() {
    local r
    r="$(cfg_hotkey_lookup "$1" "$2")"
    case "$r" in
    "OK "*) printf '%s' "${r#OK }" ;;
    UNSET) printf '%s' "$3" ;;
    *) return 1 ;;
    esac
}

# cfg_keys_valid <steps>: every step is a button/chord that btn_set knows, sleepN or shot.
# Prints the first bad step.
cfg_keys_valid() {
    local step k
    for step in $1; do
        case "$step" in
        shot) continue ;;
        sleep*)
            case "${step#sleep}" in "" | *[!0-9.]*) echo "$step"; return 1 ;; esac
            continue
            ;;
        esac
        for k in $(printf '%s' "$step" | tr '+' ' '); do
            btn_set "$k" 2>/dev/null || { echo "$step"; return 1; }
        done
    done
    return 0
}

# cfg_init_hotkeys <controls.ini>: sets SAVE_KEYS, NEXT_SLOT_KEYS and EXIT_KEYS. A value that
# is already set (the environment: SAVE_KEYS, NEXT_SLOT_KEYS, EXIT_KEYS) wins, EXIT_KEYS=""
# meaning "kill PPSSPP instead" in the on-device test, which then keeps it. Otherwise the value
# is read from controls.ini, else the documented default. HOTKEY_INFO says where each came from;
# HOTKEY_PROBLEMS (newline separated) lists what cannot be pressed.
cfg_init_hotkeys() {
    local ctl="$1" r val bad
    HOTKEY_INFO="" HOTKEY_PROBLEMS=""
    cfg_one() { # cfg_one <var> <label> <aliases> <default> <env set?>
        local var="$1" label="$2" val src
        if [ "$5" = 1 ]; then
            eval "val=\${$var}"
            src="set by the environment"
        else
            r="$(cfg_hotkey_lookup "$ctl" "$3")"
            case "$r" in
            "OK "*) val="${r#OK }" src="from controls.ini" ;;
            UNSET) val="$4" src="not set in controls.ini, assuming the default" ;;
            *)
                val="$4" src="UNUSABLE"
                HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}$label is bound to '${r#BAD }' in controls.ini, which the test cannot press: bind it to pad buttons (e.g. $4) or set $var"
                ;;
            esac
        fi
        eval "$var=\$val"
        HOTKEY_INFO="$HOTKEY_INFO$label: $val ($src)
"
    }
    cfg_one SAVE_KEYS "Save State hotkey" "SaveState" "$CFG_DEFAULT_SAVE_KEYS" "$([ -n "${SAVE_KEYS+x}" ] && echo 1 || echo 0)"
    cfg_one NEXT_SLOT_KEYS "Next Slot hotkey" "NextSlot" "$CFG_DEFAULT_NEXT_SLOT_KEYS" "$([ -n "${NEXT_SLOT_KEYS+x}" ] && echo 1 || echo 0)"
    cfg_one EXIT_KEYS "Exit hotkey" "ExitApp,Exit" "$CFG_DEFAULT_EXIT_KEYS" "$([ -n "${EXIT_KEYS+x}" ] && echo 1 || echo 0)"
    for r in SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS; do
        eval "val=\${$r}"
        [ -n "$val" ] || continue
        if ! bad="$(cfg_keys_valid "$val")"; then
            HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}$r='$val' has a step the test cannot press: '$bad' (buttons: up down left right a b x y l1 r1 select start)"
        fi
    done
    unset -f cfg_one
    return 0
}

# NextUI's start-up screen setting. The tests do not depend on it (every check of the Game
# Switcher goes through open_switcher, the rest looks at processes and files), so this only
# reports the lines of minuisettings.txt that look like a start screen setting, for the log.
cfg_start_mode_info() { # cfg_start_mode_info <minuisettings.txt>
    local lines
    lines="$(grep -i -E 'view|startup|start_in|switcher|boot' "$1" 2>/dev/null | tr '\n' ' ')"
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

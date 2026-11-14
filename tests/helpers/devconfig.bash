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

# cfg_button_code <button>: the reverse of cfg_code_button.
cfg_button_code() {
    case "$1" in
    up) echo 10-19 ;;
    down) echo 10-20 ;;
    left) echo 10-21 ;;
    right) echo 10-22 ;;
    b) echo 10-189 ;;
    a) echo 10-190 ;;
    y) echo 10-191 ;;
    x) echo 10-188 ;;
    l1) echo 10-193 ;;
    r1) echo 10-192 ;;
    select) echo 10-196 ;;
    start) echo 10-197 ;;
    *) return 1 ;;
    esac
}

# cfg_chord_codes <chord>: "select+r1" -> "10-196:10-192" (PPSSPP's ini format).
cfg_chord_codes() {
    local out="" b c
    for b in $(printf '%s' "$1" | tr '+' ' '); do
        c="$(cfg_button_code "$b")" || return 1
        out="$out${out:+:}$c"
    done
    printf '%s' "$out"
}

# cfg_chord_owner <controls.ini> <codes>: prints the name of the first [ControlMapping] key
# that has this exact chord (same codes, any order) as one of its alternatives; succeeds if any.
cfg_chord_owner() {
    local want line key alt norm
    [ -f "$1" ] || return 1
    want="$(printf '%s' "$2" | tr ':' '\n' | sort | tr '\n' ':')"
    while IFS='|' read -r key alt; do
        [ -n "$alt" ] || continue
        norm="$(printf '%s' "$alt" | tr ':' '\n' | sort | tr '\n' ':')"
        if [ "$norm" = "$want" ]; then
            printf '%s' "$key"
            return 0
        fi
    done < <(awk '
        { sub(/^\357\273\277/, ""); sub(/\r$/, "") }
        /^[ \t]*\[/ { sec = ($0 ~ /^[ \t]*\[ControlMapping\][ \t]*$/); next }
        sec && /=/ {
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
            n = split(v, alt, ","); for (i = 1; i <= n; i++) print k "|" alt[i]
        }' "$1")
    return 1
}

# cfg_controls_bind <controls.ini> <name> <codes>: sets "<name> = <codes>" in the first
# [ControlMapping] section: replaces an EMPTY value of that key, else adds the line at the end
# of the section. It refuses (status 1) when there is no such section: creating one would make
# PPSSPP drop its built-in mappings. Every other line is kept as
# it is, BOM and CRLF included. Only call it for a hotkey that is not bound.
cfg_controls_bind() {
    local tmp="$1.tmp.$$"
    grep -q '\[ControlMapping\]' "$1" 2>/dev/null || {
        echo "no [ControlMapping] section in $1: not creating one" >&2
        return 1
    }
    awk -v name="$2" -v val="$3" '
        NR == 1 && /\r$/ { cr = "\r" }
        function flush_blank(   i) { for (i = 1; i <= nb; i++) print blank[i]; nb = 0 }
        function add() { print name " = " val cr; done = 1 }
        {
            line = $0; t = line; sub(/^\357\273\277/, "", t); sub(/\r$/, "", t)
        }
        t ~ /^[ \t]*\[/ {
            if (sec && !done) add()
            flush_blank()
            sec = (t ~ /^[ \t]*\[ControlMapping\][ \t]*$/ && !seen)
            if (sec) seen = 1
            print line; next
        }
        sec && t ~ /^[ \t]*$/ { blank[++nb] = line; next }
        sec && t ~ /=/ && !done {
            k = t; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]*/, "", k)
            v = t; sub(/^[^=]*=[ \t]*/, "", v)
            if (tolower(k) == tolower(name) && v ~ /^[ \t]*$/) { flush_blank(); add(); next }
        }
        { flush_blank(); print line }
        END {
            if (sec && !done) add()
            flush_blank()
        }' "$1" >"$tmp" && [ -s "$tmp" ] && cat "$tmp" >"$1"
    local rc=$?
    rm -f "$tmp"
    sync
    return "$rc"
}

# cfg_keys_valid <steps>: every step is a button/chord that btn_set knows, sleepN, saved or shot.
# Prints the first bad step.
cfg_keys_valid() {
    local step k
    set -f
    for step in $1; do
        case "$step" in
        shot | saved) continue ;;
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
# A value already set in the environment wins (it is validated, and controls.ini is left alone
# for that hotkey); EXIT_KEYS="" is kill mode and stays. Otherwise the value comes from
# controls.ini. PPSSPP has no default binding, so a hotkey that is not bound there is
#   - SET_HOTKEYS unset or not 0: put on HOTKEY_TO_BIND with a free chord (select+r1,
#     select+right, select+start, else a fallback that no other action uses); the test binds
#     it temporarily with cfg_apply_hotkeys, after the backup of controls.ini, and the file is
#     restored at the end,
#   - SET_HOTKEYS=0: a problem.
# A binding the user made that the pad cannot press stays a problem and is never touched; a
# missing controls.ini is a problem (the tests do not create it). HOTKEY_INFO says where each
# value came from; HOTKEY_PROBLEMS (newline separated) lists what stops the test, only for
# hotkeys in "needs". Hotkeys that are not needed are resolved when they can be (for the log).
cfg_init_hotkeys() {
    local ctl="$1" needs="${2:-save next exit}" r val bad
    CFG_CTL="$ctl" CFG_NEEDS="$needs"
    HOTKEY_INFO="" HOTKEY_PROBLEMS="" HOTKEY_TO_BIND="" HOTKEY_TAKEN="" HOTKEY_DERIVED=""
    cfg_prob() { HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}$*"; }
    # cfg_free_chord <label of the hotkey> <candidate chords...>: prints the first chord that no
    # other action in controls.ini uses and that no hotkey chosen before uses
    cfg_free_chord() {
        local c codes
        shift
        for c in "$@"; do
            codes="$(cfg_chord_codes "$c")"
            cfg_chord_owner "$ctl" "$codes" >/dev/null && continue
            case " $HOTKEY_TAKEN " in *" $codes "*) continue ;; esac
            printf '%s' "$c"
            return 0
        done
        return 1
    }
    cfg_one() { # cfg_one <var> <need word> <label> <ppsspp name> <env set?> <candidate chords...>
        local var="$1" label="$3" nm="$4" envset="$5" v src need=0 chord codes owner
        case " $needs " in *" $2 "*) need=1 ;; esac
        shift 5
        if [ "$envset" = 1 ]; then
            eval "v=\${$var}"
            src="set by the environment, controls.ini is not touched"
            if [ -z "$v" ] && [ "$var" != EXIT_KEYS ] && [ "$need" = 1 ]; then
                cfg_prob "$var is empty: give a button chord (e.g. select+r1) or unset it to read the $label from controls.ini"
            fi
        else
            HOTKEY_DERIVED="$HOTKEY_DERIVED $var"
            r="$(cfg_hotkey_lookup "$ctl" "$nm")"
            v="" src=""
            case "$r" in
            "OK "*) v="${r#OK }" src="from $ctl" ;;
            NOFILE)
                src="$ctl not found"
                [ "$need" = 1 ] && cfg_prob "$ctl not found (the tests do not create it): start a game once so PPSSPP writes it, or set $var"
                ;;
            NOSECTION)
                # PPSSPP erases every button that is not listed once the section exists, so a
                # section created by the tests would wipe its built-in mappings for the run.
                src="no [ControlMapping] section in $ctl"
                [ "$need" = 1 ] && cfg_prob "no [ControlMapping] in $ctl, so $label is not bound (PPSSPP has no default); the tests do not create the section (PPSSPP would then drop its built-in button mappings): bind the hotkeys in PPSSPP (Controls > Hotkeys) or set $var"
                ;;
            UNSET)
                if [ "$need" = 0 ]; then
                    src="not bound in $ctl"
                elif [ "${SET_HOTKEYS:-1}" = 0 ]; then
                    src="not bound in $ctl"
                    cfg_prob "$label ($nm) is not bound in controls.ini; PPSSPP has no default - bind it in PPSSPP's Controls > Hotkeys, set $var, or remove SET_HOTKEYS=0 so that the tests bind it temporarily"
                elif chord="$(cfg_free_chord "$label" "$@")"; then
                    codes="$(cfg_chord_codes "$chord")"
                    v="$chord" src="NOT BOUND in $ctl: the tests bind it temporarily ($nm = $codes) and restore the file at the end"
                    HOTKEY_TAKEN="$HOTKEY_TAKEN $codes"
                    HOTKEY_TO_BIND="$HOTKEY_TO_BIND$nm|$codes|$var|$chord
"
                    if [ "$chord" != "$1" ]; then
                        owner="$(cfg_chord_owner "$ctl" "$(cfg_chord_codes "$1")")" || owner="another hotkey"
                        src="$src; the usual $1 is taken by '$owner'"
                    fi
                else
                    src="not bound in $ctl"
                    cfg_prob "$label ($nm) is not bound in controls.ini and every chord the tests could use for it ($*) is already used by another action there: bind it yourself in PPSSPP's Controls > Hotkeys or set $var"
                fi
                ;;
            *)
                # shellcheck disable=SC2089 # text for the log, quotes are literal
                src="UNUSABLE binding '${r#BAD }'"
                [ "$need" = 1 ] && cfg_prob "$label ($nm) is bound to '${r#BAD }' in controls.ini, which the test cannot press (it needs buttons of the TRIMUI pad: d-pad, A B X Y, L1 R1, select, start): rebind it in PPSSPP's Controls > Hotkeys or set $var (your binding is never changed by the tests)"
                ;;
            esac
        fi
        eval "$var=\$v"
        HOTKEY_INFO="$HOTKEY_INFO$label: ${v:-(none)} ($src)
"
    }
    cfg_one SAVE_KEYS save "Save State hotkey" "Save State" "$([ -n "${SAVE_KEYS+x}" ] && echo 1 || echo 0)" select+r1 start+r1 select+l1
    cfg_one NEXT_SLOT_KEYS next "Next Slot hotkey" "Next Slot" "$([ -n "${NEXT_SLOT_KEYS+x}" ] && echo 1 || echo 0)" select+right start+right select+left
    cfg_one EXIT_KEYS exit "Exit hotkey" "Exit App" "$([ -n "${EXIT_KEYS+x}" ] && echo 1 || echo 0)" select+start start+l1 l1+r1
    for r in SAVE_KEYS:save NEXT_SLOT_KEYS:next EXIT_KEYS:exit; do
        eval "val=\${${r%%:*}}"
        case " $needs " in *" ${r##*:} "*) ;; *) continue ;; esac
        [ -n "$val" ] || continue
        if ! bad="$(cfg_keys_valid "$val")"; then
            cfg_prob "${r%%:*}='$val' has a step the test cannot press: '$bad' (buttons: up down left right a b x y l1 r1 select start)"
        fi
    done
    unset -f cfg_one cfg_prob cfg_free_chord
    # Exported: bats tests, and the commands they run, only see exported variables, and an
    # unset + assignment (cfg_reinit_hotkeys) would otherwise drop the attribute.
    # shellcheck disable=SC2090 # HOTKEY_INFO is text, quotes in it are literal
    export SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS HOTKEY_INFO
    return 0
}

# Resolves again from the file as it is now (after controls.ini was put back), forgetting the
# values derived by the last cfg_init_hotkeys (settings from the environment are kept).
cfg_reinit_hotkeys() {
    local v
    for v in $HOTKEY_DERIVED; do unset "$v"; done
    cfg_init_hotkeys "$CFG_CTL" "$CFG_NEEDS"
}

# cfg_report_restore <had hotkeys 0|1>: after restore_files, says that controls.ini is restored
# only if it is byte-identical to the backup; else says where the original is.
cfg_report_restore() {
    [ "$1" = 1 ] || return 0
    if cmp -s "$BAK$CFG_CTL" "$CFG_CTL"; then
        echo "controls.ini restored: the hotkeys the tests had bound are removed again"
    else
        echo "WARNING: controls.ini could NOT be restored; the original is in $BAK$CFG_CTL"
    fi
}

# cfg_apply_hotkeys: binds the hotkeys on HOTKEY_TO_BIND in controls.ini. The caller must have
# backed controls.ini up first (psp_backup, which sets the "active" flag of $BAK): this writes
# $BAK/left (the file as the tests left it, so that a later change is noticed) and
# $BAK/controls.bound (what was bound, for the log). Prints what it did.
cfg_apply_hotkeys() {
    local nm codes var chord bound=""
    [ -n "$HOTKEY_TO_BIND" ] || return 0
    # Never write without the byte-exact backup (stash) that restore_files puts back.
    if ! grep -qxF -- "$CFG_CTL" "$BAK/present" 2>/dev/null || ! cmp -s "$BAK$CFG_CTL" "$CFG_CTL"; then
        echo "refusing to change $CFG_CTL: it is not backed up in $BAK (internal error)" >&2
        return 1
    fi
    while IFS='|' read -r nm codes var chord; do
        [ -n "$nm" ] || continue
        cfg_controls_bind "$CFG_CTL" "$nm" "$codes" || { echo "could not write $CFG_CTL" >&2; return 1; }
        if [ "$(cfg_hotkey_lookup "$CFG_CTL" "$nm")" != "OK $chord" ]; then
            echo "$nm was written to $CFG_CTL but does not read back as $chord" >&2
            return 1
        fi
        bound="$bound$nm = $codes ($chord)
"
    done <<<"$HOTKEY_TO_BIND"
    snapshot_left "$CFG_CTL" && printf '%s' "$bound" >"$BAK/controls.bound" || return 1
    sync
    printf 'hotkeys bound by the tests in controls.ini (the original file is restored at the end):\n%s' "$bound"
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

# --- the hotkey setup of e2e.bats ---------------------------------------------------------------
# e2e_setup_hotkeys: needs CONTROLS. The Exit hotkey is always needed (EXIT_KEYS="" kills PPSSPP
# instead); Save State and Next Slot only when PSP_KEYS is not given. Sets and exports PSP_KEYS
# (the default sequence from the hotkeys) and the hotkeys.
e2e_setup_hotkeys() {
    PSP_DEFAULT=0
    [ -z "${PSP_KEYS+x}" ] && PSP_DEFAULT=1
    cfg_init_hotkeys "$CONTROLS" "exit$([ "$PSP_DEFAULT" = 1 ] && echo ' save next')"
    e2e_default_keys
}
# e2e_reinit_hotkeys: the same after the files were put back (resolve again from the file).
e2e_reinit_hotkeys() {
    cfg_reinit_hotkeys
    e2e_default_keys
}
e2e_default_keys() {
    local bad
    if [ "$PSP_DEFAULT" = 1 ]; then
        # "saved" waits for the state file the hotkey wrote (a positive signal; it was a fixed sleep3);
        # sleep1 after Next Slot stays: the slot change only shows on the screen (for the evidence shot)
        PSP_KEYS="$SAVE_KEYS saved shot $NEXT_SLOT_KEYS sleep1 shot $SAVE_KEYS saved shot"
    elif [ -n "$PSP_KEYS" ] && ! bad="$(cfg_keys_valid "$PSP_KEYS")"; then
        HOTKEY_PROBLEMS="$HOTKEY_PROBLEMS${HOTKEY_PROBLEMS:+
}PSP_KEYS has a step the test cannot press: '$bad'"
    fi
    export PSP_KEYS PSP_DEFAULT
}

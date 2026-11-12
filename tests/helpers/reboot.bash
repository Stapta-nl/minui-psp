# shellcheck shell=bash
# shellcheck disable=SC2016 # the scripts in single quotes run on the device
# Host-side helpers for tests/bats/reboot.bats: tests that reboot the device.
#
# Why host-side: a reboot ends the sshd session that `make test-device` runs the on-device
# bats in, and with it bats. So these tests run on the HOST and use ssh for every step; they
# survive the reboot by reconnecting. The device-side half is tests/helpers/reboot-device.bash
# (plus e2e.bash for the evdev button injection): it is streamed to /tmp on the device before
# the first call and again after every boot, because /tmp is cleared by a reboot.
#
# Settings (env): DEVICE_HOST (ssh target) and DEVICE_SSH_OPTS (extra ssh options) are set by
# tests/run-reboot.sh from <PLATFORM>_HOST / <PLATFORM>_SSH_OPTS. The device's address is
# never printed by these helpers (ssh's own error text is scrubbed).
#   SSH_CONNECT_TIMEOUT (5)   per ssh call; polling during a reboot needs it short
#   POLL_INTERVAL (1)         seconds between polls of every wait
#   RB_PROBE_TIMEOUT (10)     limit of one ssh probe inside a wait (a hung ssh must not eat the wait)
#   KEEPAWAKE_INTERVAL (10)   seconds between keep-awake steps during a wait (0 = off)
#   REBOOT_DOWN_TIMEOUT (90)  BACKUP only: after the power-off request the device must be seen going
#                             down (ssh port closed) within this; normally it takes a few seconds
#   REBOOT_UP_TIMEOUT (300)   BACKUP only: ... and be back (port open, ssh answers with a NEW boot id)
#   RESUME_TIMEOUT (180)      BACKUP only: after boot NextUI must be up and relaunch the game within this
#   RB_PORT_PROBE             a command (run with eval) that succeeds when the device's ssh port is open;
#                             replaces the built-in probe (host unit tests, odd networks)
#   RB_TIMINGS_FILE           where the reboot timings are appended (default: $OUT/reboot-timings.txt)
# Every wait polls a condition and ends as soon as it holds; the durations above and in reboot.bats
# are only the time-outs after which a wait gives up.

RB_KIT_PATH="${RB_KIT_PATH:-/tmp/psp-reboot-kit.sh}"
RB_ENV_VARS="SD PLATFORM PAK_NAME ROM_DIR ROM SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS SET_HOTKEYS PSP_RUN_ID UI_WAIT BOOT_WAIT NOGAME_WAIT BOOT_SETTLE UI_SETTLE NOGAME_SETTLE CHORD_HOLD KEEPAWAKE_KEY KEEPAWAKE_INTERVAL POWER_DEV_NAME SLEEP_PROBE RB_TMP RB_OUT RB_REBOOT_CMD RB_HARD_REBOOT_CMD BOOT_ID_FILE"

# Quotes a value for the remote shell.
rb_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds the ssh command line from DEVICE_HOST / DEVICE_SSH_OPTS.
rb_ssh_setup() {
    [ -n "${DEVICE_HOST:-}" ] || return 1
    RB_SSH=(ssh -o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-5}" -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
    local extra=()
    read -r -a extra <<<"${DEVICE_SSH_OPTS:-}"
    RB_SSH+=("${extra[@]}")
}

# Arrays are not exported, so a bats test (its own subshell) does not see what setup_file set
# up: every ssh call makes sure RB_SSH exists.
rb_ssh_ready() { [ "${#RB_SSH[@]}" -gt 0 ] || rb_ssh_setup; }

# Masks the device address in text (stdin to stdout).
rb_scrub() {
    local host="${DEVICE_HOST//[[:space:]]/}" esc
    esc="$(printf '%s' "$host" | sed 's/[][\.*^$|/(){}+?]/\\&/g')"
    if [ -n "$host" ]; then
        sed -e "s|$esc|<device>|g" -e "s|${esc#*@}|<device>|g"
    else
        cat
    fi
}

# dev_run <timeout s> <script>: runs a script (bash) on the device and returns its status:
# 124 on a timeout, 255 when ssh cannot connect. stdout is the script's, stderr is scrubbed.
dev_run() {
    local limit="$1" script="$2" errf rc
    rb_ssh_ready || { echo "DEVICE_HOST is not set" >&2; return 2; }
    errf="$(mktemp "${TMPDIR:-/tmp}/rb-ssh-err.XXXXXX")" || return 2
    timeout -k 3 "$limit" "${RB_SSH[@]}" "$DEVICE_HOST" "bash -c $(rb_q "$script")" </dev/null 2>"$errf"
    rc=$?
    rb_scrub <"$errf" >&2
    rm -f "$errf"
    return "$rc"
}

# The settings forwarded to the device: "export NAME='value'; ..." for every one that is set.
rb_env_prelude() {
    local v out=""
    for v in $RB_ENV_VARS; do
        if [ -n "${!v+x}" ]; then
            out="$out export $v=$(rb_q "${!v}");"
        fi
    done
    printf '%s' "$out"
}

# dev_kit <timeout s> <script>: like dev_run, with the kit loaded, the settings exported and
# rb_init run, so the script can call the rb_* and e2e.bash functions.
dev_kit() {
    local limit="$1" script="$2"
    dev_run "$limit" "$(rb_env_prelude) . $RB_KIT_PATH || exit 97; rb_init || exit 98; $script"
}

# dev_ok <timeout s> <script>: dev_kit with no output, for use in a wait.
dev_ok() { dev_kit "$1" "$2" >/dev/null 2>&1; }

# Streams the device-side functions to the device (needed after every boot).
dev_install_kit() {
    local here="${BASH_SOURCE[0]%/*}" errf rc
    rb_ssh_ready || { echo "DEVICE_HOST is not set" >&2; return 2; }
    errf="$(mktemp "${TMPDIR:-/tmp}/rb-ssh-err.XXXXXX")" || return 2
    cat "$here/e2e.bash" "$here/devconfig.bash" "$here/reboot-device.bash" |
        timeout -k 3 60 "${RB_SSH[@]}" "$DEVICE_HOST" "cat >$(rb_q "$RB_KIT_PATH.part") && mv $(rb_q "$RB_KIT_PATH.part") $(rb_q "$RB_KIT_PATH")" 2>"$errf"
    rc=${PIPESTATUS[1]}
    rb_scrub <"$errf" >&2
    rm -f "$errf"
    return "$rc"
}

# --- waiting, with the device kept awake --------------------------------------------------
# Logs a line: to stderr, to the TAP output (fd 3 under bats) and to the timings file.
rb_log() {
    local f="${RB_TIMINGS_FILE:-${OUT:+$OUT/reboot-timings.txt}}"
    echo "$*" >&2
    { [ -w /dev/fd/3 ] && echo "# $*" >&3; } 2>/dev/null || true
    [ -z "$f" ] || echo "$(date '+%H:%M:%S') $*" >>"$f" 2>/dev/null || true
}

# One keep-awake step if KEEPAWAKE_INTERVAL seconds have passed since the last one. The step
# wakes a device that sleeps, otherwise taps a harmless button (see rb_tick). It never fails
# the test: a device that is rebooting simply does not answer. (The interval is how often input
# is sent to keep NextUI's idle timer from running out, not a wait for anything.)
rb_keepawake_maybe() {
    local every="${KEEPAWAKE_INTERVAL:-10}"
    [ "${RB_TICK:-1}" = 1 ] && [ "$every" -gt 0 ] || return 0
    [ $((SECONDS - ${RB_LAST_TICK:--99999})) -ge "$every" ] || return 0
    RB_LAST_TICK=$SECONDS
    dev_kit "${RB_PROBE_TIMEOUT:-10}" rb_tick >/dev/null 2>&1 || true
}

# await <timeout s> <what> <command...>: runs the command every POLL_INTERVAL seconds (1) until it
# succeeds (0) or the time is up (1, saying what was waited for). The time is only the backup.
# Keeps the device awake.
await() {
    local limit="$1" what="$2" start=$SECONDS
    shift 2
    while :; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        if [ $((SECONDS - start)) -ge "$limit" ]; then
            echo "timed out after ${limit}s waiting for: $what" >&2
            return 1
        fi
        rb_keepawake_maybe
        sleep "${POLL_INTERVAL:-1}"
    done
}

# probe <script>: dev_ok with the short per-probe limit, for use in a wait.
probe() { dev_ok "${RB_PROBE_TIMEOUT:-10}" "$1"; }

# The settle checks run ON the device (a local one second loop: no ssh call per poll), keep the
# device awake there, and give up after the old fixed duration (plus the count). See
# wait_ui_settled / wait_game_settled in e2e.bash.
# The settles run ON the device (a local one second loop: no ssh call per poll; the keep-awake taps
# are sent from there too) with the functions of e2e.bash, which read BOOT_SETTLE / BOOT_WAIT,
# UI_SETTLE / UI_WAIT and NOGAME_SETTLE / NOGAME_WAIT (forwarded with the other settings). The device
# decides the durations (defaults and what they mean: e2e.bash, README); the host only bounds the ssh
# call. An optional argument is a launch reference (rb_launch_ref taken BEFORE the event under test):
# a rewritten pak log (launch.sh ran) then fails the wait at once.
rb_whole() { local w="${1%%.*}"; case "$w" in "" | *[!0-9]*) w=0 ;; esac; echo "$w"; }
rb_settle_call() { # <function> <wait var value> <settle var value> <launch ref>
    local limit=$(($(rb_whole "$2") * 2 + $(rb_whole "$3") + 60)) ref=""
    [ -z "${4:-}" ] || ref="E2E_LAUNCH_REF=$(rb_q "$4"); export E2E_LAUNCH_REF;"
    dev_kit "$limit" "$ref $1"
}
settle_boot() { rb_settle_call game_settle "${BOOT_WAIT:-20}" "${BOOT_SETTLE:-0}"; }
settle_resumed() { rb_settle_call game_settle "${BOOT_WAIT:-20}" "${BOOT_SETTLE:-0}"; }
settle_ui_short() { rb_settle_call ui_settle "${UI_WAIT:-6}" "${UI_SETTLE:-0}" "${1:-}"; }
settle_nogame() { rb_settle_call nogame_settle "${NOGAME_WAIT:-25}" "${NOGAME_SETTLE:-0}" "${1:-}"; }
# rb_launch_ref: the state of the pak log now (see launch_sig in e2e.bash), to be passed to a settle.
rb_launch_ref() { dev_kit 30 'launch_sig "$LOGS/PSP.txt"'; }

# dev_definite <timeout s> <script>: runs the script on the device and returns 0 (it succeeded) or 1
# (it failed normally) ONLY for a definite answer. A timeout (124), an ssh failure (255) or a kit
# that did not load (97/98) is "unknown": it is retried (RB_DEFINITE_TRIES, 20, every POLL_INTERVAL)
# and after that returns 2. For decisions that must not be taken on a guess.
dev_definite() {
    local rc i=0
    while :; do
        dev_kit "$1" "$2" >/dev/null 2>&1
        rc=$?
        case "$rc" in
        0) return 0 ;;
        124 | 255 | 97 | 98 | 2 | 127) ;;
        *) return 1 ;;
        esac
        i=$((i + 1))
        [ "$i" -lt "${RB_DEFINITE_TRIES:-20}" ] || { echo "no definite answer from the device (ssh status $rc) after $i tries: $2" >&2; return 2; }
        sleep "${POLL_INTERVAL:-1}"
    done
}

# --- reboots -------------------------------------------------------------------------------
rb_boot_id() { dev_run "${RB_PROBE_TIMEOUT:-10}" 'cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"' 2>/dev/null; }

# True once the device does not answer or answers with another boot id than $1.
rb_went_down() {
    local now
    now="$(rb_boot_id)" || return 0
    [ "$now" != "$1" ]
}
# True when the device answers and its boot id is not $1.
rb_is_back() {
    local now
    now="$(rb_boot_id)" || return 1
    [ -n "$now" ] && [ "$now" != "$1" ]
}

# How the device is watched on the network. The ssh port is what matters (it is what the tests
# need, and ICMP may be filtered or the host may be behind a jump host), so:
#   tcp   the host and port ssh would use (ssh -G resolves ~/.ssh/config, else DEVICE_HOST and a
#         -p / -o Port= in DEVICE_SSH_OPTS) are connected to with bash's /dev/tcp, 2 s limit;
#   nc    the same with `nc -z -w2` where bash has no /dev/tcp;
#   ping  `ping -c1 -W1`, only where neither exists and the host is a plain address or name;
#   ssh   a ProxyJump/ProxyCommand is in use: the port is not reachable from here, so "is
#         up" means that a (5 s limit) ssh call succeeds.
# Sets RB_NET_VIA, RB_NET_HOST, RB_NET_PORT and RB_NET_DESC (no address in the description).
rb_net_setup() {
    local cfg host="" port="" proxy="" opts=" ${DEVICE_SSH_OPTS:-} "
    rb_ssh_ready || true
    cfg="$("${RB_SSH[@]}" -G "$DEVICE_HOST" 2>/dev/null)" || cfg=""
    host="$(printf '%s\n' "$cfg" | sed -n 's/^hostname //p' | head -n 1)"
    port="$(printf '%s\n' "$cfg" | sed -n 's/^port //p' | head -n 1)"
    proxy="$(printf '%s\n' "$cfg" | sed -n -e 's/^proxyjump //p' -e 's/^proxycommand //p' | grep -v '^none$' | head -n 1)"
    if [ -z "$host" ]; then # no ssh -G: read the target ourselves
        host="${DEVICE_HOST//[[:space:]]/}"
        host="${host#*@}"
        port="$(printf '%s' "$opts" | sed -n -e 's/.* -p *\([0-9][0-9]*\) .*/\1/p' -e 's/.*[Pp]ort=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
        case "$opts" in *[Pp]roxy[Jj]ump*|*[Pp]roxy[Cc]ommand*|*" -J "*) proxy=1 ;; esac
    fi
    RB_NET_HOST="$host"
    RB_NET_PORT="${port:-22}"
    if [ -n "$proxy" ]; then
        RB_NET_VIA=ssh
    elif "${RB_BASH:-bash}" -c 'exec 3<>/dev/tcp/127.0.0.1/9' 2>&1 | grep -qi 'no such file\|not supported'; then
        if command -v nc >/dev/null 2>&1; then RB_NET_VIA=nc; else RB_NET_VIA=ping; fi
    else
        RB_NET_VIA=tcp
    fi
    case "$RB_NET_VIA" in
    ssh) RB_NET_DESC="ssh answering (a jump host is in use, the port is not reachable from here)" ;;
    ping) RB_NET_DESC="ping" ;;
    *) RB_NET_DESC="the ssh port (port $RB_NET_PORT, $RB_NET_VIA)" ;;
    esac
}

# True when the device's ssh port accepts a connection (see rb_net_setup). Every probe has a short limit.
rb_port_open() {
    if [ -n "${RB_PORT_PROBE:-}" ]; then
        eval "$RB_PORT_PROBE"
        return
    fi
    case "${RB_NET_VIA:-}" in
    tcp) timeout -k 1 2 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$RB_NET_HOST" "$RB_NET_PORT" >/dev/null 2>&1 ;;
    nc) timeout -k 1 3 nc -z -w 2 "$RB_NET_HOST" "$RB_NET_PORT" >/dev/null 2>&1 ;;
    ping) ping -c1 -W1 "$RB_NET_HOST" >/dev/null 2>&1 ;;
    ssh) dev_run 5 true >/dev/null 2>&1 ;;
    *) return 1 ;;
    esac
}

# The checks of the two phases (state in globals: a wait runs the check in this shell).
# Down: the port is closed. Every 5th poll the boot id is read as well, for a device that
# rebooted while the port probe did not see it close (a boot id that changed, or ssh that fails).
rb_down_check() {
    RB_DOWN_N=$((RB_DOWN_N + 1))
    rb_port_open || return 0
    [ $((RB_DOWN_N % 5)) -eq 0 ] || return 1
    rb_went_down "$RB_OLD_ID"
}
# Up: ssh answers with a boot id that is not the old one. Normally this is tried once the port probe
# sees the port open (the time is noted; a port seen closed again clears it, so a false "down" does not
# leave a misleading time). A port probe that is WRONG (a tunnel or LocalForward, filtered ICMP in the
# ping fallback) must not make the run fail while ssh works: while the probe says closed, the boot id
# is tried every 3rd poll as well. Either way only a NEW boot id counts; RB_UP_VIA records which
# signal succeeded. A port that is open while ssh does not answer yet, or answers with the OLD id (the
# device did not go down after all, or is still shutting down), is not "back".
rb_up_check() {
    RB_UP_N=$((RB_UP_N + 1))
    if rb_port_open; then
        [ -n "$RB_T_PORT" ] || RB_T_PORT=$SECONDS
        rb_is_back "$RB_OLD_ID" && { RB_UP_VIA="port open, then ssh with a new boot_id"; return 0; }
        return 1
    fi
    RB_T_PORT=""
    [ $((RB_UP_N % 3)) -eq 0 ] || return 1
    rb_is_back "$RB_OLD_ID" && { RB_UP_VIA="ssh with a new boot_id (the port probe never saw the port open: check the probe, RB_PORT_PROBE)"; return 0; }
    return 1
}

# rb_phase_note <what> <seconds> <backup timeout>: a line for the log, with a warning when a phase
# used more than half of its backup time (so that a slow device shows up before it fails).
rb_phase_note() {
    local note=""
    [ $(($2 * 2)) -le "$3" ] || note=" (SLOW: more than half of the ${3}s backup timeout)"
    rb_log "reboot: $1 after ${2}s$note"
}

# await_reboot <old boot id>: after the reboot was triggered, (1) the device must be seen going down
# (the ssh port closes; REBOOT_DOWN_TIMEOUT is the backup), (2) come back (the port opens, then
# ssh answers with a NEW boot id; REBOOT_UP_TIMEOUT is the backup), (3) the kit is installed again
# and (4) the SD card is mounted. All polled every second; the time of each phase is logged
# ("reboot: down after 4s, ..." and a summary line), so that the backups can be tuned.
# No keep-awake steps meanwhile: the device is about to power-cycle.
await_reboot() {
    local old="$1" tick="${RB_TICK:-1}" t0=$SECONDS t_down t_up t_kit t_sd
    RB_TICK=0
    RB_OLD_ID="$old" RB_DOWN_N=0 RB_UP_N=0 RB_T_PORT="" RB_UP_VIA=""
    rb_net_setup
    rb_log "reboot: triggered, watching $RB_NET_DESC"
    await "${REBOOT_DOWN_TIMEOUT:-90}" "the device to go down (reboot)" rb_down_check || { RB_TICK=$tick; rb_log "reboot: the device was not seen going down after $((SECONDS - t0))s"; return 1; }
    t_down=$((SECONDS - t0))
    rb_phase_note "down (ssh port closed)" "$t_down" "${REBOOT_DOWN_TIMEOUT:-90}"
    await "${REBOOT_UP_TIMEOUT:-300}" "the device to come back (ssh port open, ssh answering with a new boot_id)" rb_up_check || { RB_TICK=$tick; rb_log "reboot: the device did not come back within $((SECONDS - t0 - t_down))s of going down (ssh port open: $([ -n "$RB_T_PORT" ] && echo yes || echo no); new boot_id: no)"; return 1; }
    t_up=$((SECONDS - t0 - t_down))
    RB_TICK=$tick
    rb_log "reboot: back via: $RB_UP_VIA"
    rb_phase_note "back (${RB_T_PORT:+port open $((RB_T_PORT - t0 - t_down))s after going down, }ssh with a new boot_id) ${t_up}s after going down; total" "$((SECONDS - t0))" "$((${REBOOT_DOWN_TIMEOUT:-90} + ${REBOOT_UP_TIMEOUT:-300}))"
    await 60 "the kit to be installed after the reboot" dev_install_kit || return 1
    t_kit=$((SECONDS - t0))
    # The SD card is mounted a little after ssh is up: the backup flag lives on it, and the
    # evidence the power-off wrapper recorded too.
    await 120 "the SD card to be mounted after the reboot" probe '[ -f "$BAK/active" ]' || return 1
    t_sd=$((SECONDS - t0))
    rb_log "reboot timing: down after ${t_down}s, up (new boot_id) after ${t_up}s more, kit installed at ${t_kit}s, SD card mounted at ${t_sd}s since the trigger (backups: down ${REBOOT_DOWN_TIMEOUT:-90}s, up ${REBOOT_UP_TIMEOUT:-300}s)"
}

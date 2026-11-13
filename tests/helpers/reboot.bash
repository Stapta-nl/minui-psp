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
#   KEEPAWAKE_INTERVAL (3)    seconds between keep-awake steps during every wait and settle (0 = off).
#                             NextUI suspends the device after about 10 s without input, and a suspended
#                             device does not answer ssh, so the taps must be dense
#   RB_TRIGGER_LINGER (3)     seconds a trigger ssh call may stay open before it is cut (rb_trigger)
#   REBOOT_DOWN_TIMEOUT (30)  BACKUP only: after the power-off request the device must be seen going
#                             down (ssh port closed) within this; observed: about 4 s
#   REBOOT_UP_TIMEOUT (120)   BACKUP only: ... and be back (port open, ssh answers with a NEW boot id);
#                             observed: about 35 s after going down
#   RB_SAME_ID_GRACE (15)     a device that went "down" and then answers ssh with the SAME boot id for this
#                             long did not reboot (it was asleep, or the network dropped): the wait ends
#                             with that verdict instead of running into REBOOT_UP_TIMEOUT
#   RB_SETUP_STEP_TIMEOUT (3) hard limit of every step of the network setup before the trigger (ssh -G,
#                             the /dev/tcp check; the ping baseline has its own 3 s limit)
#   RESUME_TIMEOUT (180)      BACKUP only: after boot NextUI must be up and relaunch the game within this
#   RB_PORT_PROBE             a command (run with eval) that succeeds when the device's ssh port is open;
#                             replaces the built-in probe (host unit tests, odd networks)
#   RB_TIMINGS_FILE           where the reboot timings, the per-poll traces and the per-wait timings are
#                             appended (default: $OUT/reboot-timings.txt)
#   RB_PING_PROBE             a command (eval) that succeeds when the device answers ping (host tests)
# Every wait polls a condition and ends as soon as it holds; the durations above and in reboot.bats
# are only the time-outs after which a wait gives up.

RB_KIT_PATH="${RB_KIT_PATH:-/tmp/psp-reboot-kit.sh}"
RB_ENV_VARS="SD PLATFORM PAK_NAME ROM_DIR ROM SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS SET_HOTKEYS PSP_RUN_ID UI_WAIT BOOT_WAIT NOGAME_WAIT BOOT_SETTLE UI_SETTLE NOGAME_SETTLE CHORD_HOLD KEEPAWAKE_KEY KEEPAWAKE_INTERVAL POWER_DEV_NAME SLEEP_PROBE RB_TMP RB_OUT RB_REBOOT_CMD RB_HARD_REBOOT_CMD BOOT_ID_FILE"

# Quotes a value for the remote shell.
rb_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Builds the ssh command line from DEVICE_HOST / DEVICE_SSH_OPTS.
rb_ssh_setup() {
    [ -n "${DEVICE_HOST:-}" ] || return 1
    # ControlMaster=no / ControlPath=none: a multiplexed master from ~/.ssh/config (ControlPersist) would
    # keep a dead connection alive across the reboot and would stay running holding the stdout of
    # a command substitution (`$(rb_boot_id)` then blocks until the master exits). These options come
    # first, so they win over the config file.
    RB_SSH=(ssh -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ControlPersist=no -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT:-5}" -o "ServerAliveInterval=${RB_ALIVE_INT:-5}" -o "ServerAliveCountMax=${RB_ALIVE_MAX:-3}")
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
    local limit="$1" script="$2" t0 rc
    t0="$(rb_now_ms)"
    dev_run "$limit" "$(rb_env_prelude) . $RB_KIT_PATH || exit 97; rb_init || exit 98; $script"
    rc=$?
    # every ssh call that takes 2 s or more shows up in the per-test breakdown
    rb_phase_since "ssh call: ${script:0:50}" "$t0" "rc $rc" 2000
    return "$rc"
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

# --- clocks, logging and the per-wait timing breakdown ---------------------------------------
# All durations here come from ONE wall clock read with rb_now_ms (bash's EPOCHREALTIME, else `date`).
# RB_CLOCK_FILE (host unit tests): a file holding a fake "now" in ms.
rb_now_ms() {
    local t
    if [ -n "${RB_CLOCK_FILE:-}" ] && [ -r "$RB_CLOCK_FILE" ]; then
        cat "$RB_CLOCK_FILE"
    elif [ -n "${EPOCHREALTIME:-}" ]; then
        t="${EPOCHREALTIME/[.,]/}"
        echo $((t / 1000))
    else
        echo $(($(date +%s) * 1000))
    fi
}
rb_secs() { printf '%s.%s' $(($1 / 1000)) $((($1 % 1000) / 100)); } # ms -> "3.2"

# Logs a line: to stderr, to the TAP output (fd 3 under bats) and to the timings file (with a wall-clock stamp).
rb_log() {
    local f="${RB_TIMINGS_FILE:-${OUT:+$OUT/reboot-timings.txt}}"
    echo "$*" >&2
    { [ -w /dev/fd/3 ] && echo "# $*" >&3; } 2>/dev/null || true
    [ -z "$f" ] || echo "$(date '+%H:%M:%S') $*" >>"$f" 2>/dev/null || true
}
# Only to the timings file (per-poll traces, per-wait lines: too many for the TAP output).
rb_trace() {
    local f="${RB_TIMINGS_FILE:-${OUT:+$OUT/reboot-timings.txt}}"
    [ -z "$f" ] || echo "$(date '+%H:%M:%S')   $*" >>"$f" 2>/dev/null || true
}

# rb_phase <label> <ms> [note]: one wait of the current test: kept for the per-test summary and traced.
rb_phase() {
    [ -z "${RB_PHASE_FILE:-}" ] || echo "$2|$1|${3:-}" >>"$RB_PHASE_FILE" 2>/dev/null || true
    rb_trace "wait: $1 ${3:+($3) }$(rb_secs "$2") s"
}
# rb_phase_since <label> <start ms> <note> [min ms]: the same for a step that began at <start ms>, if it took at least <min ms>.
rb_phase_since() {
    local ms
    ms=$(($(rb_now_ms) - $2))
    [ "$ms" -ge "${4:-0}" ] || return 0
    rb_phase "$1" "$ms" "$3"
}
# rb_timed <label> <command...>: runs the command and records how long it took.
rb_timed() {
    local label="$1" t0 rc=0
    shift
    t0="$(rb_now_ms)"
    "$@" || rc=$?
    rb_phase_since "$label" "$t0" "rc $rc"
    return "$rc"
}
# rb_test_begin / rb_test_end: call from setup / teardown of a bats file: one line per test,
# "<test>: total 35.1 s: start_game 6.2 s, wait_state_saved 3.1 s, ...", in the TAP output and the timings file.
rb_test_begin() {
    RB_TEST_T0="$(rb_now_ms)"
    if [ -n "${OUT:-}" ] && [ -d "$OUT" ]; then
        RB_PHASE_FILE="$OUT/.phases-${BATS_TEST_NUMBER:-0}"
        export RB_PHASE_FILE
        : >"$RB_PHASE_FILE"
    fi
}
rb_test_end() {
    local total ms label note parts=""
    [ -n "${RB_TEST_T0:-}" ] || return 0
    total=$(($(rb_now_ms) - RB_TEST_T0))
    if [ -n "${RB_PHASE_FILE:-}" ] && [ -s "$RB_PHASE_FILE" ]; then
        while IFS='|' read -r ms label note; do
            [ "${ms:-0}" -ge 300 ] || continue
            parts="$parts${parts:+, }$label $(rb_secs "$ms") s${note:+ ($note)}"
        done <"$RB_PHASE_FILE"
        rm -f "$RB_PHASE_FILE"
    fi
    rb_log "timing ${BATS_TEST_DESCRIPTION:0:60}: total $(rb_secs "$total") s${parts:+: $parts}"
}

# --- waiting, with the device kept awake --------------------------------------------------
# One keep-awake step if KEEPAWAKE_INTERVAL seconds (3) have passed since the last one: wakes a device
# that sleeps, otherwise taps a harmless button (see rb_tick). NextUI suspends the device after about
# 10 s without input, and a suspended device does not answer ssh (and cannot be woken from here), so the
# taps are dense. The step runs in the BACKGROUND (never delays a poll, one at a time) and never fails
# the test: a device that is rebooting simply does not answer.
rb_keepawake_maybe() {
    local every="${KEEPAWAKE_INTERVAL:-3}" now
    [ "${RB_TICK:-1}" = 1 ] && [ "$every" -gt 0 ] || return 0
    now=$(($(rb_now_ms) / 1000))
    [ $((now - ${RB_LAST_TICK:--99999})) -ge "$every" ] || return 0
    if [ -n "${RB_TICK_PID:-}" ] && kill -0 "$RB_TICK_PID" 2>/dev/null; then return 0; fi
    RB_LAST_TICK=$now
    ( dev_kit "${RB_PROBE_TIMEOUT:-10}" rb_tick || true ) >/dev/null 2>&1 3>&- </dev/null &
    RB_TICK_PID=$!
}

# await <timeout s> <what> <command...>: runs the command every POLL_INTERVAL seconds (1) until it
# succeeds (0) or the time is up (1, saying what was waited for). The time is only the backup. Every
# wait is recorded (what, signal or TIMEOUT, seconds) for the per-test summary. Keeps the device awake.
await() {
    local limit="$1" what="$2" t0
    shift 2
    t0="$(rb_now_ms)"
    while :; do
        if "$@" >/dev/null 2>&1; then
            rb_phase_since "$what" "$t0" "signal"
            return 0
        fi
        if [ $((($(rb_now_ms) - t0) / 1000)) -ge "$limit" ]; then
            echo "timed out after ${limit}s waiting for: $what" >&2
            rb_phase_since "$what" "$t0" "TIMEOUT"
            return 1
        fi
        rb_keepawake_maybe
        sleep "${POLL_INTERVAL:-1}"
    done
}

# probe <script>: dev_ok with the short per-probe limit, for use in a wait.
probe() { dev_ok "${RB_PROBE_TIMEOUT:-10}" "$1"; }

# rb_device_retry <command...>: runs a call to the device and retries it while the device does not
# answer (ssh failed 255, kit missing 97/98: a device that was asleep or is still coming up), at most
# RB_DEFINITE_TRIES (20) times, one second apart. Any other status is the answer of the device.
rb_device_retry() {
    local rc tries=0
    while :; do
        rc=0
        "$@" || rc=$?
        case "$rc" in 255 | 97 | 98) ;; *) return "$rc" ;; esac
        tries=$((tries + 1))
        if [ "$tries" -ge "${RB_DEFINITE_TRIES:-20}" ]; then return "$rc"; fi
        rb_trace "the device did not answer (status $rc), retrying ($tries)"
        sleep "${POLL_INTERVAL:-1}"
    done
}

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
    rb_timed "settle: $1" rb_device_retry dev_kit "$limit" "$ref $1"
}
settle_boot() { rb_settle_call game_settle "${BOOT_WAIT:-20}" "${BOOT_SETTLE:-0}"; }
settle_resumed() { rb_settle_call ui_game_settle "${UI_WAIT:-6}" "${UI_SETTLE:-0}"; }
settle_ui_short() { rb_settle_call ui_settle "${UI_WAIT:-6}" "${UI_SETTLE:-0}" "${1:-}"; }
settle_nogame() { rb_settle_call nogame_settle "${NOGAME_WAIT:-25}" "${NOGAME_SETTLE:-0}" "${1:-}"; }
# rb_launch_ref: the state of the pak log now (see launch_sig in e2e.bash), to be passed to a settle.
rb_launch_ref() { rb_device_retry dev_kit 30 'launch_sig "$LOGS/PSP.txt"'; }

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

# --- the trigger ------------------------------------------------------------------------------
# rb_kill_tree <pid>: the process and its children (a `timeout` and the ssh below it).
rb_kill_tree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do rb_kill_tree "$c"; done
    kill "$1" 2>/dev/null || true
}
# rb_trigger <device function>: sends the request that makes the device go down (rb_trigger_poweroff or
# rb_hard_reboot, which detach themselves on the device) and RETURNS AT ONCE: the ssh call may stay open
# for at most RB_TRIGGER_LINGER seconds (3), then the client is cut (a connection that dies with the
# reboot is never waited for). No multiplexing (rb_ssh_setup), and short server-alive settings (2 s x 2)
# so that a dead connection is noticed fast. Records when it returned (RB_T_TRIGGER_RET, ms) and how long
# the call took (RB_TRIGGER_MS): the reboot clock of await_reboot starts there. The network setup of
# await_reboot (rb_net_prepare) is done here, BEFORE the request is sent.
rb_trigger() {
    local fn="$1" t0 out pid i=0 steps rc=0 how="returned" saved=()
    rb_ssh_ready || { echo "DEVICE_HOST is not set" >&2; return 2; }
    saved=("${RB_SSH[@]}")
    rb_net_prepare # before the clock starts: await_reboot must not spend the reboot on its setup
    steps=$((${RB_TRIGGER_LINGER:-3} * 5))
    out="$(mktemp "${TMPDIR:-/tmp}/rb-trigger.XXXXXX")" || return 2
    t0="$(rb_now_ms)"
    RB_ALIVE_INT=2 RB_ALIVE_MAX=2 rb_ssh_setup
    ( dev_kit "${RB_TRIGGER_TIMEOUT:-20}" "$fn" >"$out" 2>&1 ) 3>&- </dev/null &
    pid=$!
    RB_SSH=("${saved[@]}")
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$steps" ]; do
        sleep 0.2
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        rb_kill_tree "$pid"
        how="cut after ${RB_TRIGGER_LINGER:-3}s (the request was sent; the connection is not waited for)"
    else
        wait "$pid" || rc=$?
    fi
    RB_T_TRIGGER_RET="$(rb_now_ms)"
    RB_TRIGGER_MS=$((RB_T_TRIGGER_RET - t0))
    rb_phase "trigger $fn" "$RB_TRIGGER_MS" "$how"
    [ "$rc" = 0 ] || cat "$out" >&2
    rm -f "$out"
    return "$rc"
}

# --- reboots -------------------------------------------------------------------------------
# The boot id, read through a FILE: a command substitution around the ssh call would wait for every
# process that holds its pipe (a multiplexing master that ssh forked would keep it for minutes).
rb_boot_id() {
    local f rc=0
    f="$(mktemp "${TMPDIR:-/tmp}/rb-bootid.XXXXXX")" || return 2
    dev_run "${RB_PROBE_TIMEOUT:-10}" 'cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"' >"$f" 2>/dev/null </dev/null || rc=$?
    cat "$f"
    rm -f "$f"
    return "$rc"
}

# True once the device does not answer or answers with another boot id than $1.
rb_went_down() {
    local now
    now="$(rb_boot_id)" || return 0
    [ "$now" != "$1" ]
}
# True when the device answers and its boot id is not $1. RB_SEEN_ID: the id it answered ("" no answer).
rb_is_back() {
    local now
    RB_SEEN_ID=""
    now="$(rb_boot_id)" || return 1
    RB_SEEN_ID="$now"
    [ -n "$now" ] && [ "$now" != "$1" ]
}

# How the device is watched on the network, per poll, with TWO independent signals:
#   ping  `ping -c1 -W1` (when `ping` exists and the host is not behind a jump host; checked once
#         at the start: if it does not answer then, it is not used at all, e.g. filtered ICMP, or a
#         ping whose -W takes milliseconds);
#   port  the ssh port (the host and port ssh would use: ssh -G resolves ~/.ssh/config, else
#         DEVICE_HOST and a -p / -o Port= in DEVICE_SSH_OPTS): bash's /dev/tcp, 2 s limit; `nc -z -w2`
#         where bash has none; with a ProxyJump/ProxyCommand the port is not reachable from here and the
#         probe is a short ssh call.
# DOWN: ping fails, or the port does not accept a connection (or, every 3rd poll, ssh/boot id says so).
# UP: ping answers (if it is used) AND the port accepts AND ssh answers with a NEW boot id; a wrong probe
# (a tunnel that always accepts, a firewall that drops ping) cannot hold a run: while ping/port look
# wrong, ssh is tried every 3rd poll and a new boot id alone is accepted (and logged as such).
# Sets RB_NET_VIA, RB_NET_HOST, RB_NET_PORT and RB_NET_DESC (no address in the description), and
# RB_NET_SETUP_NOTE: how long each step took. Every step has a hard limit (RB_SETUP_STEP_TIMEOUT, 3 s):
# a setup that stalls must not delay the first poll after a reboot (it once took 135 s, see below).
rb_net_setup() {
    local cfg="" host="" port="" proxy="" opts=" ${DEVICE_SSH_OPTS:-} " lim="${RB_SETUP_STEP_TIMEOUT:-3}" f t0 t1 t2 tcp_out
    rb_ssh_ready || true
    t0="$(rb_now_ms)"
    # through a file, like rb_boot_id: a child of ssh (a `Match exec` of ~/.ssh/config) that keeps stdout open
    # must not hold a command substitution beyond the limit
    if f="$(mktemp "${TMPDIR:-/tmp}/rb-sshG.XXXXXX")"; then
        timeout -k 1 "$lim" "${RB_SSH[@]}" -G "$DEVICE_HOST" >"$f" 2>/dev/null </dev/null && cfg="$(cat "$f")"
        rm -f "$f"
    fi
    t1="$(rb_now_ms)"
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
    # Does this bash have /dev/tcp? Asked WITHOUT a connection: a service name that does not exist fails in
    # the lookup in a bash that has it ("Servname not supported", "Invalid argument"), while a bash built
    # without it opens a file of that name ("No such file or directory"). The earlier check connected to
    # 127.0.0.1:9; on a host where a SYN to a closed local port is dropped instead of refused (seen on
    # WSL2), that connect hung for the kernel's whole SYN retry time, about 130 s, right after the trigger.
    # A check that runs into the limit counts as "has /dev/tcp" (the probes have their own 2 s limit).
    tcp_out="$(LC_ALL=C timeout -k 1 "$lim" "${RB_BASH:-bash}" -c 'exec 3<>/dev/tcp/127.0.0.1/rb-no-such-service' 2>&1 </dev/null)" || true
    t2="$(rb_now_ms)"
    if [ -n "$proxy" ]; then
        RB_NET_VIA=ssh
    elif printf '%s' "$tcp_out" | grep -qi 'no such file'; then
        if command -v nc >/dev/null 2>&1; then RB_NET_VIA=nc; else RB_NET_VIA=ping; fi
    else
        RB_NET_VIA=tcp
    fi
    case "$RB_NET_VIA" in
    ssh) RB_NET_DESC="ssh answering (a jump host is in use, the port is not reachable from here)" ;;
    ping) RB_NET_DESC="ping" ;;
    *) RB_NET_DESC="ping and the ssh port (port $RB_NET_PORT, $RB_NET_VIA)" ;;
    esac
    RB_NET_SETUP_NOTE="ssh -G $((t1 - t0))ms, /dev/tcp check $((t2 - t1))ms"
}

# rb_net_prepare: the network setup and the ping baseline, done ONCE and BEFORE the trigger (rb_trigger
# calls it, outside the reboot clock: the device is still up, so ping can answer), so that await_reboot
# polls the moment the trigger call returned. Sets RB_PING_USABLE, RB_NET_READY=1 and adds the time of the
# ping baseline to RB_NET_SETUP_NOTE (each step's time is in the log, so a stall can be attributed).
rb_net_prepare() {
    local t0
    rb_net_setup
    t0="$(rb_now_ms)"
    RB_PING_USABLE=0
    if rb_ping_probe; then RB_PING_USABLE=1; fi
    RB_NET_SETUP_NOTE="$RB_NET_SETUP_NOTE, ping baseline $([ "$RB_PING_USABLE" = 1 ] && echo ok || echo 'not used') $(($(rb_now_ms) - t0))ms"
    RB_NET_READY=1
}

# rb_ping_probe: 0 the device answers ping, 1 it does not, 2 not available here (no ping, jump host).
rb_ping_probe() {
    if [ -n "${RB_PING_PROBE:-}" ]; then
        eval "$RB_PING_PROBE"
        return
    fi
    [ "${RB_NET_VIA:-}" = ssh ] && return 2
    command -v ping >/dev/null 2>&1 || return 2
    timeout -k 1 3 ping -c1 -W1 "$RB_NET_HOST" >/dev/null 2>&1
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
    ping) rb_ping_probe ;;
    ssh) dev_run 5 true >/dev/null 2>&1 ;;
    *) return 1 ;;
    esac
}

# rb_net_poll <phase>: one poll of both signals, traced in the timings file: sets RB_PING (ok, fail, n/a)
# and RB_TCP (ok, fail).
rb_net_poll() {
    local t0 rc=0
    t0="$(rb_now_ms)"
    RB_PING="n/a"
    if [ "${RB_PING_USABLE:-0}" = 1 ]; then
        rb_ping_probe && RB_PING=ok || RB_PING=fail
    fi
    rb_port_open && RB_TCP=ok || RB_TCP=fail
    rb_trace "$1 poll $2: t=$(rb_secs $(($(rb_now_ms) - RB_T0))) s  ping=$RB_PING  tcp=$RB_TCP  (probes took $(($(rb_now_ms) - t0)) ms)"
    return "$rc"
}

# The checks of the two phases (state in globals: a wait runs the check in this shell).
# Down: ping fails or the port does not accept. On the 1st and every 3rd poll ssh is asked too (a
# device that rebooted before the first probe, or while the probes did not see it: a boot id that
# changed, or ssh that fails).
rb_down_check() {
    RB_DOWN_N=$((RB_DOWN_N + 1))
    rb_net_poll down "$RB_DOWN_N"
    if [ "$RB_PING" = fail ]; then RB_DOWN_VIA="ping failed"; return 0; fi
    if [ "$RB_TCP" = fail ]; then RB_DOWN_VIA="the ssh port closed"; return 0; fi
    [ $((RB_DOWN_N % 3)) -eq 1 ] || return 1
    if rb_went_down "$RB_OLD_ID"; then RB_DOWN_VIA="ssh: no answer or a new boot id (already rebooted when the polls started?)"; return 0; fi
    return 1
}
# Up: see rb_net_setup. RB_T_PORT notes when the port was first seen open since it was last closed (a
# port seen closed again clears it, so a false "down" leaves no misleading time); RB_UP_VIA records
# which signal succeeded. Sleep is not a reboot: a suspended device (or a network blip) looks "down" too,
# and comes back with the SAME boot id. When ssh keeps answering with the old id for RB_SAME_ID_GRACE
# seconds (15) the check ends the wait with RB_NOT_REBOOTED=1 (await_reboot fails with that verdict). The
# grace covers a false "down" right before a real reboot (the device goes down about 4 s after the trigger).
rb_up_check() {
    RB_UP_N=$((RB_UP_N + 1))
    rb_net_poll up "$RB_UP_N"
    if [ "$RB_PING" != fail ] && [ "$RB_TCP" = ok ]; then
        [ -n "$RB_T_PORT" ] || RB_T_PORT=$(($(rb_now_ms) - RB_T0))
        rb_is_back "$RB_OLD_ID" && { RB_UP_VIA="ping + port open, then ssh with a new boot_id"; return 0; }
        rb_same_id_check
        return
    fi
    RB_T_PORT=""
    [ $((RB_UP_N % 3)) -eq 0 ] || return 1
    rb_is_back "$RB_OLD_ID" && { RB_UP_VIA="ssh with a new boot_id ONLY (ping=$RB_PING, port=$RB_TCP: those probes look wrong for this setup; check RB_PORT_PROBE)"; return 0; }
    rb_same_id_check
}
# rb_same_id_check: after an rb_is_back that failed: 0 (and RB_NOT_REBOOTED=1) once the device has answered
# with the OLD boot id for RB_SAME_ID_GRACE seconds in a row, else 1. RB_T_SAME: since when (ms after the trigger).
rb_same_id_check() {
    if [ -z "$RB_SEEN_ID" ] || [ "$RB_SEEN_ID" != "$RB_OLD_ID" ]; then
        RB_T_SAME=""
        return 1
    fi
    [ -n "$RB_T_SAME" ] || RB_T_SAME=$(($(rb_now_ms) - RB_T0))
    rb_trace "up poll $RB_UP_N: ssh answers with the SAME boot id (since $(rb_secs "$RB_T_SAME") s)"
    [ $(($(rb_now_ms) - RB_T0 - RB_T_SAME)) -ge $((${RB_SAME_ID_GRACE:-15} * 1000)) ] || return 1
    RB_NOT_REBOOTED=1
    return 0
}

# rb_phase_note <what> <seconds> <backup timeout>: a line for the log, with a warning when a phase
# used more than half of its backup time (so that a slow device shows up before it fails).
rb_phase_note() {
    local note=""
    [ $(($2 * 2)) -le "$3" ] || note=" (SLOW: more than half of the ${3}s backup timeout)"
    rb_log "reboot: $1 after ${2}s$note"
}

# rb_boot_snapshot <label>: rb_boot_report of the device (uptime, boot id, the auto-resume marker, the pak
# log, the processes of NextUI, launch.sh and PPSSPP with their start time after the boot), traced in the
# timings file and kept in RB_BOOT_REPORT (a failing test writes it to its evidence). Never fails.
rb_boot_snapshot() {
    local out line
    out="$(dev_kit "${RB_PROBE_TIMEOUT:-10}" rb_boot_report 2>&1)" || out="${out:+$out
}(no complete answer from the device)"
    RB_BOOT_REPORT="${RB_BOOT_REPORT:-}=== $1 ($(rb_secs $(($(rb_now_ms) - RB_T0))) s after the trigger)
$out
"
    rb_trace "boot report: $1"
    while IFS= read -r line; do rb_trace "  $line"; done <<<"$out"
    return 0
}

# await_reboot <old boot id>: after the reboot was triggered (rb_trigger), (1) the device must be seen going
# down (ping or the ssh port; REBOOT_DOWN_TIMEOUT, 30 s, is the backup), (2) come back (ping and port, then
# ssh answering with a NEW boot id; REBOOT_UP_TIMEOUT, 120 s, is the backup; the SAME boot id for
# RB_SAME_ID_GRACE seconds ends the wait: the device was asleep or unreachable, it did not reboot), (3) the
# kit is installed again and (4) the SD card is mounted. All polled every second. EVERY time is counted from
# the moment the trigger call RETURNED (rb_trigger records it; without rb_trigger: from the start of this
# function), and the log says how long the trigger call took, how long each step of the network setup took
# (done by rb_trigger before the request; here only without it) and when the first poll was. Keep-awake is off
# while the device power-cycles and starts again the moment it answers (before the kit install and the SD
# card wait). A boot report (rb_boot_snapshot) is taken at the first contact after the boot and again once
# the SD card is mounted.
await_reboot() {
    local old="$1" tick="${RB_TICK:-1}" t_entry t_first sec0 t_down t_up t_kit t_sd secs_el ms_el d where
    local down_to="${REBOOT_DOWN_TIMEOUT:-30}" up_to="${REBOOT_UP_TIMEOUT:-120}"
    t_entry="$(rb_now_ms)"
    RB_TICK=0
    RB_OLD_ID="$old" RB_DOWN_N=0 RB_UP_N=0 RB_T_PORT="" RB_UP_VIA="" RB_DOWN_VIA="" RB_T_SAME="" RB_SEEN_ID="" RB_NOT_REBOOTED=""
    RB_BOOT_REPORT=""
    RB_T0="${RB_T_TRIGGER_RET:-$t_entry}"
    sec0=$SECONDS
    where="before the trigger"
    if [ "${RB_NET_READY:-}" != 1 ]; then
        rb_net_prepare
        where="HERE, after the trigger (no rb_trigger before this wait): $(($(rb_now_ms) - t_entry))ms"
    fi
    t_first="$(rb_now_ms)"
    rb_log "reboot: trigger call took $((${RB_TRIGGER_MS:--1}))ms; $((t_entry - RB_T0))ms from its return to this wait; network setup $where ($RB_NET_SETUP_NOTE); first poll at $(rb_secs $((t_first - RB_T0))) s; watching $RB_NET_DESC"
    RB_T_TRIGGER_RET="" RB_NET_READY=""
    await "$down_to" "the device to go down (reboot)" rb_down_check || { RB_TICK=$tick; rb_log "reboot: the device was not seen going down after $((($(rb_now_ms) - RB_T0) / 1000))s"; return 1; }
    t_down=$((($(rb_now_ms) - RB_T0 + 500) / 1000))
    rb_log "reboot: down ($RB_DOWN_VIA)"
    rb_phase_note "down" "$t_down" "$down_to"
    await "$up_to" "the device to come back (ping and ssh port open, ssh answering with a new boot_id)" rb_up_check || {
        RB_TICK=$tick
        rb_log "reboot: the device did not come back within $((($(rb_now_ms) - RB_T0) / 1000 - t_down))s of going down (last poll: ping=$RB_PING port=$RB_TCP; new boot_id: no${RB_T_SAME:+; it answers with the SAME boot id since $(rb_secs "$RB_T_SAME") s: asleep or unreachable for a while, not rebooted})"
        return 1
    }
    if [ -n "$RB_NOT_REBOOTED" ]; then
        RB_TICK=$tick
        rb_log "reboot: NOT rebooted: the device was unreachable (\"down\" at ${t_down}s: $RB_DOWN_VIA) and has answered with the SAME boot id since $(rb_secs "$RB_T_SAME") s after the trigger (${RB_SAME_ID_GRACE:-15}s in a row): it was asleep (idle suspend) or the network dropped; the reboot did not happen"
        return 1
    fi
    ms_el=$(($(rb_now_ms) - RB_T0))
    t_up=$(((ms_el + 500) / 1000 - t_down))
    # keep-awake from here on: the idle suspend of NextUI is about 10 s and a suspended device does not answer
    RB_TICK=$tick
    RB_LAST_TICK=""
    rb_log "reboot: back via: $RB_UP_VIA"
    rb_phase_note "back (${RB_T_PORT:+port open $(((RB_T_PORT + 500) / 1000))s after the trigger, }ssh with a new boot_id) ${t_up}s after going down; total" "$(((ms_el + 500) / 1000))" "$((down_to + up_to))"
    await 60 "the kit to be installed after the reboot" dev_install_kit || return 1
    t_kit=$((($(rb_now_ms) - RB_T0 + 500) / 1000))
    dev_kit "${RB_PROBE_TIMEOUT:-10}" rb_tick >/dev/null 2>&1 || true # the first tap at once
    RB_LAST_TICK=$(($(rb_now_ms) / 1000))
    rb_boot_snapshot "first contact after the boot (kit installed)"
    # The SD card is mounted a little after ssh is up: the backup flag lives on it, and the
    # evidence the power-off wrapper recorded too.
    await 120 "the SD card to be mounted after the reboot" probe '[ -f "$BAK/active" ]' || return 1
    t_sd=$((($(rb_now_ms) - RB_T0 + 500) / 1000))
    rb_boot_snapshot "the SD card is mounted"
    rb_log "reboot timing (from the trigger call's return): down after ${t_down}s, up (new boot_id) after ${t_up}s more, kit installed at ${t_kit}s, SD card mounted at ${t_sd}s (backups: down ${down_to}s, up ${up_to}s)"
    # a cross-check of the clocks: bash's SECONDS and the wall clock must agree (a difference would make every
    # elapsed time above untrustworthy, and is the thing to look at in the next report)
    secs_el=$((SECONDS - sec0))
    d=$((secs_el - ($(rb_now_ms) - t_entry) / 1000))
    if [ -z "${RB_CLOCK_FILE:-}" ] && [ "${d#-}" -gt 5 ]; then
        rb_log "reboot: clock check FAILED: SECONDS advanced ${secs_el}s during this wait, the wall clock $((($(rb_now_ms) - t_entry) / 1000))s"
    fi
}

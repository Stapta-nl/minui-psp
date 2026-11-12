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
#   POLL_INTERVAL (3)         seconds between polls of every wait
#   KEEPAWAKE_INTERVAL (10)   seconds between keep-awake steps during a wait (0 = off)
#   REBOOT_DOWN_TIMEOUT (90)  after the power-off request: the device must go down within this
#   REBOOT_UP_TIMEOUT (300)   ... and be back (ssh, new boot id) within this
#   RESUME_TIMEOUT (180)      after boot: NextUI must be up and relaunch the game within this

RB_KIT_PATH="${RB_KIT_PATH:-/tmp/psp-reboot-kit.sh}"
RB_ENV_VARS="SD PLATFORM PAK_NAME ROM_DIR ROM SAVE_KEYS NEXT_SLOT_KEYS EXIT_KEYS SET_HOTKEYS PSP_RUN_ID UI_WAIT CHORD_HOLD KEEPAWAKE_KEY POWER_DEV_NAME SLEEP_PROBE RB_TMP RB_OUT RB_REBOOT_CMD RB_HARD_REBOOT_CMD BOOT_ID_FILE"

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
# One keep-awake step if KEEPAWAKE_INTERVAL seconds have passed since the last one. The step
# wakes a device that sleeps, otherwise taps a harmless button (see rb_tick). It never fails
# the test: a device that is rebooting simply does not answer.
rb_keepawake_maybe() {
    local every="${KEEPAWAKE_INTERVAL:-10}"
    [ "${RB_TICK:-1}" = 1 ] && [ "$every" -gt 0 ] || return 0
    [ $((SECONDS - ${RB_LAST_TICK:--99999})) -ge "$every" ] || return 0
    RB_LAST_TICK=$SECONDS
    dev_kit 20 rb_tick >/dev/null 2>&1 || true
}

# await <timeout s> <what> <command...>: runs the command every POLL_INTERVAL seconds until it
# succeeds (0) or the time is up (1, saying what was waited for). Keeps the device awake.
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
        sleep "${POLL_INTERVAL:-3}"
    done
}

# pause <seconds>: a wait that cannot end early, in polling steps, keeping the device awake.
pause() {
    local until=$((SECONDS + $1))
    while [ "$SECONDS" -lt "$until" ]; do
        rb_keepawake_maybe
        sleep "${POLL_INTERVAL:-3}"
    done
}

# --- reboots -------------------------------------------------------------------------------
rb_boot_id() { dev_run 20 'cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"' 2>/dev/null; }

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

# await_reboot <old boot id>: the device must go down (REBOOT_DOWN_TIMEOUT) and come back
# (REBOOT_UP_TIMEOUT: ssh works and the boot id is new), then the kit is installed again.
# No keep-awake steps meanwhile: the device is about to power-cycle.
await_reboot() {
    local old="$1" tick="${RB_TICK:-1}"
    RB_TICK=0
    await "${REBOOT_DOWN_TIMEOUT:-90}" "the device to go down (reboot)" rb_went_down "$old" || { RB_TICK=$tick; return 1; }
    await "${REBOOT_UP_TIMEOUT:-300}" "the device to come back (ssh and a new boot id)" rb_is_back "$old" || { RB_TICK=$tick; return 1; }
    RB_TICK=$tick
    await 60 "the kit to be installed after the reboot" dev_install_kit || return 1
    # The SD card is mounted a little after ssh is up: the backup flag lives on it, and the
    # evidence the power-off wrapper recorded too.
    await 120 "the SD card to be mounted after the reboot" dev_ok 20 '[ -f "$BAK/active" ]'
}

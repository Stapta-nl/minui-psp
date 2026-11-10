#!/usr/bin/env bats
# bats file_tags=host,device
#
# Game Switcher preview logic of launch.sh (ported from the old tests/device/run.sh).
#
# It runs the *real* launch.sh and the *real* bin/jpg2bmp inside a throw-away SD card
# tree, with a stub standing in for PPSSPP and minui-power-control. So it checks what
# matters on the device (BusyBox tools, the aarch64 converter, the NextUI file layout,
# SIGTERM handling) without needing a screen or button presses. Nothing under the real SD
# card is touched; the sandbox is deleted afterwards.
#
# The tests run in order and share the sandbox: later cases build on earlier ones
# (e.g. "launch without saving keeps the previous preview").
#
# Env overrides:
#   SRC_PAK    pak to test (default: the repository checkout; on a device the installed pak)
#   JPG2BMP    jpg2bmp binary to use instead of $SRC_PAK/bin/jpg2bmp (host runs)
#   PLATFORM   platform under test (default: the first one in pak.json)
#   OUT_DIR    where logs are kept (default /tmp/psp-test-out; this file uses OUT_DIR/preview)
#   KEEP=1     keep the sandbox

load '../helpers/common'

setup_file() {
    require_tools mktemp cp mv rm mkdir cmp grep head tr find sed cat sleep touch basename sync wc

    PLATFORM="$(psp_platform)"
    SRC_PAK="$(psp_src_pak)"
    OUT="$OUT_DIR/preview"
    rm -rf "$OUT"
    mkdir -p "$OUT"
    T="$(mktemp -d /tmp/psp-preview-test.XXXXXX)" || fail "cannot create a temp dir"

    SD="$T/sd"
    PAK="$SD/Emus/$PLATFORM/$(psp_pak_name).pak"
    USERDATA="$SD/.userdata/$PLATFORM"
    SHARED="$SD/.userdata/shared"
    LOGS="$USERDATA/logs"
    ROMS="$SD/Roms"
    ROMDIR="$ROMS/PlayStation Portable (PSP)"
    MINUI="$SHARED/.minui/PSP"
    STATES="$SHARED/PSP-ppsspp"
    STUB="$T/stub"
    INI="$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini"

    mkdir -p "$PAK/bin" "$PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM" "$LOGS" "$ROMDIR" "$MINUI" "$STATES" "$STUB"
    cp "$SRC_PAK/launch.sh" "$SRC_PAK/pak.json" "$PAK/"
    cp -R "$SRC_PAK/scripts" "$PAK/"
    cp "$SRC_PAK/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" "$INI"
    install_jpg2bmp "${JPG2BMP:-$SRC_PAK/bin/jpg2bmp}" "$PAK/bin/jpg2bmp" ||
        fail "no jpg2bmp found (build it with make bin/jpg2bmp, or set JPG2BMP)"

    # Stubs for hardware helpers so nothing touches the screen or the real power control.
    printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/minui-power-control"
    printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/setalpha"
    printf '#!/bin/sh\nexit 0\n' >"$PAK/bin/show_message"

    # Fake PPSSPP: records its args, then runs $STUB/actions:
    #   save <fixture> <prefix> <slot>   write <prefix>_<slot>.jpg (+ .ppst) into the state dir
    #   sleep <n>                         wait n seconds (lets mtimes differ)
    #   hang                              wait until killed (like a running emulator)
    cat >"$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$STUB/args"
echo $$ >"$STUB/pid"
sleep 2 # like a real boot: saves must be newer than launch.sh's marker (FAT has 2 s mtime)
while read -r action a b c; do
    case "$action" in
    save)
        cp "$FIX/$a.jpg" "$STATES/${b}_${c}.jpg"
        printf 'state' >"$STATES/${b}_${c}.ppst"
        touch "$STUB/saved"
        ;;
    sleep) sleep "$a" ;;
    hang) exec sleep 300 ;;
    esac
done <"$STUB/actions"
EOF
    chmod +x "$PAK/PPSSPP/PPSSPPSDL_$PLATFORM" "$PAK/bin/"*

    printf 'b' >"$ROMDIR/Game B.iso"
    printf 'c' >"$ROMDIR/Game C.iso"

    mkdir -p "$USERDATA/PSP-ppsspp"
    touch "$USERDATA/PSP-ppsspp/debug" # trace logging, as with the debug flag on a device

    export PLATFORM OUT T SD PAK USERDATA SHARED LOGS ROMS ROMDIR MINUI STATES STUB INI FIX
    export DEVICE=brick SDCARD_PATH="$SD" USERDATA_PATH="$USERDATA" LOGS_PATH="$LOGS" \
        SHARED_USERDATA_PATH="$SHARED" ROMS_PATH="$ROMS"
}

teardown_file() {
    # Kept for the debug bundle: what the games left in the NextUI preview dir.
    if [ -n "${OUT:-}" ] && [ -d "${MINUI:-}" ]; then
        cp -R "$MINUI" "$OUT/minui-PSP" 2>/dev/null
        ls -l "$STATES" >"$OUT/states-listing.txt" 2>/dev/null
    fi
    if [ -n "${KEEP:-}" ]; then
        echo "# sandbox kept in $T" >&3
    else
        [ -z "${T:-}" ] || rm -rf "$T"
    fi
}

# install_jpg2bmp <source> <destination>: copies the converter into the sandbox. It is an
# aarch64 binary: on another CPU it is run through qemu-user when that is available and
# the kernel has no binfmt handler for it.
install_jpg2bmp() {
    local src="$1" dst="$2" rc qemu
    [ -f "$src" ] || return 1
    cp "$src" "$dst" && chmod +x "$dst" || return 1
    "$dst" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
        qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64)" || return 0
        mv "$dst" "$dst.aarch64"
        printf '#!/bin/sh\nexec "%s" "%s.aarch64" "$@"\n' "$qemu" "$dst" >"$dst"
        chmod +x "$dst"
    fi
    return 0
}

conv() { "$PAK/bin/jpg2bmp" "$FIX/$1.jpg" "$T/expected-$1.bmp" && echo "$T/expected-$1.bmp"; }
preview() { echo "$MINUI/$1.$2.bmp"; }
case_log() { echo "$OUT/$BATS_TEST_NUMBER.log"; }

# run_game <rom file> [action lines...]: runs launch.sh to completion and saves its log.
run_game() {
    local rom="$1"
    shift
    rm -f "$STUB/args" "$STUB/pid" "$STUB/saved"
    printf '%s\n' "$@" >"$STUB/actions"
    sh "$PAK/launch.sh" "$ROMDIR/$rom" >"$T/launch.out" 2>&1
    cp "$LOGS/PSP.txt" "$(case_log)" 2>/dev/null
}

# Previews of a game (any slot).
previews_of() { find "$MINUI" -name "$1.*.bmp"; }

@test "1 no save state -> no preview, no slot file (NextUI shows No Preview)" {
    run_game "Game B.iso" "sleep 0"
    assert_file_not_exist "$MINUI/Game B.iso.txt"
    run previews_of "Game B.iso"
    assert_output ""
}

@test "2 save state -> preview and slot file" {
    run_game "Game C.iso" "save thumb1 ULUS10041_1.00 0"
    assert_grep "$MINUI/Game C.iso.txt" '^0$'
    assert_same "$(preview "Game C.iso" 0)" "$(conv thumb1)"
    # a real BMP
    [ "$(head -c 2 "$(preview "Game C.iso" 0)")" = BM ]
    assert_grep "$(case_log)" 'Game switcher preview from save state'
}

@test "3 two saves in different slots -> newest slot wins" {
    run_game "Game C.iso" "save thumb1 ULUS10041_1.00 1" "sleep 2" "save thumb2 ULUS10041_1.00 5"
    assert_grep "$MINUI/Game C.iso.txt" '^5$'
    assert_same "$(preview "Game C.iso" 5)" "$(conv thumb2)"
}

@test "4 other game without saving gets no preview" {
    run_game "Game B.iso" "sleep 0"
    assert_file_not_exist "$MINUI/Game B.iso.txt"
    run previews_of "Game B.iso"
    assert_output ""
}

@test "5 launch without saving keeps the previous preview" {
    run_game "Game C.iso" "sleep 0"
    assert_grep "$MINUI/Game C.iso.txt" '^5$'
    assert_same "$(preview "Game C.iso" 5)" "$(conv thumb2)"
}

@test "6 resume hand-off file is removed and no state is forced" {
    printf '5' >/tmp/resume_slot.txt
    run_game "Game C.iso" "sleep 0"
    # resume_slot.txt removed (minarch would pick it up)
    assert_file_not_exist /tmp/resume_slot.txt
    refute_grep "$STUB/args" '^--state='
}

@test "7 SIGTERM (power off) still writes the preview, once" {
    rm -f "$STUB/args" "$STUB/pid" "$STUB/saved"
    printf '%s\n' "save thumb1 ULUS10041_1.00 3" "hang" >"$STUB/actions"
    # 3>&-: the background job must not hold bats' output descriptor open
    sh "$PAK/launch.sh" "$ROMDIR/Game C.iso" >"$T/launch.out" 2>&1 3>&- &
    local launch_pid=$! i=0
    while [ ! -f "$STUB/saved" ] && [ "$i" -lt 100 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
    done
    sleep 1
    kill -TERM "$launch_pid" 2>/dev/null
    kill -TERM "$(cat "$STUB/pid" 2>/dev/null)" 2>/dev/null
    wait "$launch_pid" 2>/dev/null || true
    cp "$LOGS/PSP.txt" "$(case_log)" 2>/dev/null
    assert_grep "$MINUI/Game C.iso.txt" '^3$'
    assert_same "$(preview "Game C.iso" 3)" "$(conv thumb1)"
    run sh -c "grep -v '^+' '$(case_log)' | grep -c 'Game switcher preview from save state'"
    assert_output 1
}

@test "8 jpg2bmp works on this CPU and rejects junk" {
    info "$(uname -m)"
    printf 'not an image' >"$T/junk.jpg"
    run "$PAK/bin/jpg2bmp" "$FIX/thumb1.jpg" "$T/out.bmp"
    assert_success
    run "$PAK/bin/jpg2bmp" "$T/junk.jpg" "$T/junk.bmp"
    assert_failure
    run find "$MINUI" -name '*.tmp'
    assert_output ""
}

# MinUI PSP

A [MinUI](https://github.com/shauninman/MinUI) and [NextUI](https://github.com/LoveRetro/NextUI) Emu Pak for PSP, wrapping the standalone PPSSPP emulator.

## Requirements

This pak is designed and tested on the following MinUI Platforms and devices:

- `tg5040`: Trimui Brick (formerly `tg3040`), Trimui Smart Pro
- `tg5050`: Trimui Smart Pro S

The pak may work on other platforms and devices, but it has not been tested on them.

## Installation

1. Mount your MinUI SD card.
2. Download the latest release from GitHub. It will be named `PSP.pak.zip`.
3. Copy the zip file to the correct platform folder in the "/Emus" directory on the SD card. Please ensure the new zip file name is `PSP.pak.zip`.
4. Extract the zip in place, then delete the zip file.
5. Confirm that there is a `/Emus/<PLATFORM>/PSP.pak/launch.sh` file on your SD card.
6. Create a folder at `/Roms/PlayStation Portable (PSP)` and place your ROMs in this directory.
7. Unmount your SD Card and insert it into your MinUI device.

Note: The `<PLATFORM>` folder name is based on the name of your device. For example, if you are using a TrimUI Brick, the folder is `tg5040`.

### Updating

`pak.json` lists `PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini` and `controls.ini` in `update_ignore`, so an installer or updater that honours that list (such as the NextUI Pak Store) keeps your settings and hotkey bindings. **Extracting the release zip over the installed pak by hand does not**: the zip contains both files, and extracting it in place replaces them with the shipped defaults (your PPSSPP settings and hotkeys are lost). To update by hand, back up those two files first and put them back afterwards, or extract without overwriting them (for example `unzip -o PSP.pak.zip -x 'PPSSPP/.config/ppsspp/PSP/SYSTEM/*'`). The pak itself never replaces your `ppsspp.ini` or `controls.ini`.

## Extra Controls

- `Menu` - Open the PPSSPP menu.
- `R2` - Swap between the D-Pad and the Analog Stick.

## Deep Sleep & Shutdown

Deep sleep is supported on compatible devices. Click the power button to enter deep sleep. Click again to resume the game. To shut down, hold the power button for 2 seconds. For more information and issues, see [MinUI Power Control](https://github.com/ben16w/minui-power-control).

If the device is shut down with the power button (hold for 2 seconds) while a game is running, it boots straight back into that game the next time it is turned on, the same way NextUI/MinUI auto-resume works for built-in emulators. Quitting the game to the menu as usual (via the PPSSPP menu) does not trigger this, and neither does a crash, a forced power-off of a frozen device or a flat battery: like the built-in emulators, the game is only relaunched after a normal shutdown.

**What is resumed** depends on two PPSSPP settings (PPSSPP Settings > System > Save states):

- **Save state on exit** (`SaveStateOnExit` in the `[General]` section of `ppsspp.ini`): PPSSPP saves a state (and its thumbnail) whenever the game ends: the Exit hotkey, Exit in the pause menu, and also when the power button shuts the device down. The slot is the auto-load slot if "Auto load savestate" names one, otherwise the current save state slot. This needs the PPSSPP build shipped with this pak.
- **Auto load savestate** (`AutoLoadSaveState`, `2` = load the newest state): PPSSPP loads that state when the game starts, after a power-off resume and also when you open the game from the menu.

New installs of the pak have both on (`SaveStateOnExit = True`, `AutoLoadSaveState = 2`), so after a power-off you continue at the exact moment you turned the device off. The pak does not change these settings on an existing install (and keeps your `ppsspp.ini` unless you overwrite it by extracting a release over it, see Updating), so on an existing install turn "Save state on exit" on in PPSSPP's settings (or add `SaveStateOnExit = True` below `AutoLoadSaveState` in `/Emus/<PLATFORM>/PSP.pak/PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp.ini`). Both settings can also be changed per game in a game-specific PPSSPP config.

With "Save state on exit" off, a power-off does not save a new state: the game is still relaunched, and PPSSPP loads the newest state you saved yourself (if "Auto load savestate" is on), so progress since that state or your last in-game save is lost. With "Auto load savestate" off, the game is relaunched from its start.

Note that "Save state on exit" overwrites the slot it uses each time you leave a game. Use another slot for states you want to keep.

**How it works:** `bin/poweroff` is a small shim that the power button's shutdown script runs instead of the system `poweroff` (`launch.sh` puts the pak's `bin` folder first in `PATH`). The shutdown script first tells PPSSPP to quit (SIGTERM), which makes PPSSPP save its state (it quits after at most 5 seconds, saved or not), then runs `poweroff`. The shim tells `launch.sh` that a power-off is requested and waits up to 15 seconds for the answer. Once PPSSPP has exited, `launch.sh` writes the auto-resume marker, then the Game Switcher image, and then tells the shim to go ahead, so all of it is on the card before the device turns off. If PPSSPP is still running 8 seconds after the shim's request (it should quit within about 7 seconds of the SIGTERM), `launch.sh` arms the marker and releases the shim anyway, and the Game Switcher image is skipped when the marker step was slow. When a state really was saved during the session, `launch.sh` also replaces the shutdown script's "Powering off" screen with "Quicksave created, powering off" (the platform's `show_message`, best effort, in the background, started right after the marker and before the Game Switcher image; it first waits up to 2 seconds for the shim's request so that it replaces the shutdown script's screen, and is skipped together with the Game Switcher image when the marker step was slow). The check is "a state newer than the launch exists", so with save-on-exit off a state saved by hand during the session also shows it. If PPSSPP was stopped by a signal but the power-off is not visible yet (the shutdown script runs `poweroff` a moment after the SIGTERM), `launch.sh` looks for it for up to 3 seconds; a normal Exit is not delayed. If the power-off never happens although the marker was armed (PPSSPP still running 20 seconds after the request), the marker and the request are withdrawn again, and a request older than 20 seconds is ignored. The shim never waits when no PSP game is running, and then hands over to `/sbin/poweroff`. Files used in `/tmp` (all temporary, cleared on every boot):

- `psp-poweroff-req`: created by the shim, a power-off was requested.
- `psp-poweroff-ok`: created by `launch.sh`, ready to power off.
- `psp-pak.pid`: pid of `launch.sh`, so the shim stops waiting if it is gone.
- `psp-poweroff-shim.log`: what the shim did.

**Limits:** `launch.sh` never returns to the menu while a power-off is pending; if the device has not turned off after a minute, the auto-resume marker is removed and you are back at the menu. The pak never loads a state itself (it does not pass `--state` to PPSSPP); it only relaunches the game. The resume is armed only by the power button; sleep, a crash or a dead battery do not resume. Only games located on the SD card are resumed. The pak log (`/.userdata/<PLATFORM>/logs/PSP.txt`) shows the global `SaveStateOnExit`/`AutoLoadSaveState` values at each launch.

## Saves & States

- Save states are stored in the `/.userdata/shared/PSP-ppsspp/` directory, named `<game ID>_<slot>.ppst` with a `.jpg` thumbnail. The state saved on exit is a normal save state in one of these slots.
- Game saves are stored in the `/Saves/PSP/` directory.

## Game Switcher Image

Like the built-in emulators, the image NextUI's Game Switcher shows for a game comes from a save state. When PPSSPP exits (or the device powers off while it runs), the pak takes the newest save state written during that session (including the state saved on exit), converts its thumbnail with the bundled `jpg2bmp` and writes it to `/.userdata/shared/.minui/PSP/<rom file>.<slot>.bmp`, together with the slot number in `<rom file>.txt`.

No save state means no image: NextUI shows "No Preview". Opening and resuming a game works as before.

## PPSSPP Configuration

The PPSSPP configuration directory is located at `/Emus/<PLATFORM>/PSP.pak/PPSSPP/.config/ppsspp/`. This directory contains:

- **TEXTURES directory**: `/Emus/<PLATFORM>/PSP.pak/PPSSPP/.config/ppsspp/PSP/TEXTURES/` - Place custom texture packs here for texture replacement/modding.
- **SYSTEM directory**: Contains configuration files like `ppsspp.ini` and `controls.ini`.

Note: The `<PLATFORM>` folder name is based on your device (e.g., `tg5040` for TrimUI Brick).

## Aspect Ratio

The pak auto-sets the Aspect Ratio based on the device model. On Trimui Brick it uses `0.848000`, on other supported devices it uses `1.000000`. To disable automatic configuration changes, create a file named `no-config-changes` in `/.userdata/<PLATFORM>/PSP-ppsspp/`. This will prevent the pak from modifying aspect ratio and other configuration settings. If the aspect ratio or graphics backend setting is missing from the `[Graphics]` section of `ppsspp.ini`, the pak adds it.

## RetroAchievements

On NextUI, the pak copies the RetroAchievements settings from the NextUI Settings menu into PPSSPP every time a game is launched:

- **Enabled and logged in** in NextUI: RetroAchievements are enabled in PPSSPP with the same username and login token. No separate login inside PPSSPP is needed. PPSSPP's Hardcore Mode is turned off, like in NextUI (see below).
- **Disabled, or not logged in** in NextUI: RetroAchievements are disabled in PPSSPP, and the PPSSPP username and login token are removed.
- **MinUI** (no NextUI settings file), or a NextUI version without RetroAchievements settings: PPSSPP's own RetroAchievements settings are left untouched.

Notes:

- NextUI's offline RetroAchievements mode (caching and replaying unlocks when Wi-Fi returns) is built into NextUI's own emulator frontend and is not available to standalone PPSSPP. PPSSPP connects to retroachievements.org directly, so Wi-Fi must be connected when the game starts. If the login fails at startup (no Wi-Fi), achievements stay off for that session: PPSSPP only retries the login from its game browser, not from the in-game menu that opens with the Menu button, and this pak never shows the game browser. If Wi-Fi drops during play, PPSSPP keeps retrying unlocks in the background, but unlocks not yet sent when you quit the game are lost.
- Hardcore Mode: NextUI has a Hardcore Mode setting, but it is hidden from its Settings menu and off, so NextUI always plays in softcore. PPSSPP has Hardcore Mode on by default, so the pak turns it off to match. If a NextUI version shows the setting, the pak follows it. In Hardcore Mode, PPSSPP disables save states (unless "save states in hardcore mode" was turned on inside PPSSPP).
- Per-game PPSSPP settings (game-specific configs created in PPSSPP) can override the RetroAchievements on/off and Hardcore Mode settings for that game; the pak only changes the global `ppsspp.ini`.
- If PPSSPP reports the login token as expired, it deletes it; log in again in NextUI Settings > RetroAchievements to get a new one.
- To manage RetroAchievements inside PPSSPP yourself, create a file named `no-ra-sync` in `/.userdata/<PLATFORM>/PSP-ppsspp/`. The `no-config-changes` file also disables this sync.

## Skip Buffer Effects

This option can be found under Settings > Graphics > Speed Hacks > Skip buffer effects. Use it as a last‑resort speed boost for demanding games. It can break transparency/lighting or even cause black screens. It's best to toggle it per game as needed.

## Thanks

- [hrydgard](https://github.com/hrydgard) for developing [PPSSPP](https://github.com/hrydgard/ppsspp) and related projects.
- [spruceUI](https://github.com/spruceUI) team for creating the [PPSSPP-spruce](https://github.com/spruceUI/PPSSPP-spruce) repository.
- [frysee](https://github.com/frysee) and the rest of the NextUI contributors for developing [NextUI](https://github.com/LoveRetro/NextUI).
- [Shaun Inman](https://github.com/shauninman) for developing [MinUI](https://github.com/shauninman/MinUI).
- Also [josegonzalez](https://github.com/josegonzalez), for their pak repositories, which this project is based on.

## License

This project uses PPSSPP, which is open-source software. Please refer to the original PPSSPP [LICENSE.TXT](PPSSPP/LICENSE.TXT) file for more details.

The project code which is not part of PPSSPP is licensed under the [MIT License](https://opensource.org/licenses/MIT). See the project [LICENSE](LICENSE) file for more details.

## Testing

The tests use [bats-core](https://github.com/bats-core/bats-core) with `bats-support`, `bats-assert` and `bats-file`. The Makefile downloads them at pinned versions into `tests/lib/` (git-ignored; `make clean` removes them). Needs `bash`, `jq`, `curl`, `shellcheck` and an aarch64 `bin/jpg2bmp` (built natively on aarch64, otherwise `make test CC=aarch64-linux-gnu-gcc`; it is run through `qemu-aarch64-static` when the host is not aarch64 and that is installed).

| Command | What it does |
|---|---|
| `make test` | The tests tagged `host`, on this machine. Never uses ssh. This is what CI runs. |
| `make test-device` | The tests tagged `device`, over ssh, on every configured device. Unconfigured devices are skipped (exit 0); a configured device that is unreachable is an error. The tests that **reboot** the device (tag `reboot`, see below) run afterwards from this machine; `SKIP_REBOOT_TESTS=1` leaves them out. |
| `make test-device-<platform>` | One device, e.g. `make test-device-tg5040`. Fails if it is not configured. One target exists for every platform in `pak.json`. |
| `make test-bundle` | `dist/psp-device-tests.tar.gz`: bats, its libraries, the tests, fixtures and the aarch64 `pngcolor` helper. |

`make test` runs shellcheck, the release contents check, the check that `tests/devices.env.example` matches the platforms in `pak.json`, and the tests that run the real `launch.sh` and `bin/jpg2bmp` against a stub PPSSPP in a throw-away SD tree (`tests/bats/preview.bats`: Game Switcher image; `tests/bats/ra.bats`: RetroAchievements sync, see below). By default it tests the repository checkout; `make test SRC_PAK=<unpacked release> RELEASE_ZIP=<release zip>` tests a release the way CI does. `JPG2BMP=<file>` overrides the converter, `PLATFORM` the platform under test (default: the first in `pak.json`), `KEEP=1` keeps the sandbox and `OUT_DIR` sets where logs go.

### Tags

Tests say where they run with bats tags (`# bats file_tags=...`, `# bats test_tags=...`):

- `host`: runs on the host and in CI. `device`: runs over ssh only. The stub-PPSSPP tests carry both.
- `reboot` (always together with `device`): reboots the device, so it runs on the host and uses ssh for every step (see "Auto-resume on a device, with reboots"). The on-device run leaves these out.
- `platform:<name>`: only on that platform, e.g. `tests/bats/e2e.bats`. Device tests without a platform tag run on every device. A new platform in `pak.json` therefore gets its `make` target, and the right tests, without changes to the test setup.

### Devices

Configure the devices you have in `tests/devices.env` (git-ignored; start from `tests/devices.env.example`):

```make
TG5040_HOST ?= root@brick.local
TG5040_SSH_OPTS ?= -p 2222 -i ~/.ssh/trimui
```

Values from the command line or the environment win: `make test-device-tg5040 TG5040_HOST=root@192.168.1.50`. Configuring a host is all the consent the tests need, even though the end-to-end test injects button presses and changes (then restores) the recents and resume files of its test game. ssh runs with `BatchMode=yes` (set up key-based login; there is never a password prompt) and a connect timeout (`SSH_CONNECT_TIMEOUT`, default 10 s). A platform without a line in `tests/devices.env.example` makes `make test` fail.

For each device `make test-device` checks that the device has `bash`, `tar`, `gzip` and `mktemp` (naming any that are missing), streams the test bundle to a temp dir on it, runs the `device` tests there against the pak installed in `Emus/<platform>/PSP.pak`, fetches the results and removes the temp dir. Environment variables such as `SDCARD_PATH`, `ROM_DIR`, `ROM`, `PSP_KEYS`, `EXIT_KEYS`, `BOOT_WAIT`, `UI_WAIT`, `KEY_GAP`, `CHORD_HOLD` and `KEEP` are forwarded when set (see the header of `tests/bats/e2e.bats`).

### Debug bundle

Every run writes `dist/test-report-<target>-<timestamp>.tar.gz` (target: `host` or the platform), whether it passed or failed: the TAP output, the JUnit XML, per-case logs and screenshots, `summary.md` (also shown in the CI job summary), host information (git SHA and dirty state, tool versions, make variables, timestamps, which devices were configured; the ssh address is never recorded) and, for devices, `uname -a`, `/etc/os-release`, BusyBox and bash versions, the NextUI version, `df`, the installed `pak.json` and `ppsspp.ini` and the `PSP.txt` log. What is collected is a list with one command per line in `tests/collectors/host.list` and `tests/collectors/device.list`; add a line to collect more. A collector that fails is noted in `collector-errors.txt` and never stops the bundle.

### End-to-end test (device only)

`tests/bats/e2e.bats` drives the real NextUI and PPSSPP on a TrimUI device with no one at the buttons: it injects button presses through the `TRIMUI Player1` evdev device, launches the first game in `Roms/*(PSP)` through NextUI's `/tmp/next` hand-off, and takes screenshots with the [Screenshot Monitor](https://github.com/josegonzalez/minui-screenshot-monitor-pak) pak's `bin/screenshot`. Screenshots are judged by the bundled `pngcolor` helper.

Requirements: root over ssh, this pak and the Screenshot Monitor pak installed, and a game in `Roms/*(PSP)`. Do not touch the device while it runs. The test temporarily changes the recents and resume files of the test game and restores them at the end (its backup is kept on the SD card, so a run that was cut short is restored at the start of the next one). It restarts NextUI with SIGKILL, never SIGTERM, because NextUI treats SIGTERM as a power-off request. See the header of `e2e.bats` for the settings, and "What the on-device tests assume" below for the hotkeys and the NextUI settings.

### What the on-device tests assume, and how they check it

The device tests (end-to-end and reboot) read the device's configuration instead of assuming it, and check what they still need **before touching anything**; a failed check is ONE message that lists everything to change (`FAIL: ...` lines in the e2e `setup_file` message and in the reboot preflight).

- **Hotkeys.** PPSSPP keeps hotkey bindings in `controls.ini` (`[ControlMapping]`, e.g. `Save State = 10-196:10-192`: a chord of two pad buttons, `,` separates alternatives; `10` is the pad and the number PPSSPP's key code), next to `ppsspp.ini` in the pak's `PPSSPP/.config/ppsspp/PSP/SYSTEM/`. The tests read `Save State`, `Next Slot` and `Exit App` (as PPSSPP does: key names without regard to case, the first line wins) and turn the key codes into buttons of the `TRIMUI Player1` pad with PPSSPP's fixed code table for pads (19-22 d-pad, 188 X, 189 B, 190 A, 191 Y, 192 R1, 193 L1, 196 select, 197 start; not the PSP button rows of the file, which the user may have swapped). **PPSSPP has no default binding for these hotkeys**, and the shipped `controls.ini` has none. So a hotkey that is **not bound** (absent or empty) is **bound temporarily by the tests**: Save State = select+R1 (`10-196:10-192`), Next Slot = select+right (`10-196:10-22`), Exit App = select+start (`10-196:10-197`), or, when another action in the file already uses that exact chord, the first free fallback (start+R1 / start+right / start+L1, ...); if none is free the preflight says so. Only the missing keys are added inside `[ControlMapping]` (the section is appended if the file has none); every other line, the BOM and CRLF endings are untouched, a hotkey you bound is never changed, and a `controls.ini` that does not exist is not created (the preflight says so). The original `controls.ini` is backed up byte for byte on the SD card together with the other files the tests change, and restored at the end, in teardown, after the reboot tests, and at the start of the next run if a run was cut short; if the file was changed in the meantime the changed copy is kept as `controls.ini.replaced` next to the backup and a warning is printed. The bindings are in place before any game is launched (PPSSPP reads the file at start) and stay across the reboots. The log lists what was bound (`hotkeys.txt` in the debug bundle). `SET_HOTKEYS=0` turns this off: an unbound hotkey is then a preflight failure naming what to bind. `SAVE_KEYS`, `NEXT_SLOT_KEYS` or `EXIT_KEYS` (one chord each, e.g. `select+r1`; `EXIT_KEYS=""` kills PPSSPP instead, e2e only), or the whole sequence with `PSP_KEYS`, win and mean the file is not touched for that hotkey. A binding to something the pad injection cannot press (keyboard, another pad, an axis, the menu button, L2/R2) is a preflight failure and never overwritten. Each test file only needs what it presses: the reboot tests do not need Next Slot, the e2e test does unless `PSP_KEYS` is given. Per-game control mappings are not read. Not verified without a device: that PPSSPP picks the new chords up on launch. The log prints what was used and where it came from.
- **NextUI start screen** (menu or Game Switcher). Nothing in the tests depends on it: every Game Switcher check opens the switcher explicitly, the other checks look at processes and files. The relevant lines of `minuisettings.txt` are printed in the log and collected in the debug bundle (`controls.ini`, `minui-state.txt` and `minuisettings.txt`, in which every value of a key containing token, password, user or auth, such as the RetroAchievements login, is replaced by `<hidden>`; `ppsspp.ini` is redacted the same way).
- **Also checked:** root, the pak (with `jpg2bmp`, and for the reboot tests the `poweroff` shim), `ppsspp.ini`, a game in `Roms/*(PSP)`, the pad, the NextUI launcher, the Screenshot Monitor pak (e2e), `pngcolor` (e2e). The reboot tests set `SaveStateOnExit`/`AutoLoadSaveState` themselves.

The parsing and the preflight are covered off-device by `tests/bats/devconfig.bats` and `tests/bats/reboot-helpers.bats`.

### Auto-resume on a device, with reboots (device only)

`tests/bats/reboot.bats` tests this pak's auto-resume feature on a real TrimUI device, including real reboots. It runs after the on-device tests of `make test-device`, or alone with `bash tests/run-reboot.sh <platform> <dir>` (with `DEVICE_HOST` and `DEVICE_SSH_OPTS` set). Cases:

| Case | What it checks |
|---|---|
| R1, R2 | Quitting with the Exit hotkey saves a new state (`.ppst`) and its Game Switcher preview, and arms **no** `auto_resume.txt`. NextUI is up and launches no game, also after NextUI is restarted (no auto-launch). |
| R3, R4, R5 | A power-off request (SIGTERM to PPSSPP plus the pak's `poweroff` shim, which is what the power button's shutdown script does): the marker is armed with the game's path, a state is saved, the device reboots, NextUI relaunches the game (PPSSPP runs the test ROM) and consumes the marker. |
| R6 | A crash (`kill -9` PPSSPP): no marker, back at the menu, no auto-launch. |
| R7 | A forced reboot with no handshake (the power-cut analogue: `sync` then `reboot -f`): no auto-resume, the save states are untouched. |
| R8, R9 | "Save state on exit" off (`SaveStateOnExit = False`): a power-off still arms the marker and relaunches the game, with no new state saved (PPSSPP loads the newest existing one). |

**Design.** A reboot ends the ssh session that the on-device bats runs in, so these tests run on the host and drive the device with ssh. Each step is a short ssh call that sources a small kit (`tests/helpers/e2e.bash` plus `tests/helpers/reboot-device.bash`, streamed to `/tmp` on the device, and again after every boot because a reboot clears `/tmp`). They reuse the button injection, the `/tmp/next` hand-off and the backup/restore of the end-to-end test. Waits poll with timeouts: after the power-off request the device must go **down** within `REBOOT_DOWN_TIMEOUT` (90 s) and come **back** (ssh answers with a new `boot_id`) within `REBOOT_UP_TIMEOUT` (300 s); after the boot NextUI must relaunch the game within `RESUME_TIMEOUT` (180 s). The address after the reboot must be the same (use a hostname or a DHCP reservation). Because the marker, the log and the states are lost to a reboot or overwritten by the resumed game, the power-off wrapper (below) copies them to the SD card at the moment of the final power-off call, and the test reads them after the boot. A run takes roughly 15 minutes.

**Reboot instead of power-off (the trade-off).** A real power-off cannot be undone remotely, so in R3 and R8 the final call of the shim, `/sbin/poweroff`, is replaced by a test wrapper that records what `launch.sh` had armed and saved at that moment, syncs and runs `reboot`. The shim already supports this for its own tests (`PSP_POWEROFF_REAL`); the wrapper is passed in the environment of that single call, so no production code changes, nothing in the system is replaced, and the wrapper (in `/tmp`) disappears with the reboot or when the test restores. Before anything starts, the preflight proves that the shim calls whatever `PSP_POWEROFF_REAL` names, and refuses to run if it does not (an older pak would really power off). Not covered: the real `poweroff` command itself, and minui-power-control's own button handling and shutdown script (the test plays its role: SIGTERM to PPSSPP, then the shim).

**Keeping the device awake.** While it waits, the test sends a harmless button tap through the evdev pad every `KEEPAWAKE_INTERVAL` seconds (default 10; `KEEPAWAKE_KEY`, default `l1`, which pages the list in NextUI's menus and is a plain shoulder button in PPSSPP, and is not part of any chord the tests use; `0` turns it off), which restarts NextUI's idle timer (`launch.sh` also sets `/tmp/stay_awake` while a game runs). Only with a clear signal (a backlight node `bl_power` that is not 0; a brightness of 0 or a missing node never counts, so the power key is never tapped on a guess; `SLEEP_PROBE`, a command that succeeds when asleep, overrides the check) it taps the power key on the input device whose name matches `POWER_DEV_NAME` (default `axp|pek|power|gpio-keys`) instead; a short tap, far from the long press that powers off. A device in deep sleep does not answer ssh and cannot be woken from here, so the tests rely on prevention. The steps are skipped while the device is rebooting. After a reboot the tests also wait until the SD card is mounted again before reading the evidence. The state snapshots wait until the files stop changing and compare size and checksum (`md5sum`, else `cksum`).

Requirements: those of the end-to-end test (root over ssh, a game in `Roms/*(PSP)`, the Save State and Exit hotkeys of PPSSPP on a pad chord, see below), key-based ssh that works again after a reboot, and nothing else touching the device. The Screenshot Monitor pak is optional (an evidence screenshot after the resume). Settings: `NOGAME_WAIT` (25 s, how long "no auto-launch" is watched), `BOOT_WAIT`, `UI_WAIT`, `EXIT_KEYS`, `ROM`, `ROM_DIR`, `SDCARD_PATH` as for the end-to-end test. The tests set `SaveStateOnExit` and `AutoLoadSaveState = 2` in the global `ppsspp.ini` themselves (a per-game PPSSPP config would override them). Recents, resume files, the slot file and previews of the test game and `ppsspp.ini` are backed up on the SD card (`/.userdata/shared/.psp-reboot-backup`) and restored at the end, every existing file in the save state folder is copied there and put back (a test overwrites a slot of the test game), new save states are deleted, and a run that was cut short is restored at the start of the next one. Evidence (what the wrapper recorded, the pak log, screenshots) is in the debug bundle under `reboot/logs/reboot/`; the TAP and JUnit results are in `reboot/` (`reboot/junit/report.xml`) and count in `summary.md`.

The helpers are tested without a device in `tests/bats/reboot-helpers.bats` (part of `make test`): a fake `ssh` runs the device-side code against a throw-away SD tree, with the real `bin/poweroff`: waits and timeouts, the keep-awake steps, reboot detection (including a connection that drops without a reboot), backup and restore (also of an aborted run), the wrapper, the preflight and the tags.

### CI

CI runs `make test` against the unpacked release, shows per-test results on the pull request (check run from the JUnit XML, using `dorny/test-reporter`), appends `summary.md` to the job summary and uploads the debug bundle. Pull requests from forks get a read-only token and cannot create the check run; the job summary and the artifact are the fallback. CI then runs `make test` a second time with `LAUNCH_SHELL="busybox sh"` (`busybox-static` from apt), so `launch.sh` is also run by the shell the devices have; its results and debug bundle are named `Tests (BusyBox sh)` and `test-report-host-busybox`.

## Testing RetroAchievements

`tests/bats/ra.bats` has one test per case. Each runs the real `launch.sh` against a stub PPSSPP in its own throw-away SD tree with a NextUI-style `minuisettings.txt` (helpers in `tests/helpers/ra.bash`), and checks what PPSSPP would see at start-up (the `[Achievements]` section of `ppsspp.ini` and the token file): enabled in softcore and hardcore, disabled, not logged in, MinUI and older NextUI (PPSSPP left alone), the `no-ra-sync` and `no-config-changes` flags, usernames with special characters, older and CRLF ini files, token normalisation, that a custom RetroAchievements server set in PPSSPP is left alone, that a second launch rewrites nothing, that the token and password never reach the log (also with the `debug` flag), and that a failed ini write (full SD card) leaves `ppsspp.ini` unchanged. The tests are bats (bash); only `launch.sh` runs under `LAUNCH_SHELL` (default `sh`; CI also runs everything with `LAUNCH_SHELL="busybox sh"`, and `make test LAUNCH_SHELL="busybox sh"` does the same locally with `busybox-static` installed). `make test` and `make test-device` run them, and `LAUNCH_SHELL`, `TMP_ROOT` and `KEEP` are forwarded to the device. To run only these: `tests/lib/bats-core/bin/bats tests/bats/ra.bats` (env: `SRC_PAK`, `PAK_NAME`, `PLATFORM`, `OUT_DIR`, `TMP_ROOT`, `LAUNCH_SHELL`, `KEEP`). Set `TMP_ROOT=/mnt/SDCARD` to run the sandbox on the SD card's FAT file system instead of `/tmp`. Logs of each `launch.sh` run are kept in `$OUT_DIR/ra/<test number>.<run>.log`.

What needs a person and a real account (not automated):

1. **Login via NextUI only:** log out inside PPSSPP (or delete `PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp_retroachievements.dat`), log in under NextUI Settings > RetroAchievements, start a PSP game with Wi-Fi on. PPSSPP shows the RetroAchievements login message and the game's achievement count; the pak log (`.userdata/<PLATFORM>/logs/PSP.txt`) says `RetroAchievements: enabling for user ...`.
2. **Unlock:** earn an easy achievement. The unlock pop-up appears in PPSSPP and the unlock shows on retroachievements.org.
3. **Softcore:** after a launch, PPSSPP's Hardcore Mode is off, save states work, and the game shows as softcore on the site.
4. **Disable:** turn RetroAchievements off in NextUI and start a game: no login message, and PPSSPP's Achievements settings show it disabled and logged out.
5. **Wi-Fi off:** start a game with Wi-Fi off. The game runs normally, PPSSPP shows a login failure, and no achievements are active for that session. Turn Wi-Fi on and restart the game: login works again.

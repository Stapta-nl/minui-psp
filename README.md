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

## Extra Controls

- `Menu` - Open the PPSSPP menu.
- `R2` - Swap between the D-Pad and the Analog Stick.

## Deep Sleep & Shutdown

Deep sleep is supported on compatible devices. Click the power button to enter deep sleep. Click again to resume the game. To shut down, hold the power button for 2 seconds. **Note:** Shutdown does not save or resume the game and any unsaved progress will be lost. For more information and issues, see [MinUI Power Control](https://github.com/ben16w/minui-power-control).

## Saves & States

- Save states are stored in the `/.userdata/shared/PSP-ppsspp/` directory.
- Game saves are stored in the `/Saves/PSP/` directory.

## Game Switcher Image

Like the built-in emulators, the image NextUI's Game Switcher shows for a game comes from a save state. When PPSSPP exits (or the device powers off while it runs), the pak takes the newest save state written during that session, converts its thumbnail with the bundled `jpg2bmp` and writes it to `/.userdata/shared/.minui/PSP/<rom file>.<slot>.bmp`, together with the slot number in `<rom file>.txt`.

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
| `make test-device` | The tests tagged `device`, over ssh, on every configured device. Unconfigured devices are skipped (exit 0); a configured device that is unreachable is an error. |
| `make test-device-<platform>` | One device, e.g. `make test-device-tg5040`. Fails if it is not configured. One target exists for every platform in `pak.json`. |
| `make test-bundle` | `dist/psp-device-tests.tar.gz`: bats, its libraries, the tests, fixtures and the aarch64 `pngcolor` helper. |

`make test` runs shellcheck, the release contents check, the check that `tests/devices.env.example` matches the platforms in `pak.json`, and the tests that run the real `launch.sh` and `bin/jpg2bmp` against a stub PPSSPP in a throw-away SD tree (`tests/bats/preview.bats`: Game Switcher image; `tests/bats/ra.bats`: RetroAchievements sync, see below). By default it tests the repository checkout; `make test SRC_PAK=<unpacked release> RELEASE_ZIP=<release zip>` tests a release the way CI does. `JPG2BMP=<file>` overrides the converter, `PLATFORM` the platform under test (default: the first in `pak.json`), `KEEP=1` keeps the sandbox and `OUT_DIR` sets where logs go.

### Tags

Tests say where they run with bats tags (`# bats file_tags=...`, `# bats test_tags=...`):

- `host`: runs on the host and in CI. `device`: runs over ssh only. The stub-PPSSPP tests carry both.
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

Requirements: root over ssh, this pak and the Screenshot Monitor pak installed, and a game in `Roms/*(PSP)`. Do not touch the device while it runs. The test temporarily changes the recents and resume files of the test game and restores them at the end (its backup is kept on the SD card, so a run that was cut short is restored at the start of the next one). It restarts NextUI with SIGKILL, never SIGTERM, because NextUI treats SIGTERM as a power-off request. It expects these PPSSPP hotkeys: select+R1 saves a state, select+right moves to the next slot, select+start exits. See the header of `e2e.bats` for the settings.

### CI

CI runs `make test` against the unpacked release, shows per-test results on the pull request (check run from the JUnit XML, using `dorny/test-reporter`), appends `summary.md` to the job summary and uploads the debug bundle. Pull requests from forks get a read-only token and cannot create the check run; the job summary and the artifact are the fallback. CI also runs the RetroAchievements cases in a BusyBox container, where every tool is a BusyBox applet like on the device.

## Testing RetroAchievements

`tests/ra.sh` runs the real `launch.sh` against a stub PPSSPP in a throw-away SD tree with a NextUI-style `minuisettings.txt`, and checks what PPSSPP would see at start-up (the `[Achievements]` section of `ppsspp.ini` and the token file): enabled in softcore and hardcore, disabled, not logged in, MinUI and older NextUI (PPSSPP left alone), the `no-ra-sync` and `no-config-changes` flags, usernames with special characters, older and CRLF ini files, token normalisation, that a custom RetroAchievements server set in PPSSPP is left alone, that a second launch rewrites nothing, that the token and password never reach the log (also with the `debug` flag), and that a failed ini write (full SD card) leaves `ppsspp.ini` unchanged. It is a POSIX `sh` script so that it can also run under BusyBox; `tests/bats/ra.bats` runs it as part of `make test` and `make test-device`. To run it by hand: `SRC_PAK=<pak> sh tests/ra.sh` (its header lists `PLATFORM`, `OUT_DIR`, `TMP_ROOT`, `LAUNCH_SHELL`, `KEEP`). Set `TMP_ROOT=/mnt/SDCARD` to run the sandbox on the SD card's FAT file system instead of `/tmp`.

What needs a person and a real account (not automated):

1. **Login via NextUI only:** log out inside PPSSPP (or delete `PPSSPP/.config/ppsspp/PSP/SYSTEM/ppsspp_retroachievements.dat`), log in under NextUI Settings > RetroAchievements, start a PSP game with Wi-Fi on. PPSSPP shows the RetroAchievements login message and the game's achievement count; the pak log (`.userdata/<PLATFORM>/logs/PSP.txt`) says `RetroAchievements: enabling for user ...`.
2. **Unlock:** earn an easy achievement. The unlock pop-up appears in PPSSPP and the unlock shows on retroachievements.org.
3. **Softcore:** after a launch, PPSSPP's Hardcore Mode is off, save states work, and the game shows as softcore on the site.
4. **Disable:** turn RetroAchievements off in NextUI and start a game: no login message, and PPSSPP's Achievements settings show it disabled and logged out.
5. **Wi-Fi off:** start a game with Wi-Fi off. The game runs normally, PPSSPP shows a login failure, and no achievements are active for that session. Turn Wi-Fi on and restart the game: login works again.

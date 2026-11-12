PAK_NAME := $(shell jq -r .name pak.json)

MINUI_POWER_CONTROL_VERSION := 1.1.0
# PPSSPP build with "Save state on exit" (Stapta-nl/ppsspp save-on-exit-v1.20.3).
# Override on the command line, e.g. make build PPSSPP_RELEASE_URL=https://.../beta-main
PPSSPP_RELEASE_URL ?= https://github.com/Stapta-nl/PPSSPP-spruce/releases/download/beta-save-on-exit
SPRUCEOS_PSP_URL := https://raw.githubusercontent.com/spruceUI/spruceOS/main/Emu/PSP
STB_COMMIT := d14d46f6b44456eb88beac58cba833a4135d4c89

# Test framework: bats-core and its helper libraries, downloaded into tests/lib (git-ignored).
BATS_CORE_VERSION := 1.11.1
BATS_SUPPORT_VERSION := 0.3.0
BATS_ASSERT_VERSION := 2.1.0
BATS_FILE_VERSION := 0.4.0
BATS_GITHUB_URL := https://github.com/bats-core

# Supported platforms: the single source of truth is pak.json. The per-device test targets
# (test-device-<platform>) and the device settings are generated from this list.
PLATFORMS := $(shell jq -r '.platforms[]' pak.json)
comma := ,
empty :=
space := $(empty) $(empty)
platform_upper = $(shell printf '%s' '$(1)' | tr '[:lower:]' '[:upper:]')

# Device settings (<PLATFORM>_HOST, optional <PLATFORM>_SSH_OPTS). tests/devices.env is
# git-ignored; copy tests/devices.env.example. It only uses "?=", so values from the
# command line or the environment take precedence.
-include tests/devices.env
DEVICE_VARS := $(foreach p,$(PLATFORMS),$(call platform_upper,$(p))_HOST $(call platform_upper,$(p))_SSH_OPTS)
export $(DEVICE_VARS)

# bin/jpg2bmp must be an aarch64 binary. CI builds natively on ubuntu-24.04-arm;
# when building elsewhere pass a cross compiler, e.g. CC=aarch64-linux-gnu-gcc.

# Off-device checks: syntax, shellcheck, the auto-resume test.
# POSIX sh scripts (sh -n); the test runners tests/run-*.sh, bundle.sh and collect.sh are bash.
SH_FILES := launch.sh bin/poweroff $(wildcard scripts/*.sh) tests/autoresume.sh tests/collectors/pak-files.sh
SHELL_FILES := $(SH_FILES) $(filter-out $(SH_FILES),$(wildcard tests/*.sh))

lint:
	for f in $(SH_FILES); do sh -n "$$f" || exit 1; done
	shellcheck -x $(SHELL_FILES)

# The auto-resume logic (real launch.sh, stub PPSSPP, real bind mounts; needs root or sudo).
# Plain sh on purpose: CI also runs it under BusyBox in docker (see ci.yaml). The poweroff shim
# protocol is tests/bats/poweroff.bats. Part of "make test"; SRC_PAK is passed on to the script.
.PHONY: lint test-shell
test-shell: lint
	sh tests/autoresume.sh

clean:
	rm -f bin/minui-power-control bin/setalpha bin/jpg2bmp PPSSPP/PPSSPPSDL_tg5040 PPSSPP/PPSSPPSDL_tg5050 PPSSPP/libstdc++.so.6 src/stb_image.h tests/bin/pngcolor dist/psp-device-tests.tar.gz dist/test-report-*.tar.gz
	rm -rf tests/lib dist/test-out

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

build: bin/minui-power-control bin/setalpha bin/jpg2bmp PPSSPP/PPSSPPSDL_tg5040 PPSSPP/PPSSPPSDL_tg5050 PPSSPP/libstdc++.so.6
	@echo "Build complete"

bin/minui-power-control:
	mkdir -p bin
	curl -f -o bin/minui-power-control -sSL https://github.com/ben16w/minui-power-control/releases/download/$(MINUI_POWER_CONTROL_VERSION)/minui-power-control
	chmod +x bin/minui-power-control

PPSSPP/PPSSPPSDL_tg5040:
	curl -f -o PPSSPP/PPSSPPSDL_tg5040 -sSL $(PPSSPP_RELEASE_URL)/PPSSPPSDL_TrimUI
	chmod +x PPSSPP/PPSSPPSDL_tg5040

PPSSPP/PPSSPPSDL_tg5050:
	curl -f -o PPSSPP/PPSSPPSDL_tg5050 -sSL $(PPSSPP_RELEASE_URL)/PPSSPPSDL_SmartProS
	chmod +x PPSSPP/PPSSPPSDL_tg5050

bin/setalpha:
	curl -f -o bin/setalpha -sSL $(SPRUCEOS_PSP_URL)/setalpha
	chmod +x bin/setalpha

src/stb_image.h:
	curl -f -o src/stb_image.h -sSL https://raw.githubusercontent.com/nothings/stb/$(STB_COMMIT)/stb_image.h

bin/jpg2bmp: src/jpg2bmp.c src/stb_image.h
	mkdir -p bin
	$(CC) -Os -s -static -o bin/jpg2bmp src/jpg2bmp.c
	@if ! file bin/jpg2bmp | grep -q 'ARM aarch64'; then \
		echo "bin/jpg2bmp is not an aarch64 binary ($$(file -b bin/jpg2bmp)). Build on aarch64 or pass CC=aarch64-linux-gnu-gcc." >&2; \
		rm -f bin/jpg2bmp; \
		exit 1; \
	fi
	chmod +x bin/jpg2bmp

PPSSPP/libstdc++.so.6:
	curl -f -o PPSSPP/libstdc++.so.6 -sSL $(SPRUCEOS_PSP_URL)/libstdc%2B%2B.so.6

# Test helper for tests/bats/e2e.bats (not shipped in the pak): average colour of a PNG.
tests/bin/pngcolor: src/pngcolor.c src/stb_image.h
	mkdir -p tests/bin
	$(CC) -Os -s -static -o tests/bin/pngcolor src/pngcolor.c
	@if ! file tests/bin/pngcolor | grep -q 'ARM aarch64'; then \
		echo "tests/bin/pngcolor is not an aarch64 binary ($$(file -b tests/bin/pngcolor)). Build on aarch64 or pass CC=aarch64-linux-gnu-gcc." >&2; \
		rm -f tests/bin/pngcolor; \
		exit 1; \
	fi

# bats-core and its helper libraries, at pinned release versions.
tests/lib/bats-core/bin/bats:
	mkdir -p tests/lib/bats-core
	curl -f -o tests/lib/bats-core.tar.gz -sSL $(BATS_GITHUB_URL)/bats-core/archive/refs/tags/v$(BATS_CORE_VERSION).tar.gz
	tar -xzf tests/lib/bats-core.tar.gz --strip-components=1 -C tests/lib/bats-core
	rm -f tests/lib/bats-core.tar.gz

tests/lib/bats-support/load.bash:
	mkdir -p tests/lib/bats-support
	curl -f -o tests/lib/bats-support.tar.gz -sSL $(BATS_GITHUB_URL)/bats-support/archive/refs/tags/v$(BATS_SUPPORT_VERSION).tar.gz
	tar -xzf tests/lib/bats-support.tar.gz --strip-components=1 -C tests/lib/bats-support
	rm -f tests/lib/bats-support.tar.gz

tests/lib/bats-assert/load.bash:
	mkdir -p tests/lib/bats-assert
	curl -f -o tests/lib/bats-assert.tar.gz -sSL $(BATS_GITHUB_URL)/bats-assert/archive/refs/tags/v$(BATS_ASSERT_VERSION).tar.gz
	tar -xzf tests/lib/bats-assert.tar.gz --strip-components=1 -C tests/lib/bats-assert
	rm -f tests/lib/bats-assert.tar.gz

tests/lib/bats-file/load.bash:
	mkdir -p tests/lib/bats-file
	curl -f -o tests/lib/bats-file.tar.gz -sSL $(BATS_GITHUB_URL)/bats-file/archive/refs/tags/v$(BATS_FILE_VERSION).tar.gz
	tar -xzf tests/lib/bats-file.tar.gz --strip-components=1 -C tests/lib/bats-file
	rm -f tests/lib/bats-file.tar.gz

BATS_DEPS := tests/lib/bats-core/bin/bats tests/lib/bats-support/load.bash tests/lib/bats-assert/load.bash tests/lib/bats-file/load.bash

# --- tests ---------------------------------------------------------------------------
# make test                      tests tagged "host": runs on the host and in CI, never uses ssh
# make test-device               on-device tests (tagged "device") on every configured device
# make test-device-<platform>    one device (generated for every platform in pak.json)
# Every run writes dist/test-report-<target>-<timestamp>.tar.gz (see README.md).
#
# By default the repository checkout is tested. SRC_PAK=<dir> tests an unpacked release
# instead (CI does this), RELEASE_ZIP=<zip> also checks the release archive contents and
# JPG2BMP=<file> overrides the aarch64 converter.
.PHONY: test test-device test-bundle $(addprefix test-device-,$(PLATFORMS))

test: test-shell $(BATS_DEPS) $(if $(or $(SRC_PAK),$(JPG2BMP)),,bin/jpg2bmp)
	MAKE_VARS="PAK_NAME=$(PAK_NAME) PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) SRC_PAK=$(SRC_PAK) RELEASE_ZIP=$(RELEASE_ZIP) JPG2BMP=$(JPG2BMP) CC=$(CC) MAKECMDGOALS=$(MAKECMDGOALS)" \
		bash tests/run-host.sh

# The bundle (which needs an aarch64 toolchain) is only built when a device is configured.
CONFIGURED_PLATFORMS := $(strip $(foreach p,$(PLATFORMS),$(if $(strip $($(call platform_upper,$(p))_HOST)),$(p))))

test-device: $(if $(CONFIGURED_PLATFORMS),test-bundle)
	@fail=0; for p in $(PLATFORMS); do \
		MAKE_VARS="PAK_NAME=$(PAK_NAME) PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) MAKECMDGOALS=$(MAKECMDGOALS)" \
			bash tests/run-device.sh "$$p" --skip-unconfigured || fail=1; \
	done; exit $$fail

.SECONDEXPANSION:
$(addprefix test-device-,$(PLATFORMS)): test-device-%: $$(if $$(strip $$($$(call platform_upper,$$*)_HOST)),test-bundle)
	MAKE_VARS="PAK_NAME=$(PAK_NAME) PLATFORMS=$(subst $(space),$(comma),$(PLATFORMS)) MAKECMDGOALS=$(MAKECMDGOALS)" \
		bash tests/run-device.sh "$*"

# Everything needed to run the on-device tests; run-device.sh copies it to the device.
test-bundle: $(BATS_DEPS) tests/bin/pngcolor
	mkdir -p dist
	tar -czf dist/psp-device-tests.tar.gz \
		--exclude='tests/lib/*/test' --exclude='tests/lib/*/docs' --exclude='tests/lib/*/man' \
		tests/bats tests/helpers tests/fixtures tests/lib tests/bin \
		tests/run-bats.sh tests/collect.sh tests/collectors
	ls -lah dist

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	ls -lah dist

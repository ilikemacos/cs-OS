# cs-OS — CLI-only build pipeline.
#
# No .xcodeproj, no Xcode UI, ever. SwiftPM compiles the binary; this Makefile
# assembles the .app bundle by hand (SwiftPM cannot emit one), signs it ad-hoc
# with the virtualization entitlement, and produces a distributable tarball.
#
#   make            build + bundle a runnable cs-OS.app in dist/
#   make assets     fetch/build the Linux kernel + initfs (slow, cached)
#   make run        build and launch
#   make archive    tarball + sha256 for release
#   make release    archive + GitHub release upload
#   make clean

SHELL      := /bin/bash
VERSION    ?= 0.1.0
BUILD      ?= $(shell date +%Y%m%d%H%M)
CONFIG     ?= release
ARCH       := arm64

APP_NAME   := cs-OS
BINARY     := csos
BUNDLE_ID  := com.chopstickshq.csos

ROOT       := $(shell pwd)
BUILD_DIR  := $(ROOT)/.build
ASSETS     := $(BUILD_DIR)/assets
DIST       := $(ROOT)/dist
APP        := $(DIST)/$(APP_NAME).app
CONTENTS   := $(APP)/Contents
MACOS_DIR  := $(CONTENTS)/MacOS
RES_DIR    := $(CONTENTS)/Resources

ARTIFACT   := cs-os-v$(VERSION)-$(ARCH).zip
SWIFT_BIN  := $(BUILD_DIR)/$(CONFIG)/$(BINARY)

CYAN := \033[38;5;110m
RESET := \033[0m
define log
	@printf "$(CYAN)==>$(RESET) %s\n" $(1)
endef

.PHONY: all
all: bundle

# ---------------------------------------------------------------- preflight

.PHONY: preflight
preflight:
	@xcrun --show-sdk-version >/dev/null 2>&1 || { \
	  printf "\033[31merror:\033[0m Xcode license not accepted.\n"; \
	  printf "  Run: sudo xcodebuild -license accept\n"; exit 1; }
	@[ "$$(uname -m)" = "arm64" ] || { \
	  printf "\033[31merror:\033[0m cs-OS requires Apple silicon.\n"; exit 1; }
	@sw_vers -productVersion | awk -F. '$$1 < 26 { \
	  print "\033[31merror:\033[0m macOS 26 or later required (found " $$0 ")"; exit 1 }'

# ---------------------------------------------------------------- assets

$(ASSETS)/vmlinux:
	@bash scripts/fetch-assets.sh

.PHONY: assets
assets: $(ASSETS)/vmlinux

# ---------------------------------------------------------------- compile

.PHONY: build
build: preflight
	$(call log,"compiling csos ($(CONFIG))")
	@swift build -c $(CONFIG) --arch $(ARCH)

# ---------------------------------------------------------------- bundle

.PHONY: bundle
bundle: build assets
	$(call log,"assembling $(APP_NAME).app")
	@rm -rf "$(APP)"
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)/linux"

	@cp "$(SWIFT_BIN)" "$(MACOS_DIR)/$(BINARY)"
	@strip -rSTx "$(MACOS_DIR)/$(BINARY)" 2>/dev/null || true

	@sed -e 's/__VERSION__/$(VERSION)/' -e 's/__BUILD__/$(BUILD)/' \
	    Resources/Info.plist > "$(CONTENTS)/Info.plist"

	@cp "$(ASSETS)/vmlinux" "$(RES_DIR)/linux/vmlinux"
	@cp $(ASSETS)/JetBrainsMonoNL-*.ttf "$(RES_DIR)/" 2>/dev/null || true
	@[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$(RES_DIR)/" || true

	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@$(MAKE) --no-print-directory sign
	$(call log,"bundled: $(APP) ($$(du -sh '$(APP)' | cut -f1))")

# ---------------------------------------------------------------- sign
#
# Ad-hoc signature. This is sufficient because cs-OS is distributed only via
# `curl | sh` — curl does not set com.apple.quarantine, so Gatekeeper does not
# demand notarization. A browser-downloaded copy of the tarball WILL be blocked.
# To notarize later: set DEVELOPER_ID and add a `notarize` step.

.PHONY: sign
sign:
	$(call log,"signing (ad-hoc) with virtualization entitlement")
	@plutil -lint Resources/csos.entitlements >/dev/null \
	  || { echo "entitlements plist is malformed"; exit 1; }
	@codesign --force --sign - \
	    --entitlements Resources/csos.entitlements \
	    --timestamp=none \
	    "$(APP)"
	@codesign --verify --verbose=1 "$(APP)" 2>&1 | sed 's/^/    /'
	@codesign -d --entitlements - --xml "$(APP)" 2>/dev/null \
	  | plutil -convert xml1 -o - - 2>/dev/null \
	  | grep -q 'com.apple.security.virtualization' \
	  && echo "    virtualization entitlement present" \
	  || echo "    WARNING: virtualization entitlement missing from signature"

# ---------------------------------------------------------------- archive

.PHONY: archive
archive: bundle
	$(call log,"creating $(ARTIFACT)")
	@rm -f "$(DIST)/$(ARTIFACT)" "$(DIST)/$(ARTIFACT).sha256"
	@# ditto, not zip/tar: it is the only archiver that reliably preserves
	@# the code signature, symlinks and extended attributes of a .app.
	@# `tar czf` silently corrupts the signature and the bundle fails to launch.
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/$(ARTIFACT)"
	@cd "$(DIST)" && shasum -a 256 "$(ARTIFACT)" | tee "$(ARTIFACT).sha256"
	@printf '{\n  "version": "%s",\n  "artifact": "%s",\n  "sha256": "%s",\n  "min_macos": "26.0",\n  "arch": "arm64"\n}\n' \
	    "$(VERSION)" "$(ARTIFACT)" \
	    "$$(shasum -a 256 '$(DIST)/$(ARTIFACT)' | cut -d' ' -f1)" \
	    > "$(DIST)/latest.json"
	$(call log,"archive: $(DIST)/$(ARTIFACT) ($$(du -h '$(DIST)/$(ARTIFACT)' | cut -f1))")

.PHONY: release
release: archive
	$(call log,"publishing v$(VERSION) to GitHub")
	@gh release create "v$(VERSION)" \
	    "$(DIST)/$(ARTIFACT)" "$(DIST)/$(ARTIFACT).sha256" "$(DIST)/latest.json" \
	    --title "cs-OS v$(VERSION)" --notes-file CHANGELOG.md

# ---------------------------------------------------------------- dev

.PHONY: run
run: bundle
	@open "$(APP)"

.PHONY: install
install: bundle
	$(call log,"installing to /Applications")
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP)" /Applications/

.PHONY: clean
clean:
	@rm -rf "$(DIST)" "$(BUILD_DIR)/$(CONFIG)"

.PHONY: distclean
distclean:
	@rm -rf "$(DIST)" "$(BUILD_DIR)"

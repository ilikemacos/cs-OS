# cs-OS — CLI-only build pipeline.
#
# No .xcodeproj, no Xcode UI, no sudo, ever.
#
# This drives `swiftc` directly rather than SwiftPM, because SwiftPM is not
# usable on stock Command Line Tools: CLT 26.5 ships a libPackageDescription
# that exports no Package symbols, so even `swift package init`'s own template
# fails to build. Driving the compiler ourselves also removes the last reason
# anyone would need Xcode installed.
#
#   make deps      vendor SwiftTerm at a pinned tag
#   make guest     fetch the prebuilt kernel + rootfs (CI-built)
#   make           build + bundle a runnable cs-OS.app in dist/
#   make run       build and launch
#   make archive   tarball + SHA256 for release
#   make clean

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Force the Command Line Tools toolchain. Without this, /usr/bin/swiftc shims
# to Xcode and dies on an unaccepted licence — which would need sudo to fix.
export DEVELOPER_DIR := /Library/Developer/CommandLineTools

VERSION     ?= 0.1.0
BUILD       ?= $(shell date +%Y%m%d%H%M)
DEPLOY_TGT  ?= 14.0
# Universal by default: the macOS 14 floor exists to serve Intel machines.
ARCHS       ?= arm64 x86_64

APP_NAME    := cs-OS
BINARY      := csos
BUNDLE_ID   := com.chopstickshq.csos

ROOT        := $(shell pwd)
BUILD_DIR   := $(ROOT)/.build
DIST        := $(ROOT)/dist
APP         := $(DIST)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
VENDOR      := $(ROOT)/third_party
GUEST_DIR   := $(ROOT)/guest/dist

SWIFTTERM_REPO := https://github.com/migueldeicaza/SwiftTerm.git
SWIFTTERM_TAG  := v1.18.0
SWIFTTERM_SRC  := $(VENDOR)/SwiftTerm

SDK         := $(shell xcrun --show-sdk-path)
SOURCES     := $(shell find $(ROOT)/Sources/csos -name '*.swift')
ARTIFACT    := $(APP_NAME)-$(VERSION)-macos-universal.tar.gz

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
	@[ -d "$(DEVELOPER_DIR)" ] || { \
	  printf "\033[31merror:\033[0m Command Line Tools not found.\n"; \
	  printf "  Run: xcode-select --install\n"; exit 1; }
	@xcrun --show-sdk-path >/dev/null 2>&1 || { \
	  printf "\033[31merror:\033[0m CLT toolchain is not usable.\n"; exit 1; }
	@[ "$$(uname -s)" = "Darwin" ] || { \
	  printf "\033[31merror:\033[0m macOS only.\n"; exit 1; }

# ---------------------------------------------------------------- deps

$(SWIFTTERM_SRC)/Package.swift:
	$(call log,"vendoring SwiftTerm $(SWIFTTERM_TAG)")
	@mkdir -p $(VENDOR)
	@git clone -q --depth 1 -b $(SWIFTTERM_TAG) $(SWIFTTERM_REPO) $(SWIFTTERM_SRC)

.PHONY: deps
deps: $(SWIFTTERM_SRC)/Package.swift

# ---------------------------------------------------------------- guest

# The kernel and rootfs are cross-built on Linux in CI (see
# .github/workflows/guest.yml) and published as release assets. Building them
# here would mean a Linux toolchain on macOS, i.e. Docker, i.e. a huge
# privileged dependency — exactly what this project avoids.
.PHONY: guest
guest:
	@bash scripts/fetch-guest.sh

# ---------------------------------------------------------------- compile

# Per-arch: SwiftTerm static lib, then the app, then lipo them together.
#
# A shell loop rather than $(foreach) over a `define`: foreach flattens the
# macro onto one line, which splices the progress `printf` into the middle of
# the swiftc invocation.
.PHONY: build
build: preflight deps
	@for a in $(ARCHS); do \
	  printf "$(CYAN)==>$(RESET) compiling SwiftTerm ($$a)\n"; \
	  mkdir -p $(BUILD_DIR)/$$a; \
	  swiftc -module-name SwiftTerm \
	    -emit-module -emit-module-path $(BUILD_DIR)/$$a/SwiftTerm.swiftmodule \
	    -emit-library -static -o $(BUILD_DIR)/$$a/libSwiftTerm.a \
	    -target $$a-apple-macos$(DEPLOY_TGT) -sdk $(SDK) -O -wmo -swift-version 5 \
	    $$(find $(SWIFTTERM_SRC)/Sources/SwiftTerm -name '*.swift' \
	         -not -path '*/Documentation.docc/*'); \
	  printf "$(CYAN)==>$(RESET) compiling cs-OS ($$a)\n"; \
	  swiftc -module-name csos -o $(BUILD_DIR)/$$a/$(BINARY) \
	    -target $$a-apple-macos$(DEPLOY_TGT) -sdk $(SDK) -O -wmo -swift-version 5 \
	    -I $(BUILD_DIR)/$$a -L $(BUILD_DIR)/$$a -lSwiftTerm \
	    -framework Virtualization \
	    $(SOURCES); \
	done
	$(call log,"lipo -> universal")
	@mkdir -p $(BUILD_DIR)
	@lipo -create $(foreach a,$(ARCHS),$(BUILD_DIR)/$(a)/$(BINARY)) \
	   -output $(BUILD_DIR)/$(BINARY)
	@lipo -info $(BUILD_DIR)/$(BINARY)

# ---------------------------------------------------------------- bundle

.PHONY: bundle
bundle: build
	$(call log,"assembling $(APP_NAME).app")
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(BUILD_DIR)/$(BINARY) $(CONTENTS)/MacOS/$(BINARY)
	@sed -e 's/__VERSION__/$(VERSION)/g' -e 's/__BUILD__/$(BUILD)/g' \
	   Resources/Info.plist > $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@if [ -d $(GUEST_DIR) ]; then \
	   cp -R $(GUEST_DIR) $(CONTENTS)/Resources/guest; \
	 else \
	   printf "\033[33mwarn:\033[0m no guest image — run 'make guest'. The app will build but not boot.\n"; \
	 fi
	$(call log,"ad-hoc signing with virtualization entitlement")
	@codesign --force --sign - \
	  --entitlements Resources/csos-microvm.entitlements \
	  --options runtime \
	  --timestamp=none \
	  $(APP)
	@codesign --verify --verbose=1 $(APP) 2>&1 | sed 's/^/    /'
	$(call log,"built $(APP)")

.PHONY: run
run: bundle
	@open $(APP)

# ---------------------------------------------------------------- release

.PHONY: archive
archive: bundle
	$(call log,"archiving $(ARTIFACT)")
	@cd $(DIST) && tar -czf $(ARTIFACT) $(APP_NAME).app
	@cd $(DIST) && shasum -a 256 $(ARTIFACT) | tee $(ARTIFACT).sha256
	@ls -lh $(DIST)/$(ARTIFACT)

.PHONY: clean
clean:
	@rm -rf $(BUILD_DIR) $(DIST)/$(APP_NAME).app $(DIST)/*.tar.gz $(DIST)/*.sha256

.PHONY: distclean
distclean: clean
	@rm -rf $(VENDOR) $(GUEST_DIR)

SHELL := /bin/zsh

PROJECT      := Gitwall.xcodeproj
SCHEME       := Gitwall
CONFIG       ?= Debug
DERIVED      := build/DerivedData
DESTINATION  := platform=macOS
PACKAGES     := $(wildcard Packages/*)
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Gitwall.app
ARCHIVE      := build/Gitwall.xcarchive
RELEASE_APP  := build/DerivedData-release/Build/Products/Release/Gitwall.app
INSTALL_APP  := $(HOME)/Applications/Gitwall.app
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help generate build run install register test test-packages test-app clean archive open

help:
	@echo "make generate       - generate Gitwall.xcodeproj from project.yml (XcodeGen)"
	@echo "make build          - build the app (Debug) into $(DERIVED)"
	@echo "make run            - build, register and launch the app"
	@echo "make install        - Release build into ~/Applications (the way to use the app daily)"
	@echo "make register       - point Launch Services and the widget service at the built app"
	@echo "make test           - swift test for all packages + xcodebuild test"
	@echo "make test-packages  - swift test for all packages"
	@echo "make archive        - Release archive for App Store / notarization"
	@echo "make clean          - remove generated project and build products"

$(PROJECT): project.yml
	xcodegen generate --spec project.yml --use-cache

generate: $(PROJECT)

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates build
	@$(MAKE) --no-print-directory register

# Duplicate bundles (archives, copies) can steal the Launch Services registration of the app,
# its URL scheme and the widget extension; the widget gallery then silently hides Gitwall.
# Only one copy may be registered: the Debug build (make run) or the installed Release build (make install).
register:
	@$(LSREGISTER) -u "$(INSTALL_APP)" >/dev/null 2>&1 || true
	@$(LSREGISTER) -u "$(ARCHIVE)/Products/Applications/Gitwall.app" >/dev/null 2>&1 || true
	@$(LSREGISTER) -f "$(APP)" >/dev/null 2>&1 || true
	@pkill -f GitwallWidget.appex >/dev/null 2>&1 || true
	@killall chronod >/dev/null 2>&1 || true

install: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(DESTINATION)' -derivedDataPath build/DerivedData-release \
		-allowProvisioningUpdates build
	@pkill -x Gitwall >/dev/null 2>&1 || true
	@pkill -f GitwallWidget.appex >/dev/null 2>&1 || true
	@$(LSREGISTER) -u "$(APP)" >/dev/null 2>&1 || true
	rm -rf "$(INSTALL_APP)"
	ditto "$(RELEASE_APP)" "$(INSTALL_APP)"
	@killall chronod >/dev/null 2>&1 || true
	open "$(INSTALL_APP)"

run: build
	@pkill -x Gitwall || true
	open "$(APP)"

test-packages:
	@for pkg in $(PACKAGES); do \
		echo "==> swift test ($$pkg)"; \
		swift test --package-path $$pkg || exit 1; \
	done

test-app: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(DESTINATION)' -derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates test

test: test-packages test-app

archive: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/$(DESTINATION)' -derivedDataPath build/DerivedData-archive \
		-archivePath $(ARCHIVE) -allowProvisioningUpdates archive
	@$(LSREGISTER) -u "$(ARCHIVE)/Products/Applications/Gitwall.app" >/dev/null 2>&1 || true
	@$(MAKE) --no-print-directory register

open: generate
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) build
	@for pkg in $(PACKAGES); do rm -rf $$pkg/.build; done

SHELL := /bin/zsh

PROJECT      := Gitwall.xcodeproj
SCHEME       := Gitwall
CONFIG       ?= Debug
DERIVED      := build/DerivedData
DESTINATION  := platform=macOS
# Directories that actually hold a package; Packages/ also contains documentation.
PACKAGES     := $(patsubst %/Package.swift,%,$(wildcard Packages/*/Package.swift))
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Gitwall.app
ARCHIVE      := build/Gitwall.xcarchive
VERSION      := $(shell awk '/MARKETING_VERSION:/ {print $$2; exit}' project.yml)
RELEASE_APP  := build/DerivedData-release/Build/Products/Release/Gitwall.app
INSTALL_APP  := $(HOME)/Applications/Gitwall.app
LSREGISTER   := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: help generate build run install register test test-packages test-app clean archive release open

help:
	@echo "make generate       - generate Gitwall.xcodeproj from project.yml (XcodeGen)"
	@echo "make build          - build the app (Debug) into $(DERIVED)"
	@echo "make run            - build, register and launch the app"
	@echo "make install        - Release build into ~/Applications (the way to use the app daily)"
	@echo "make register       - point Launch Services and the widget service at the built app"
	@echo "make test           - swift test for all packages + xcodebuild test"
	@echo "make test-packages  - swift test for all packages"
	@echo "make archive        - Release archive for App Store / notarization"
	@echo "make release        - notarized Developer ID build + zip for GitHub Releases"
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

# Developer ID build for direct download: archive, notarize, staple, zip, publish. Needs the App Store Connect
# API key in the environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH) and a Developer ID certificate in the
# login keychain; see docs/RELEASING.md.
release: archive
	@test -n "$(ASC_KEY_ID)" || { echo "set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH"; exit 1; }
	rm -rf build/export/developer-id
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist Config/ExportOptions-developer-id.plist \
		-exportPath build/export/developer-id -allowProvisioningUpdates \
		-authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID "$(ASC_KEY_ID)" -authenticationKeyIssuerID "$(ASC_ISSUER_ID)"
	cd build/export/developer-id && \
		ditto -c -k --keepParent Gitwall.app Gitwall-$(VERSION).zip && \
		xcrun notarytool submit Gitwall-$(VERSION).zip --key "$(ASC_KEY_PATH)" --key-id "$(ASC_KEY_ID)" --issuer "$(ASC_ISSUER_ID)" --wait && \
		xcrun stapler staple Gitwall.app && \
		rm Gitwall-$(VERSION).zip && \
		ditto -c -k --keepParent Gitwall.app Gitwall-$(VERSION).zip && \
		shasum -a 256 Gitwall-$(VERSION).zip > Gitwall-$(VERSION).zip.sha256 && \
		spctl -a -vv -t exec Gitwall.app
	@echo "Ready: build/export/developer-id/Gitwall-$(VERSION).zip"
	@echo "Publish with: gh release create v$(VERSION) build/export/developer-id/Gitwall-$(VERSION).zip build/export/developer-id/Gitwall-$(VERSION).zip.sha256 --title \"Gitwall $(VERSION)\" --generate-notes"

open: generate
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) build
	@for pkg in $(PACKAGES); do rm -rf $$pkg/.build; done

SHELL := /bin/zsh

PROJECT      := Gitwall.xcodeproj
SCHEME       := Gitwall
CONFIG       ?= Debug
DERIVED      := build/DerivedData
DESTINATION  := platform=macOS
PACKAGES     := $(wildcard Packages/*)
APP          := $(DERIVED)/Build/Products/$(CONFIG)/Gitwall.app

.PHONY: help generate build run test test-packages test-app clean archive open

help:
	@echo "make generate       - generate Gitwall.xcodeproj from project.yml (XcodeGen)"
	@echo "make build          - build the app (Debug) into $(DERIVED)"
	@echo "make run            - build and launch the app"
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
		-destination 'generic/$(DESTINATION)' -derivedDataPath $(DERIVED) \
		-archivePath build/Gitwall.xcarchive -allowProvisioningUpdates archive

open: generate
	open $(PROJECT)

clean:
	rm -rf $(PROJECT) build
	@for pkg in $(PACKAGES); do rm -rf $$pkg/.build; done

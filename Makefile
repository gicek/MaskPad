SHELL := /bin/zsh
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules --no-print-directory

# Xcode, even when xcode-select points at the Command Line Tools (Scripts/release.sh uses the same rule).
# Set DEVELOPER_DIR to pick another Xcode.
ifndef DEVELOPER_DIR
XCODE_SELECTED := $(shell xcode-select -p 2>/dev/null)
DEVELOPER_DIR := $(or $(filter-out %/CommandLineTools,$(XCODE_SELECTED)),/Applications/Xcode.app/Contents/Developer)
endif
export DEVELOPER_DIR

# build/ layout: debug/ holds the Debug app, release/ the signed app and zip, dist/ the notarized DMG,
# zip and appcast (see Scripts/release.sh). DerivedData, SourcePackages and intermediates are build
# intermediates; anything else in build/ is left alone.
PROJECT := MaskPad.xcodeproj
SCHEME := MaskPad
DERIVED_DATA := build/DerivedData
# Swift packages are fetched once into build/SourcePackages and shared with Scripts/release.sh.
SOURCE_PACKAGES := build/SourcePackages
DEBUG_APP := build/debug/MaskPad.app
# Builds are quiet by default; for full output: make build XCODEBUILD_FLAGS=
# Tests are not quiet, because -quiet hides the ** TEST SUCCEEDED / FAILED ** line.
XCODEBUILD_FLAGS ?= -quiet
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	-destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED_DATA) \
	-clonedSourcePackagesDirPath $(SOURCE_PACKAGES)
# Python scripts import each other; keep __pycache__ out of Scripts/.
PYTHON := PYTHONDONTWRITEBYTECODE=1 python3

.PHONY: help project open build run test strings check-strings check icons bump release dist publish \
	verify-release go-live clean distclean

help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } /^##@/ { printf "\n%s\n", substr($$0, 5) } \
		/^[a-z-]+:.*## / { printf "  %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Build (command line only; each target generates the Xcode project itself)

build: project ## Build the Debug app into build/debug
	$(XCODEBUILD) $(XCODEBUILD_FLAGS) build
	@rm -rf $(DEBUG_APP) && mkdir -p $(dir $(DEBUG_APP))
	@ditto $(DERIVED_DATA)/Build/Products/Debug/MaskPad.app $(DEBUG_APP)
	@echo "==> $(DEBUG_APP)"

run: build ## Build and launch the Debug app, quitting a running copy first
	@pkill -x MaskPad || true
	open $(DEBUG_APP)

test: project ## Run the unit tests
	$(XCODEBUILD) test

strings: ## Regenerate the string catalog from Scripts/translations.py
	$(PYTHON) Scripts/build_strings.py

check-strings: ## Check that the string catalog is complete and up to date
	$(PYTHON) Scripts/build_strings.py --check

check: check-strings test ## Run all checks (string catalog and unit tests)

icons: ## Regenerate the app, menu bar and DMG art from design/ (needs Node and uv)
	Scripts/build_icons.sh

##@ Xcode (only for editing and debugging in the IDE)

# The .xcodeproj is generated from project.yml and not committed. Regenerating is cheap, and it picks up
# added or removed source files, so every target that builds depends on this one.
project: ## Generate MaskPad.xcodeproj from project.yml
	@test -x "$(DEVELOPER_DIR)/usr/bin/xcodebuild" \
		|| { echo "error: Xcode not found at $(DEVELOPER_DIR); install it or set DEVELOPER_DIR." >&2; exit 1; }
	@command -v xcodegen >/dev/null || { echo "error: xcodegen is missing; brew install xcodegen" >&2; exit 1; }
	@xcodegen generate --quiet

open: project ## Generate the project and open it in Xcode
	open $(PROJECT)

##@ Release (Developer ID; see README for the full flow)

bump: ## Next build number, and VERSION=x.y.z if given; creates the release notes template
	Scripts/bump_version.sh $(VERSION)

release: check ## make check, then a signed, not notarized app and zip into build/release
	Scripts/release.sh release

dist: check ## Release, then notarized DMG, zip and appcast into build/dist
	Scripts/release.sh dist

publish: check ## Dist, then a draft GitHub release from build/dist (not live yet)
	Scripts/release.sh publish

verify-release: ## Download and check the GitHub release for this version (VERSION=x.y.z for another)
	Scripts/github_release.sh verify $(VERSION)

go-live: ## Verify, then publish the draft so Sparkle offers the update
	Scripts/github_release.sh go-live $(VERSION)

##@ Cleaning

# Only what builds produce: build/ may also hold local files such as a key backup. Builds started in Xcode
# go to Xcode's default DerivedData folder instead; xcodebuild reports which one belongs to this project,
# and it is removed only if it is under Xcode's DerivedData. The query itself creates that folder, so it
# runs only when a MaskPad-* folder already exists. App copies in what is removed are first unregistered
# from Launch Services, so the app launcher doesn't keep pointing at them instead of the installed app.
XCODE_DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData
clean: ## Remove build output, fetched packages and Xcode's DerivedData for this project
	@Scripts/unregister_apps.sh build
	rm -rf build/debug build/release build/dist build/intermediates $(DERIVED_DATA) $(SOURCE_PACKAGES)
	@[[ -d $(PROJECT) && -n $$(print -l $(XCODE_DERIVED_DATA)/MaskPad-*(N/)) ]] || exit 0; \
	products=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -showBuildSettings 2>/dev/null \
		| awk '$$1 == "BUILD_ROOT" { print $$3; exit }'); \
	dir=$${products%/Build/Products}; \
	if [[ $$dir == $(XCODE_DERIVED_DATA)/MaskPad-* && -d $$dir ]]; then \
		Scripts/unregister_apps.sh "$$dir"; echo "rm -rf $$dir"; rm -rf "$$dir"; \
	fi

distclean: clean ## Clean, then remove the generated MaskPad.xcodeproj (back to a fresh checkout)
	rm -rf $(PROJECT)

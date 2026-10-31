version ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
arch ?= $(shell uname -m)
.DEFAULT_GOAL := build

.PHONY: build build-darwin app bundle-darwin dmg test test-signing test-credentials test-icons start run install setup-signing clean

ifeq ($(OS),Windows_NT)
host_os := Windows
else
host_os := $(shell uname -s)
endif

ifeq ($(host_os),Darwin)
INSTALL_DIR ?= /Applications
install: app
	swift scripts/install-macos.swift "dist/GitHub Notify.app" "$(INSTALL_DIR)"
else
install:
	$(MAKE) -C legacy version="$(version)" install
endif

build:
	swift build -c release --arch $(arch)

build-darwin: build

test:
	swift test

test-signing:
	python3 scripts/test-signing.py

test-credentials:
	python3 scripts/test-credentials.py

test-icons:
	mkdir -p .build/icon-tests
	swiftc -swift-version 6 -warnings-as-errors Sources/GitHubNotify/ApplicationIcon.swift scripts/test-app-icon.swift -o .build/icon-tests/test-app-icon
	.build/icon-tests/test-app-icon assets/icon.png .build/icon-tests/rendered

app:
	VERSION="$(version)" ARCH="$(arch)" /bin/bash scripts/bundle.sh

setup-signing:
	/bin/bash scripts/setup-signing.sh

bundle-darwin: dmg

dmg: app
	/usr/bin/hdiutil create -volname "GitHub Notify" -srcfolder "dist/staging" -ov -format UDZO "dist/github-notify_$(version)_macos_$(arch).dmg"
	cd dist && shasum -a 256 "github-notify_$(version)_macos_$(arch).dmg" > "github-notify_$(version)_macos_$(arch).dmg.sha256"

start: run

run: app
	open "dist/GitHub Notify.app"

clean:
	swift package clean

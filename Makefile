version ?= 0.0.0
arch ?= $(shell uname -m)
.DEFAULT_GOAL := build

.PHONY: build build-darwin app bundle-darwin dmg test start run install clean

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

app:
	VERSION="$(version)" ARCH="$(arch)" /bin/bash scripts/bundle.sh

bundle-darwin: dmg

dmg: app
	/usr/bin/hdiutil create -volname "GitHub Notify" -srcfolder "dist/staging" -ov -format UDZO "dist/github-notify_$(version)_macos_$(arch).dmg"
	cd dist && shasum -a 256 "github-notify_$(version)_macos_$(arch).dmg" > "github-notify_$(version)_macos_$(arch).dmg.sha256"

start: run

run: app
	open "dist/GitHub Notify.app"

clean:
	swift package clean

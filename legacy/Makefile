version ?= 0.0.0-SNAPSHOT
arch ?= amd64
.DEFAULT_GOAL := build-win

.PHONY: build-win build-linux test format generate bundle-linux install

native_os := $(shell go env GOOS)

ifeq ($(native_os),windows)
install:
	CGO_ENABLED=0 go install -ldflags "-s -w -X main.version=$(version) -H=windowsgui" .
else ifeq ($(native_os),linux)
install:
	CGO_ENABLED=1 go install -ldflags "-s -w -X main.version=$(version)" .
else
install:
	@echo "The Go app supports Windows and Linux only. Run make install at the repository root for macOS."
	@exit 1
endif

build-win:
	GOOS=windows GOARCH=$(arch) CGO_ENABLED=0 go build -ldflags "-s -w -X main.version=$(version) -H=windowsgui" -o bin/windows/github-notify.exe .

build-linux:
	GOOS=linux GOARCH=$(arch) CGO_ENABLED=1 go build -ldflags "-s -w -X main.version=$(version)" -o bin/linux/github-notify .

test:
	go test ./...

format:
	gofmt -w .

generate:
	/bin/bash icon/gen.sh

bundle-linux:
	docker build --platform linux/$(arch) -t github-notify-legacy .
	docker run --rm --platform linux/$(arch) -v "$(CURDIR)/bin:/build/bin" github-notify-legacy make version=$(version) arch=$(arch) build-linux

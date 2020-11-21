# GitHub Notify

> Simple tray application for getting GitHub notifications

![Build Status](https://github.com/koltyakov/github-notify/workflows/Build/badge.svg?branch=master)
[![Go Report Card](https://goreportcard.com/badge/github.com/koltyakov/github-notify)](https://goreportcard.com/report/github.com/koltyakov/github-notify)
[![License](https://img.shields.io/github/license/koltyakov/github-notify.svg)](https://github.com/koltyakov/github-notify/blob/master/LICENSE)

| | |
|-|-|
| macOS | ![systray_macOS](./assets/systray_macOS.png) |
| Windows | ![systray_Windows](./assets/systray_Windows.png) |
| Linux | ![systray_Linux](./assets/systray_Linux.png) |

**Scenario**

- I'm a maintainer or active watcher of some repositories at GitHub
- I want to react to issues quickly
- I prefer a status based humble info rather than agressive email or pop-ups

## Demo

![demo](./assets/demo.gif)

## Install/run

### macOS

Install from [.dmg](https://github.com/koltyakov/github-notify/releases) and run as any other application.

### Windows

Just run `github-notify.exe`.

### Linux

```bash
go get github.com/koltyakov/github-notify
nohup github-notify >/dev/null 2>&1 &
```

## Local development

### Build command

```bash
make build-darwin # can be build in macOS only
make build-win
make build-linux # can be build Linux only
```

**Prerequisites**

The project uses these major dependencies and inherits their prerequisites:

- [systray](https://github.com/getlantern/systray)
- [Lorca](https://github.com/zserge/lorca)

Due to the nature of `systray` package, the build for macOS can be done in a Mac, a linux build only on a Linux machine. Platform specific prerequisites are required.

Windows cross build can be done from any platform.

### Start command

```bash
make start
```

### App bundle (for macOS)

```bash
make bundle-darwin
```

As a result, the `.dmg` installer image should be found in `./dist` folder.
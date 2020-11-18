package main

import (
	"runtime"

	"github.com/getlantern/systray"
	"github.com/koltyakov/github-notify/icon"
)

// Tray state cache
var tray = &struct {
	Icon    string
	Title   string
	Tooltip string
}{}

// setIcon sets icon in systray
// it also wraps systray.SetIcon and ignores macOS as currently systray.SetIcon causes memory leaks in macOS
// see more https://github.com/getlantern/systray/issues/135
func setIcon(i *icon.Icon) {
	// Ignore changing icon in macOS until systray issue is fixed
	if tray.Icon != "" && runtime.GOOS == "darwin" {
		return
	}

	// Do nothing if current icon is the same
	if tray.Icon != i.Name {
		tray.Icon = i.Name
		systray.SetIcon(i.Data)
	}
}

// setTooltip sets title in systray
func setTitle(title string) {
	// In Ubuntu, title update after 2nd time didn't work
	// disabling titles completely for Linux for now
	// ToDo: investigate
	if runtime.GOOS == "linux" {
		// systray.SetTitle("")
		return
	}

	// Do nothing when a value didn't mutated
	if tray.Title != title {
		tray.Title = title
		systray.SetTitle(title)
	}
}

// setTooltip sets tooltip in systray
func setTooltip(tooltip string) {
	// Do nothing when a value didn't mutated
	if tray.Tooltip != tooltip {
		tray.Tooltip = tooltip
		systray.SetTooltip(tooltip)
	}
}

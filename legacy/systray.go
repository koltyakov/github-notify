//go:build windows || linux
// +build windows linux

package main

import (
	"runtime"

	"github.com/getlantern/systray"
	"github.com/koltyakov/github-notify/icon"
)

// Tray helper struct
type Tray struct {
	Icon    string
	Title   string
	Tooltip string
}

// SetIcon sets icon in systray
// It avoids redundant icon updates.
func (t *Tray) SetIcon(i *icon.Icon) {
	// Do nothing if current icon is the same
	if t.Icon != i.Name {
		t.Icon = i.Name
		systray.SetIcon(i.Data)
	}
}

// SetTitle sets title in systray
func (t *Tray) SetTitle(title string) {
	// In Ubuntu, title update after 2nd time didn't work
	// disabling titles completely for Linux for now
	// ToDo: investigate
	if runtime.GOOS == "linux" {
		// systray.SetTitle("")
		return
	}

	// Do nothing when a value didn't mutated
	if t.Title != title {
		t.Title = title
		systray.SetTitle(title)
	}
}

// SetTooltip sets tooltip in systray
func (t *Tray) SetTooltip(tooltip string) {
	// Do nothing when a value didn't mutated
	if t.Tooltip != tooltip {
		t.Tooltip = tooltip
		systray.SetTooltip(tooltip)
	}
}

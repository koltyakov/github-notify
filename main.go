package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/getlantern/systray"

	"github.com/koltyakov/github-notify/icon"
)

var appname = "github-notify"
var running = true
var notiCnt = -1

// Init systray applications
func main() {
	onExit := func() { running = false }
	systray.Run(onReady, onExit)
}

func onReady() {
	menu := map[string]*systray.MenuItem{}

	systray.SetIcon(icon.Base)
	systray.SetTitle("Loading...")

	cnfg, err := getSettings()
	if err != nil {
		onError(err)
	}

	// Menu items
	menu["notifications"] = systray.AddMenuItem("Notifications", "")
	menu["getToken"] = systray.AddMenuItem("Get Token", "")
	menu["settings"] = systray.AddMenuItem("Settings", "")
	systray.AddSeparator()
	menu["about"] = systray.AddMenuItem("About", "About GitHub Notify")
	menu["quit"] = systray.AddMenuItem("Quit", "Quit GitHub Notify")
	// Menu items

	// Menu actions
	go func() {
		for {
			select {
			case <-menu["notifications"].ClickedCh:
				if err := openBrowser("https://github.com/notifications?query=is%3Aunread"); err != nil {
					fmt.Printf("error opening browser: %s\n", err)
				}
			case <-menu["getToken"].ClickedCh:
				if err := openBrowser("https://github.com/settings/tokens/new"); err != nil {
					fmt.Printf("error opening browser: %s\n", err)
				}
			case <-menu["settings"].ClickedCh:
				if newCnfg, upd := openSettings(); upd {
					cnfg = newCnfg
					menu["getToken"].Hide()
					if cnfg.GithubToken == "" {
						onEmptyToken(menu)
					}
					// check updates immediately after settings change
					_ = run(&cnfg, menu, 0)
				}
			case <-menu["about"].ClickedCh:
				if err := openBrowser("https://github.com/koltyakov/github-notify"); err != nil {
					fmt.Printf("error opening browser: %s\n", err)
				}
			case <-menu["quit"].ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	// Show get token item only when no token is provided
	menu["getToken"].Hide()
	if cnfg.GithubToken == "" {
		onEmptyToken(menu)
	}

	// Infinite service loop
	for running {
		<-time.After(
			run(&cnfg, menu, 1*time.Second),
		)
	}
}

// run executes notification checks logic
func run(cnfg *settings, menu map[string]*systray.MenuItem, timeout time.Duration) time.Duration {
	// Get notification only when having access token
	if cnfg.GithubToken != "" {
		// Request GitHub API
		num, err := getNotifications(cnfg.GithubToken)
		if err != nil {
			if onError(err); strings.Contains(err.Error(), "401 Bad credentials") {
				menu["getToken"].Show()
				cnfg.GithubToken = ""
				return 0 // continue
			}
		} else {
			onNotification(num)
		}

		// Timeout duration from settings
		d, err := time.ParseDuration(cnfg.UpdateFrequency)
		if err != nil {
			fmt.Printf("error parsing update frequency: %s\n", err)
			d = 30 * time.Second
		}
		timeout = d
	}
	return timeout
}

// onError system tray menu on error event handler
func onError(err error) {
	fmt.Printf("error: %s", err)
	systray.SetTitle("Error")
	systray.SetTooltip(fmt.Sprintf("Error: %s", err))
	systray.SetIcon(icon.Err)
}

// onEmptyToken system tray menu on empty token event handler
func onEmptyToken(menu map[string]*systray.MenuItem) {
	menu["getToken"].Show()
	systray.SetTitle("No Token")
	systray.SetTooltip("Error: no access token has been provided")
	systray.SetIcon(icon.Err)
}

// onNotification system tray menu on notifications change event handler
func onNotification(num int) {
	if notiCnt != num {
		systray.SetTitle(fmt.Sprintf("%d", num))
		systray.SetTooltip("")
		if num == 0 {
			systray.SetIcon(icon.Base)
			return
		}
		systray.SetIcon(icon.Noti)
	}
	notiCnt = num
}

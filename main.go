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

	systray.SetIcon(icon.Generic)
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
				openBrowser("https://github.com/notifications?query=is%3Aunread")
			case <-menu["getToken"].ClickedCh:
				openBrowser("https://github.com/settings/tokens/new")
			case <-menu["settings"].ClickedCh:
				if newCnfg, upd := openSettings(); upd {
					cnfg = newCnfg
					menu["getToken"].Hide()
					if cnfg.GithubToken == "" {
						onEmptyToken(menu)
					}
				}
			case <-menu["about"].ClickedCh:
				openBrowser("https://github.com/koltyakov/github-notify")
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

	for running {
		timeout := 1 * time.Second

		// Get notification only when having access token
		if cnfg.GithubToken != "" {
			// Request GitHub API
			num, err := getNotifications(cnfg.GithubToken)
			if err != nil {
				if onError(err); strings.Contains(err.Error(), "401 Bad credentials") {
					menu["getToken"].Show()
					cnfg.GithubToken = ""
					continue
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

		<-time.After(timeout)
	}
}

func onError(err error) {
	fmt.Printf("error: %s", err)
	systray.SetTitle("Error")
	systray.SetTooltip(fmt.Sprintf("Error: %s", err))
	systray.SetIcon(icon.Error)
}

func onEmptyToken(menu map[string]*systray.MenuItem) {
	menu["getToken"].Show()
	systray.SetTitle("No Token")
	systray.SetTooltip("Error: no access token has been provided")
	systray.SetIcon(icon.Error)
}

func onNotification(num int) {
	if notiCnt != num {
		systray.SetTitle(fmt.Sprintf("%d", num))
		systray.SetTooltip("")
		if num == 0 {
			systray.SetIcon(icon.Generic)
			return
		}
		systray.SetIcon(icon.Noti)
	}
	notiCnt = num
}

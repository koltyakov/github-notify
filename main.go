package main

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/getlantern/systray"

	"github.com/koltyakov/github-notify/icon"
)

var appname = "github-notify"
var running = true

var cnfg = &settings{}
var menu = map[string]*systray.MenuItem{}

// Init systray applications
func main() {
	onExit := func() { running = false }
	systray.Run(onReady, onExit)
}

func onReady() {
	setIcon(icon.Base)
	setTitle("Loading...")

	c, err := getSettings()
	if err != nil {
		onError(err)
	}
	cnfg = &c

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
					cnfg = &newCnfg
					menu["getToken"].Hide()
					if cnfg.GithubToken == "" {
						onEmptyToken()
					}
					// check updates immediately after settings change
					go func() { _ = run(0) }()
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
		onEmptyToken()
	}

	// Infinite service loop
	for running {
		timeout := time.Duration(1 * time.Second)
		var wg sync.WaitGroup
		wg.Add(1)
		// Run in separate goroutine
		go func() {
			defer wg.Done()
			timeout = run(timeout)
		}()
		wg.Wait()
		<-time.After(timeout)
	}
}

// run executes notification checks logic
func run(timeout time.Duration) time.Duration {
	// Get notification only when having access token
	if cnfg.GithubToken != "" {
		// Request GitHub API
		notifications, err := getNotifications(cnfg.GithubToken)
		if err != nil {
			if onError(err); strings.Contains(err.Error(), "401 Bad credentials") {
				menu["getToken"].Show()
				cnfg.GithubToken = ""
				return 0 // continue
			}
		} else {
			reposEvents := map[string]int{}
			for _, n := range notifications {
				reposEvents[*n.Repository.FullName] = reposEvents[*n.Repository.FullName] + 1
			}
			onNotification(len(notifications), reposEvents)
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
	setTitle("Error")
	setTooltip(fmt.Sprintf("Error: %s", err))
	setIcon(icon.Err)
}

// onEmptyToken system tray menu on empty token event handler
func onEmptyToken() {
	menu["getToken"].Show()
	setTitle("No Token")
	setTooltip("Error: no access token has been provided")
	setIcon(icon.Err)
}

// onNotification system tray menu on notifications change event handler
func onNotification(num int, repos map[string]int) {
	if len(repos) > 1 && num != len(repos) {
		// Shows additional counter for the number or repositories with notifications after "/" separator
		setTitle(fmt.Sprintf("%d/%d", num, len(repos)))
	} else {
		// Shows only overall notifications counter
		setTitle(fmt.Sprintf("%d", num))
	}

	if num == 0 {
		// No unread items
		setIcon(icon.Base)
		setTooltip("No unread notifications")
	} else {
		// Tooltip contains list of repositories with notifications counters
		tooltip := ""
		for repo, cnt := range repos {
			tooltip = fmt.Sprintf("%s%s (%d)\n", tooltip, repo, cnt)
		}
		setIcon(icon.Noti)
		setTooltip(strings.Trim(tooltip, "\n"))
	}
}

package main

import (
	"fmt"
	"runtime"
	"strings"
	"time"

	"github.com/getlantern/systray"

	"github.com/koltyakov/github-notify/icon"
)

var appname = "github-notify"

var cnfg = &settings{}
var menu = map[string]*systray.MenuItem{}

// Init systray applications
func main() {
	onExit := func() {}
	systray.Run(onReady, onExit)
}

// onReady bootstraps system tray menu logic
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

	// Menu actions
	go menuActions()

	// Show get token item only when no token is provided
	menu["getToken"].Hide()
	if cnfg.GithubToken == "" {
		onEmptyToken()
	}

	// Infinite service loop
	for {
		<-time.After(run(1 * time.Second))
	}
}

// menuActions watch to menu actions channels
// must be started in a goroutine, otherwise blocks the loop
func menuActions() {
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
			newCnfg, upd, err := openSettings()
			if err != nil {
				onError(err)
			}
			if upd && err == nil {
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
	fmt.Printf("error: %s\n", err)
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
	// Default overall notifications counter
	title := fmt.Sprintf("%d", num)
	// Additional counter for the number of repositories
	if len(repos) > 1 && num != len(repos) {
		title = fmt.Sprintf("%d/%d", num, len(repos))
	}
	setTitle(title)

	// Show counter in menu for Linux
	if runtime.GOOS == "linux" {
		menu["notifications"].SetTitle(fmt.Sprintf("Notifications (%s)", title))
	}

	// No unread items
	if num == 0 {
		setIcon(icon.Base)
		setTooltip("No unread notifications")
		return
	}

	// Windows doesn't support long tooltip messages
	if runtime.GOOS == "windows" {
		tooltip := fmt.Sprintf("Notifications: %d", num)
		if len(repos) > 1 && num != len(repos) {
			tooltip = fmt.Sprintf("%s\nRepositories: %d", tooltip, len(repos))
		}
		setIcon(icon.Noti)
		setTooltip(tooltip)
		return
	}

	// Tooltip contains list of repositories with notifications counters
	tooltip := ""
	for repo, cnt := range repos {
		tooltip = fmt.Sprintf("%s%s (%d)\n", tooltip, repo, cnt)
	}
	setIcon(icon.Noti)
	setTooltip(strings.Trim(tooltip, "\n"))
}

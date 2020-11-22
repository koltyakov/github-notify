package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/getlantern/systray"

	"github.com/koltyakov/github-notify/icon"
)

var (
	appname = "github-notify"
	version string
)

var cnfg = &settings{}
var menu = map[string]*systray.MenuItem{}
var appCtx, appCtxCancel = context.WithCancel(context.Background())

// Init systray applications
func main() {
	// Graceful shutdown signalling
	grace := make(chan os.Signal, 1)
	signal.Notify(grace, os.Interrupt, syscall.SIGINT, syscall.SIGTERM)

	// Lock session to prevent multiple simultaneous application instances
	if err := lockSession(); err != nil {
		fmt.Printf("error: %s\n", err)
		return
	}
	defer unlockSession()

	// Systray exit handler
	onExit := func() {
		appCtxCancel()
	}

	// Graceful shutdown action
	go func() {
		<-grace
		systray.Quit()
	}()

	// Initiate systray application
	systray.Run(onReady, onExit)
}

// onReady bootstraps system tray menu logic
func onReady() {
	setIcon(icon.Base)
	setTitle("Loading...")

	// Get app settings
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
		<-time.After(run(1*time.Second, cnfg))
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
			if err := openBrowser("https://github.com/settings/tokens/new?scopes=notifications&description=GitHub%20Notify%20App"); err != nil {
				fmt.Printf("error opening browser: %s\n", err)
			}
		case <-menu["settings"].ClickedCh:
			openSettingsHandler()
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
func run(timeout time.Duration, cnfg *settings) time.Duration {
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
			onNotification(len(notifications), reposEvents, cnfg.FavoriteRepos)
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

// openSettingsHandler handler
func openSettingsHandler() {
	menu["settings"].Disable()
	go func() {
		newCnfg, upd, err := openSettings(appCtx)
		if err != nil {
			onError(err)
		}
		menu["settings"].Enable()
		if upd && err == nil {
			cnfg = &newCnfg
			menu["getToken"].Hide()
			if cnfg.GithubToken == "" {
				onEmptyToken()
			}
			// check updates immediately after settings change
			go func() { _ = run(0, cnfg) }()
		}
	}()
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

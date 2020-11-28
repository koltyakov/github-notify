package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"regexp"
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

var appConf = &settings{}
var menu = map[string]*systray.MenuItem{}
var appCtx, appCtxCancel = context.WithCancel(context.Background())
var tray = &Tray{} // Tray state cache
var ghClient *GitHubClient
var repoEvents map[string]int

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
	tray.SetIcon(icon.Base)
	tray.SetTitle("Loading...")

	// Get app settings
	c, err := getSettings()
	if err != nil {
		onError(err)
	}
	appConf = &c

	// Initiate GitHub client
	ghClient = NewGitHubClient(context.Background(), appConf.GithubToken)

	// Menu items
	menu["notifications"] = systray.AddMenuItem("Notifications", "Open notifications on GitHub")
	menu["markAsRead"] = systray.AddMenuItem("Mark as read", "Marks current notifications as read")
	menu["filter"] = systray.AddMenuItem("Filter mode", "") // "Notifications filter mode switch")
	menu["filter:all"] = menu["filter"].AddSubMenuItem("All notifications", "Show all notifications")
	menu["filter:favorite"] = menu["filter"].AddSubMenuItem("Favorite repos", "Show notification only from favorite repositories")
	menu["getToken"] = systray.AddMenuItem("Get Token", "Open token creation page")
	menu["settings"] = systray.AddMenuItem("Settings", "Open applications settings")
	systray.AddSeparator()
	menu["about"] = systray.AddMenuItem("About", "About GitHub Notify")
	menu["quit"] = systray.AddMenuItem("Quit", "Quit GitHub Notify")

	// Default states for menu items
	menu["markAsRead"].Disable()
	menu["getToken"].Hide()

	// Notification filters
	checkNotificationMode(appConf.FiltersMode)

	// Menu actions
	go menuActions()

	// Show get token item only when no token is provided
	if appConf.GithubToken == "" {
		onEmptyToken()
	}

	// Infinite service loop
	for {
		<-time.After(run(1*time.Second, appConf))
	}
}

// menuActions watch to menu actions channels
// must be started in a goroutine, otherwise blocks the loop
func menuActions() {
	for {
		select {
		case <-menu["notifications"].ClickedCh:
			onOpenLinkHandler("https://github.com/notifications?query=is%3Aunread")
		case <-menu["markAsRead"].ClickedCh:
			onMarkAsRead("")
		case <-menu["filter:all"].ClickedCh:
			onNotificationModeChange("all")
		case <-menu["filter:favorite"].ClickedCh:
			onNotificationModeChange("favorite")
		case <-menu["getToken"].ClickedCh:
			onOpenLinkHandler("https://github.com/settings/tokens/new?scopes=notifications&description=GitHub%20Notify%20App")
		case <-menu["settings"].ClickedCh:
			openSettingsHandler()
		case <-menu["about"].ClickedCh:
			onOpenLinkHandler("https://github.com/koltyakov/github-notify")
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
		notifications, err := ghClient.GetNotifications()
		if err != nil {
			if onError(err); strings.Contains(err.Error(), "401 Bad credentials") {
				menu["getToken"].Show()
				cnfg.GithubToken = ""
				return 0 // continue
			}
		} else {
			re := map[string]int{}
			for _, n := range notifications {
				re[*n.Repository.FullName] = re[*n.Repository.FullName] + 1
			}
			repoEvents = re
			onNotification(len(notifications), re, cnfg)
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
			appConf = &newCnfg
			ghClient.SetToken(appConf.GithubToken)
			menu["getToken"].Hide()
			if appConf.GithubToken == "" {
				onEmptyToken()
			}
			// check updates immediately after settings change
			go func() { _ = run(0, appConf) }()
		}
	}()
}

// onError system tray menu on error event handler
func onError(err error) {
	fmt.Printf("error: %s\n", err)
	tray.SetTitle("Error")
	tray.SetTooltip(fmt.Sprintf("Error: %s", err))
	tray.SetIcon(icon.Err)
}

// onEmptyToken system tray menu on empty token event handler
func onEmptyToken() {
	menu["getToken"].Show()
	tray.SetTitle("No Token")
	tray.SetTooltip("Error: no access token has been provided")
	tray.SetIcon(icon.Err)
}

// onNotificationModeChange notification mode (all, favorite) change handler
func onNotificationModeChange(mode string) {
	c, err := setFilterMode(mode)
	if err != nil {
		fmt.Printf("error: %s\n", err)
		return
	}
	appConf = &c
	checkNotificationMode(mode)
	go func() { _ = run(0, appConf) }()
}

// onMarkAsRead mark notifications as read handler
func onMarkAsRead(repo string) {
	if repo == "" {
		// Mark all repositories as read when a specific repo is not provided
		for rn := range repoEvents {
			markAsRead := true
			if appConf.FiltersMode == "favorite" {
				markAsRead = false
				for _, fr := range appConf.FavoriteRepos {
					if matched, _ := regexp.MatchString(fr, rn); matched {
						markAsRead = true
					}
				}
			}
			if markAsRead {
				if err := ghClient.MarkRepositoryNotificationsRead(rn); err != nil {
					fmt.Printf("error: %s\n", err)
				}
			}
		}
	} else {
		// Mark a specific repository events as read
		if err := ghClient.MarkRepositoryNotificationsRead(repo); err != nil {
			fmt.Printf("error: %s\n", err)
		}
	}
	go func() { _ = run(0, appConf) }()
}

// checkNotificationMode sets check mark to a notification mode item
// unchecks other selected modes
func checkNotificationMode(mode string) {
	for mKey, mItem := range menu {
		if strings.Index(mKey, "filter:") != -1 {
			if mKey == "filter:"+appConf.FiltersMode {
				mItem.Check()
				continue
			}
			mItem.Uncheck()
		}
	}
}

// onOpenLinkHandler on open link handler
func onOpenLinkHandler(url string) {
	if err := openBrowser(url); err != nil {
		fmt.Printf("error opening browser: %s\n", err)
	}
}

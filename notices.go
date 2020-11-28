package main

import (
	"fmt"
	"regexp"
	"runtime"
	"sort"
	"strings"

	"github.com/koltyakov/github-notify/icon"
)

/* Notifications events and handlers */

// onNotification system tray menu on notifications change event handler
func onNotification(num int, repos map[string]int, cnfg *settings) {
	// https://unicode.org/emoji/charts/full-emoji-list.html
	// some statuses text can be inplemented with using unicode emoji

	// Notification in favoutite repos
	favNum := favReposEvents(repos, cnfg)

	// Filter mode
	if cnfg.FiltersMode == "favorite" {
		num = favNum
	}

	// No unread items
	if num == 0 {
		tray.SetTitle("0")
		tray.SetIcon(icon.Base)
		tray.SetTooltip("No unread notifications")
		return
	}

	// Notifications icon
	if favNum > 0 {
		tray.SetIcon(icon.Warn)
	} else {
		tray.SetIcon(icon.Notice)
	}

	// Notifications title
	title := getNotificationsTitle(num, favNum, repos, cnfg)
	tray.SetTitle(title)

	// Notifications tooltip
	tooltip := getNotificationsTooltip(num, favNum, repos, cnfg)
	tray.SetTooltip(tooltip)

	// Show counter in menu for Linux
	if runtime.GOOS == "linux" {
		menu["notifications"].SetTitle(fmt.Sprintf("Notifications (%s)", title))
	}
}

// favReposEvents gets events notifications in favorite repositories
func favReposEvents(repos map[string]int, cnfg *settings) int {
	favNum := 0
	for repoName, eventsCnt := range repos {
		isFavorite := false
		for _, favRepo := range cnfg.FavoriteRepos {
			if matched, _ := regexp.MatchString(favRepo, repoName); matched {
				isFavorite = true
			}
		}
		if isFavorite {
			favNum += eventsCnt
		}
	}
	return favNum
}

// favRepoNotifications gets events notifications in favorite repositories
func favReposNoti(repos map[string]int, cnfg *settings) map[string]int {
	favRepos := map[string]int{}
	for repoName, eventsCnt := range repos {
		isFavorite := false
		for _, favRepo := range cnfg.FavoriteRepos {
			if matched, _ := regexp.MatchString(favRepo, repoName); matched {
				isFavorite = true
			}
		}
		if isFavorite {
			favRepos[repoName] = eventsCnt
		}
	}
	return favRepos
}

// getNotificationsTitle constructs title string with counters
func getNotificationsTitle(num int, favNum int, repos map[string]int, cnfg *settings) string {
	// Filter mode
	if cnfg.FiltersMode == "favorite" {
		num = favNum
		favNum = 0
		repos = favReposNoti(repos, cnfg)
	}

	// Default overall notifications counter
	title := fmt.Sprintf("%d", num)
	// There are notification in favorite repositories
	if favNum > 0 {
		if favNum == num {
			// All notifications are in favorite repos
			title = fmt.Sprintf("[%d]", favNum)
		} else {
			title = fmt.Sprintf("[%d]/%d", favNum, num)
		}
	}
	// Additional counter for the number of repositories
	if len(repos) > 1 && num != len(repos) {
		title = fmt.Sprintf("%s/%d", title, len(repos))
	} else if favNum > 0 {
		title = fmt.Sprintf("%s/%d", title, len(repos))
	}
	return title
}

// getNotificationsTooltip constructs tooltip string
func getNotificationsTooltip(num int, favNum int, repos map[string]int, cnfg *settings) string {
	// Filter mode
	if cnfg.FiltersMode == "favorite" {
		num = favNum
		favNum = 0
		repos = favReposNoti(repos, cnfg)
	}

	// Windows doesn't support long tooltip messages
	if runtime.GOOS == "windows" {
		tooltip := fmt.Sprintf("Notifications: %d", num)
		if favNum > 0 {
			tooltip = fmt.Sprintf("%s\nIn favorite: %d", tooltip, favNum)
		}
		if len(repos) > 1 && num != len(repos) {
			tooltip = fmt.Sprintf("%s\nRepositories: %d", tooltip, len(repos))
		}
		return tooltip
	}

	// Sort repos by name
	keys := make([]string, 0, len(repos))
	for k := range repos {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	// Tooltip contains list of repositories with notifications counters
	tooltip := ""
	for _, k := range keys {
		tooltip = fmt.Sprintf("%s%s (%d)\n", tooltip, k, repos[k])
	}
	return strings.Trim(tooltip, "\n")
}

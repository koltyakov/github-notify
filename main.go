package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/getlantern/systray"

	"github.com/koltyakov/github-notify/icon"
)

var running = true

func main() {
	onExit := func() {
		running = false
	}
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetIcon(icon.Generic)
	systray.SetTitle("Loading...")

	config, err := getSettings()
	if err != nil {
		fmt.Println(err)
		systray.SetTitle("Error")
		systray.SetTooltip(fmt.Sprintf("Error: %s", err))
	}

	notiPage := systray.AddMenuItem("Notifications", "")
	tokenPage := systray.AddMenuItem("Get Token", "")
	tokenPage.Hide()
	settings := systray.AddMenuItem("Settings", "")
	systray.AddSeparator()
	aboutPage := systray.AddMenuItem("About", "About GitHub Notify")
	mQuit := systray.AddMenuItem("Quit", "Quit GitHub Notify")

	go func() {
		for {
			select {
			case <-notiPage.ClickedCh:
				openBrowser("https://github.com/notifications?query=is%3Aunread")
			case <-tokenPage.ClickedCh:
				openBrowser("https://github.com/settings/tokens/new")
			case <-settings.ClickedCh:
				config = openSettings()
				if config.GithubToken == "" {
					tokenPage.Show()
					systray.SetTitle("No Token")
					systray.SetTooltip("Error: no access token has been provided")
					systray.SetIcon(icon.Error)
				} else {
					tokenPage.Hide()
					systray.SetTitle("")
					systray.SetTooltip("")
					systray.SetIcon(icon.Generic)
				}
			case <-aboutPage.ClickedCh:
				openBrowser("https://github.com/koltyakov/github-notify")
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	if config.GithubToken == "" {
		tokenPage.Show()
		systray.SetTitle("No Token")
		systray.SetTooltip("Error: no access token has been provided")
		systray.SetIcon(icon.Error)
	}

	for running {
		if config.GithubToken != "" {
			if num, err := getNotifications(config.GithubToken); err != nil {
				fmt.Printf("error: %s\n", err)
				systray.SetTitle("Error")
				systray.SetTooltip(fmt.Sprintf("Error: %s", err))
				systray.SetIcon(icon.Error)
				if strings.Contains(err.Error(), "401 Bad credentials") {
					tokenPage.Show()
					config.GithubToken = ""
					continue
				}
			} else {
				systray.SetTitle(fmt.Sprintf("%d", num))
				systray.SetTooltip("")
				if num != 0 {
					systray.SetIcon(icon.Noti)
				} else {
					systray.SetIcon(icon.Generic)
				}
			}
			d, err := time.ParseDuration(config.UpdateFrequency)
			if err != nil {
				fmt.Printf("error parsing update frequency: %s\n", err)
				d = 30 * time.Second
			}
			time.Sleep(d)
		} else {
			time.Sleep(1 * time.Second)
		}
	}
}

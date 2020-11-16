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
	systray.SetIcon(icon.Data)
	systray.SetTitle("Loading...")

	// https://github.com/settings/tokens
	accessToken := getAccessToken()

	notiPage := systray.AddMenuItem("Notifications", "")
	tokenPage := systray.AddMenuItem("Get Token", "")
	tokenPage.Hide()
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
			case <-aboutPage.ClickedCh:
				openBrowser("https://github.com/koltyakov/github-notify")
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()

	if accessToken == "" {
		tokenPage.Show()
		systray.SetTitle("No Token")
		systray.SetTooltip("Error: no access token has been provided")
	}

	go func() {
		for running && accessToken != "" {
			if num, err := getNotifications(accessToken); err != nil {
				fmt.Printf("error: %s\n", err)
				systray.SetTitle("Error")
				systray.SetTooltip(fmt.Sprintf("Error: %s", err))
				if strings.Contains(err.Error(), "401 Bad credentials") {
					tokenPage.Show()
					running = false
				}
			} else {
				systray.SetTitle(fmt.Sprintf("%d", num))
				systray.SetTooltip("")
			}
			time.Sleep(30 * time.Second)
		}
	}()
}

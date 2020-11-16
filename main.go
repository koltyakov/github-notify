package main

import (
	"context"
	"fmt"
	"io/ioutil"
	"strings"
	"time"

	"github.com/getlantern/systray"
	"github.com/google/go-github/v32/github"
	"golang.org/x/oauth2"

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

	mQuit := systray.AddMenuItem("Quit", "")
	go func() {
		<-mQuit.ClickedCh
		systray.Quit()
	}()

	// https://github.com/settings/tokens
	dat, err := ioutil.ReadFile("./config/token")
	if err != nil {
		fmt.Println(err)
		systray.Quit()
	}
	accessToken := string(dat)

	if accessToken == "" {
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

func getNotifications(accessToken string) (int, error) {
	ctx := context.Background()

	ts := oauth2.StaticTokenSource(
		&oauth2.Token{
			AccessToken: accessToken,
		},
	)
	tc := oauth2.NewClient(ctx, ts)
	client := github.NewClient(tc)

	noti, _, err := client.Activity.ListNotifications(ctx, nil)
	if err != nil {
		return -1, err
	}

	return len(noti), nil
}

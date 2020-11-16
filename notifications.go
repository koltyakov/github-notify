package main

import (
	"context"

	"github.com/google/go-github/v32/github"
	"golang.org/x/oauth2"
)

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

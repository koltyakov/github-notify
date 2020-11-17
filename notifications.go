package main

import (
	"context"

	"github.com/google/go-github/v32/github"
	"golang.org/x/oauth2"
)

// getNotifications checks personal unread GitHub notifications and returns the count
func getNotifications(accessToken string) (int, error) {
	ctx := context.Background()

	client := github.NewClient(
		oauth2.NewClient(ctx, oauth2.StaticTokenSource(
			&oauth2.Token{
				AccessToken: accessToken,
			},
		)),
	)

	noti, _, err := client.Activity.ListNotifications(ctx, nil)
	if err != nil {
		return -1, err
	}

	return len(noti), nil
}

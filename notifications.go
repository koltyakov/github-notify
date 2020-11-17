package main

import (
	"context"

	"github.com/google/go-github/v32/github"
	"golang.org/x/oauth2"
)

// getNotifications checks personal unread GitHub notifications
func getNotifications(accessToken string) ([]*github.Notification, error) {
	ctx := context.Background()

	client := github.NewClient(
		oauth2.NewClient(ctx, oauth2.StaticTokenSource(
			&oauth2.Token{
				AccessToken: accessToken,
			},
		)),
	)

	notifications, _, err := client.Activity.ListNotifications(ctx, nil)
	if err != nil {
		return nil, err
	}

	return notifications, nil
}

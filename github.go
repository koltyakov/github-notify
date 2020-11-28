package main

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/go-github/v32/github"
	"golang.org/x/oauth2"
)

// GitHubClient struct
type GitHubClient struct {
	client   *github.Client
	ctx      context.Context
	lastRead time.Time
}

// NewGitHubClient creates GitHub API client
func NewGitHubClient(ctx context.Context, accessToken string) *GitHubClient {
	return &GitHubClient{
		client: newClient(ctx, accessToken),
		ctx:    ctx,
	}
}

// newClient creates and instance of GitHub client with OAuth2
func newClient(ctx context.Context, accessToken string) *github.Client {
	return github.NewClient(
		oauth2.NewClient(ctx, oauth2.StaticTokenSource(
			&oauth2.Token{
				AccessToken: accessToken,
			},
		)),
	)
}

// SetToken sets/updates access token
func (gh *GitHubClient) SetToken(accessToken string) {
	gh.client = newClient(gh.ctx, accessToken)
}

// GetNotifications checks personal unread GitHub notifications
func (gh *GitHubClient) GetNotifications() ([]*github.Notification, error) {
	gh.lastRead = time.Now()
	notifications, _, err := gh.client.Activity.ListNotifications(gh.ctx, nil)
	if err != nil {
		return nil, err
	}
	return notifications, nil
}

// MarkRepositoryNotificationsRead marks notifications as read
func (gh *GitHubClient) MarkRepositoryNotificationsRead(repoName string) error {
	r := strings.Split(repoName, "/")
	if len(r) < 2 {
		return errors.New("incorrect repository name, should be owner/repo formatted")
	}
	_, err := gh.client.Activity.MarkRepositoryNotificationsRead(gh.ctx, r[0], r[1], gh.lastRead)
	return err
}

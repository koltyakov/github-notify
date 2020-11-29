package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/emersion/go-autostart"
)

// AutoStart struct
type AutoStart struct {
	app *autostart.App
}

// getApp gets github-notify autostart application instance
func (a *AutoStart) getApp() (*autostart.App, error) {
	if a.app != nil {
		return a.app, nil
	}

	a.app = &autostart.App{
		Name:        appname,
		DisplayName: "GitHub Notify",
	}

	execPath, err := os.Executable()
	if err != nil {
		return a.app, fmt.Errorf("error getting executable: %s", err)
	}

	// ignore if "go-build" is in the path
	if strings.Index(execPath, "go-build") != -1 {
		return a.app, fmt.Errorf("autostart is not available for dev mode (go run ./)")
	}

	// Darwin/Linux
	a.app.Exec = []string{"sh", "-c", fmt.Sprintf("nohup %s >/dev/null 2>&1 &", execPath)}
	// Windows
	if runtime.GOOS == "windows" {
		a.app.Exec = []string{"cmd", "/c", execPath}
	}

	return a.app, nil
}

// IsEnabled checks if the app is currently autostarted
func (a *AutoStart) IsEnabled() bool {
	app, _ := a.getApp()
	return app.IsEnabled()
}

// Enable adds the app to auto start
func (a *AutoStart) Enable() error {
	app, err := a.getApp()
	if err != nil {
		return err
	}
	if len(app.Exec) == 0 {
		return fmt.Errorf("can't add the app to auto start, empty command")
	}
	return app.Enable()
}

// Disable removes the app from auto start
func (a *AutoStart) Disable() error {
	app, _ := a.getApp()
	return app.Disable()
}

// Configure configures auto start due to the state parameter
func (a *AutoStart) Configure(enable bool) error {
	if a.IsEnabled() != enable {
		if enable {
			if err := a.Enable(); err != nil {
				return err
			}
		} else {
			if err := a.Disable(); err != nil {
				return err
			}
		}
	}
	return nil
}

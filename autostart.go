package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/koltyakov/github-notify/boot"
)

// Autostart struct
type Autostart struct {
	app boot.Booter
}

// Configure configures auto start due to the state parameter
func (a *Autostart) Configure(enable bool) error {
	if a.isEnabled() != enable {
		if enable {
			if err := a.enable(); err != nil {
				return err
			}
		} else {
			if err := a.disable(); err != nil {
				return err
			}
		}
	}
	return nil
}

// getApp gets github-notify autostart application instance
func (a *Autostart) getApp() (boot.Booter, error) {
	if a.app != nil {
		return a.app, nil
	}

	a.app = boot.NewBooter(appname, "GitHub Notify", nil)

	execPath, err := os.Executable()
	if err != nil {
		return a.app, fmt.Errorf("error getting executable: %s", err)
	}

	// ignore if "go-build" is in the path
	if strings.Index(execPath, "go-build") != -1 {
		return a.app, fmt.Errorf("autostart is not available for dev mode (go run ./)")
	}

	// Darwin/Linux
	exec := []string{"sh", "-c", fmt.Sprintf("nohup %s >/dev/null 2>&1 &", execPath)}
	// Windows
	if runtime.GOOS == "windows" {
		exec = []string{execPath}
	}

	a.app.SetExec(exec)

	return a.app, nil
}

// isEnabled checks if the app is currently autostarted
func (a *Autostart) isEnabled() bool {
	app, _ := a.getApp()
	return app.IsEnabled()
}

// enable adds the app to auto start
func (a *Autostart) enable() error {
	app, err := a.getApp()
	if err != nil {
		return err
	}
	if len(app.GetExec()) == 0 {
		return fmt.Errorf("can't add the app to auto start, empty command")
	}
	return app.Enable()
}

// disable removes the app from auto start
func (a *Autostart) disable() error {
	app, _ := a.getApp()
	return app.Disable()
}

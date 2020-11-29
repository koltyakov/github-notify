package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/kirsle/configdir"
	"github.com/koltyakov/gosip/cpass"
	"github.com/skratchdot/open-golang/open"
	"github.com/zserge/lorca"
)

// settings structure
type settings struct {
	GithubToken     string   `json:"githubToken"`
	UpdateFrequency string   `json:"updateFrequency"` // possible values: "10s", "30s", ...
	FavoriteRepos   []string `json:"favoriteRepos"`
	FiltersMode     string   `json:"filtersMode"` // possible values: "all", "favorite"
	AutoStart       bool     `json:"autoStart"`

	// DesktopNotifications bool   `json:"desktopNotifications"`
}

// openSettings opens Chrome window using Lorca, Chrome is required in the system
// returns new or existing settings and a sign if the setting were updated
func openSettings(ctx context.Context) (settings, bool, error) {
	cnfg, upd, err := openInChrome(ctx)
	if err != nil {
		// Check only an error with no Chrome found
		if strings.Index(err.Error(), "fork/exec : no such file or directory") != -1 {
			// Workaround opening settings file for manual edit
			err = openInEditor()
		}
	}
	return cnfg, upd, err
}

// openInEditor opens settings file in default text editor
// for the cases, no Chrome is installed in the system
func openInEditor() error {
	return open.Run(getConfigPath())
}

// openInChrome opens settings in Chrome/Chromium using Lorca
func openInChrome(ctx context.Context) (settings, bool, error) {
	isUpdated := false

	// Settings dialog window size
	dlg := &dimension{
		Width:  540,
		Height: 541,
	}

	// Get saved or default settings
	cnfg, err := getSettings()
	if err != nil {
		fmt.Printf("error: %s\n", err)
	}

	// Chrome Launch Switches arguments https://sites.google.com/site/chromeappupdates/launch-switches
	var args []string
	// args = append(args, "--headless")

	if screen, err := getScreenSize(); err == nil && screen.Height != 0 && screen.Width != 0 {
		args = append(args, fmt.Sprintf(
			"--window-position=%d,%d",
			(screen.Width-dlg.Width)/2,
			(screen.Height-dlg.Height)/2,
		))
	}

	// Init Lorca window using embed HTML
	ui, err := lorca.New("data:text/html,"+url.PathEscape(settingsHTMLTmpl), "", dlg.Width, dlg.Height, args...)
	if err != nil {
		// Can't open Chrome, likely is not installed
		return cnfg, false, err
	}

	var savingErr error
	if err := ui.Bind("saveSettings", func(settingsJSON string) {
		c := settings{}
		if err := json.Unmarshal([]byte(settingsJSON), &c); err != nil {
			fmt.Printf("unable to parse the response: %v\n", err)
		} else {
			if err := saveSettings(c); err != nil {
				// fmt.Printf("error saving settings: %v\n", err)
				savingErr = err
			} else {
				isUpdated = true
			}
		}
		_ = ui.Close()
	}); err != nil {
		// fmt.Printf("error binding handler: %s\n", err)
		return cnfg, false, fmt.Errorf("can't save settings: %v", err)
	}

	if getAppVersion() != "0.0.0-SNAPSHOT" {
		// Set title with version
		ui.Eval(fmt.Sprintf(`document.title += ", v.%s";`, getAppVersion()))
		// Block context menu
		ui.Eval(`window.addEventListener("contextmenu", function(e) { e.preventDefault(); });`)
	}

	// Binding existing settings values
	jsonBytes, _ := json.Marshal(cnfg)
	ui.Eval(fmt.Sprintf("const currentSettings = %s;", jsonBytes))

	// Wait for settings page close
	defer func() { _ = ui.Close() }()
	select {
	case <-ui.Done():
	case <-ctx.Done():
		return cnfg, isUpdated, nil
	}

	// An error has happened in save settings handler
	if savingErr != nil {
		return cnfg, false, fmt.Errorf("can't save settings: %v", savingErr)
	}

	// Return new settings
	cnfg, _ = getSettings()
	return cnfg, isUpdated, nil
}

// getSettings retrieves setting from disk or returns defaults
func getSettings() (settings, error) {
	var defaults = settings{
		GithubToken:     "",
		UpdateFrequency: "30s",
		FavoriteRepos:   make([]string, 0),
		FiltersMode:     "all",
		AutoStart:       false,
	}

	var cnfg settings
	configFile := getConfigPath()

	configData, err := ioutil.ReadFile(configFile)
	if err != nil {
		return defaults, err
	}

	if err := json.Unmarshal(configData, &cnfg); err != nil {
		return defaults, err
	}

	cnfg.GithubToken, _ = cpass.Cpass("").Decode(cnfg.GithubToken)

	if cnfg.FavoriteRepos == nil {
		cnfg.FavoriteRepos = make([]string, 0)
	}

	if cnfg.FiltersMode == "" {
		cnfg.FiltersMode = "all"
	}

	// if autoStart != nil {
	// 	cnfg.AutoStart = autoStart.IsEnabled()
	// }

	return cnfg, nil
}

// saveSettings persists settings to disk
func saveSettings(cnfg settings) error {
	configFile := getConfigPath()
	configFolder := filepath.Dir(configFile)
	if err := configdir.MakePath(configFolder); err != nil {
		return err
	}

	cnfg.GithubToken, _ = cpass.Cpass("").Encode(cnfg.GithubToken)

	configData, err := json.MarshalIndent(cnfg, "", " ")
	if err != nil {
		return err
	}

	if err := ioutil.WriteFile(configFile, configData, 0644); err != nil {
		return err
	}

	return nil
}

// getConfigPath gets application settings file path
func getConfigPath() string {
	configPath := configdir.LocalConfig(appname)
	configFile := filepath.Join(configPath, "settings.json")
	return configFile
}

// getAppVersion gets application version number
func getAppVersion() string {
	if len(version) == 0 {
		return "0.0.0-SNAPSHOT"
	}
	return version
}

// setFilterMode changes notifications filter mode
func setFilterMode(mode string) (settings, error) {
	cnfg, err := getSettings()
	if err != nil {
		return cnfg, err
	}
	cnfg.FiltersMode = mode
	err = saveSettings(cnfg)
	return cnfg, err
}

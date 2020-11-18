package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"net/url"
	"path/filepath"

	"github.com/kirsle/configdir"
	"github.com/koltyakov/gosip/cpass"
	"github.com/skratchdot/open-golang/open"
	"github.com/zserge/lorca"
)

// settings structure
type settings struct {
	GithubToken     string `json:"githubToken"`
	UpdateFrequency string `json:"updateFrequency"`
}

// openSettings opens Chrome window using Lorca, Chrome is required in the system
// returns new or egsisting settings and a sign if the setting were updated
func openSettings() (settings, bool, error) {
	cnfg, upd, err := openInChrome()
	if err != nil {
		// ToDo: Check only an error with no Chrome found
		fmt.Printf("%s\n", err)
		// Workaround opening settigns file for manual edit
		err = openInEditor()
	}
	return cnfg, upd, err
}

// openInEditor opens settings file in default text editor
// for the cases, no Chrome is installed in the system
func openInEditor() error {
	return open.Run(getConfigPath())
}

// openInChrome opens settings in Chrome/Chromium using Lorca
func openInChrome() (settings, bool, error) {
	isUpdated := false

	// Settings dialog window size
	dlg := &struct {
		w int
		h int
	}{
		w: 540,
		h: 380,
	}

	// Get saved or default settings
	cnfg, err := getSettings()
	if err != nil {
		fmt.Printf("error: %s\n", err)
	}

	// Chrome Launch Switches arguments https://sites.google.com/site/chromeappupdates/launch-switches
	var args []string

	// args = append(args, fmt.Sprintf(
	// 	"--window-position=%d,%d",
	// 	(int(screenWidth)-dlg.w)/2,
	// 	(int(screenHeight)-dlg.h)/2,
	// ))

	// Init Lorca window using embed HTML
	ui, err := lorca.New("data:text/html,"+url.PathEscape(settingsHTMLTmpl), "", dlg.w, dlg.h, args...)
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

	ui.Eval(`
		const githubToken = "` + cnfg.GithubToken + `";
		const updateFrequency = "` + cnfg.UpdateFrequency + `";
	`)

	// Wait for settings page close
	defer func() { _ = ui.Close() }()
	<-ui.Done()

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

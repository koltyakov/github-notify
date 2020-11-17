package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"net/url"
	"path/filepath"

	"github.com/kirsle/configdir"
	"github.com/koltyakov/gosip/cpass"
	"github.com/zserge/lorca"
)

// settings structure
type settings struct {
	GithubToken     string `json:"githubToken"`
	UpdateFrequency string `json:"updateFrequency"`
}

// openSettings opens Chrome window using Lorca, Chrome is required in the system
// returns new or egsisting settings and a sign if the setting were updated
func openSettings() (settings, bool) {
	isUpdated := false

	// Settings dialog window size
	dlg := &struct {
		w int
		h int
	}{
		w: 540,
		h: 380,
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
		log.Fatal(err)
	}

	if err := ui.Bind("saveSettings", func(settingsJSON string) {
		var cnfg settings
		if err := json.Unmarshal([]byte(settingsJSON), &cnfg); err != nil {
			fmt.Printf("unable to parse the response: %v\n", err)
		} else {
			if err := saveSettings(cnfg); err != nil {
				fmt.Printf("error saving settings: %v\n", err)
			} else {
				isUpdated = true
			}
		}
		_ = ui.Close()
	}); err != nil {
		fmt.Printf("error binding handler: %s\n", err)
	}

	cnfg, err := getSettings()
	if err != nil {
		fmt.Printf("error: %s\n", err)
	}

	ui.Eval(`
		const githubToken = "` + cnfg.GithubToken + `";
		const updateFrequency = "` + cnfg.UpdateFrequency + `";
	`)

	// Wait for settings page close
	defer func() { _ = ui.Close() }()
	<-ui.Done()

	// Return new settings
	cnfg, _ = getSettings()
	return cnfg, isUpdated
}

// getSettings retrieves setting from disk or returns defaults
func getSettings() (settings, error) {
	var defaults = settings{
		GithubToken:     "",
		UpdateFrequency: "30s",
	}

	var cnfg settings
	configPath := configdir.LocalConfig(appname)
	configFile := filepath.Join(configPath, "settings.json")

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
	configPath := configdir.LocalConfig(appname)
	if err := configdir.MakePath(configPath); err != nil {
		return err
	}

	configFile := filepath.Join(configPath, "settings.json")

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

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

var html = `
<html>
	<head>
		<title>GitHub Notify</title>
		<link rel="shortcut icon" type="image/svg+xml" href="https://github.githubassets.com/favicons/favicon.svg">
		<link rel="apple-touch-icon" sizes="180x180" href="https://github.githubassets.com/apple-touch-icon-180x180.png">
		<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-alpha3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-CuOF+2SnTUfTwSZjCXf01h7uYhfOBuxIhGKPbfEJ3+FqH/s6cIFN9bGr1HmAg4fQ" crossorigin="anonymous">
		<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.0.0-alpha3/dist/js/bootstrap.bundle.min.js" integrity="sha384-popRpmFF9JQgExhfw5tZT4I9/CI5e2QcuUZPOVXb1m7qUmeR2b50u+YFEYe1wgzy" crossorigin="anonymous"></script>
	</head>
	<body>
		<div class="modal-header">
			<h5 class="modal-title" id="exampleModalLabel">Settings</h5>
			<button type="button" class="btn-close" data-dismiss="modal" aria-label="Close" onclick="window.close()"></button>
		</div>
		<div class="modal-body">
			<form>
				<div class="mb-3">
					<label for="githubToken" class="form-label">GitHub Token</label>
					<input type="password" class="form-control" id="githubToken">
				</div>
				<div class="mb-3">
					<label for="updateFrequency" class="form-label">Update Frequency</label>
					<select class="form-select" id="updateFrequency">
						<option value="10s">High</option>
						<option value="30s">Medium</option>
						<option value="120s">Low</option>
					</select>
				</div>
			</form>
		</div>
		<div class="modal-footer">
			<button type="button" class="btn btn-secondary" data-dismiss="modal" onclick="window.close()">Close</button>
			<button type="button" class="btn btn-primary" onclick="save()">Save</button>
		</div>
		<script type="text/javascript">
			function save() {
				const data = {
					githubToken: document.getElementById("githubToken").value,
					updateFrequency: document.getElementById("updateFrequency").value
				};
				saveValue(JSON.stringify(data));
			}
			document.getElementById("githubToken").value = githubToken;
			document.getElementById("updateFrequency").value = updateFrequency;
		</script>
	</body>
</html>
`

type settings struct {
	GithubToken     string `json:"githubToken"`
	UpdateFrequency string `json:"updateFrequency"`
}

var defaultSettings = settings{
	GithubToken:     "",
	UpdateFrequency: "30s",
}

func openSettings() settings {
	dialogWidth := 520
	dialogHeight := 375

	var args []string

	// args = append(args, fmt.Sprintf(
	// 	"--window-position=%d,%d",
	// 	(int(screenWidth)-dialogWidth)/2,
	// 	(int(screenHeight)-dialogHeight)/2,
	// ))

	ui, err := lorca.New("data:text/html,"+url.PathEscape(html), "", dialogWidth, dialogHeight, args...)
	if err != nil {
		log.Fatal(err)
	}

	ui.Bind("saveValue", func(formData string) {
		var s settings
		if err := json.Unmarshal([]byte(formData), &s); err != nil {
			fmt.Printf("unable to parse the response: %v\n", err)
		} else {
			if err := saveSettings(s); err != nil {
				fmt.Printf("error saving settings: %v\n", err)
			}
		}
		_ = ui.Close()
	})

	s, err := getSettings()
	if err != nil {
		fmt.Printf("error: %s\n", err)
	}

	ui.Eval(`
		const githubToken = "` + s.GithubToken + `";
		const updateFrequency = "` + s.UpdateFrequency + `";
	`)

	defer ui.Close()
	<-ui.Done()

	s, _ = getSettings()
	return s
}

func getSettings() (settings, error) {
	var s settings
	configPath := configdir.LocalConfig("github-notify")
	configFile := filepath.Join(configPath, "settings.json")

	configData, err := ioutil.ReadFile(configFile)
	if err != nil {
		return defaultSettings, err
	}

	if err := json.Unmarshal(configData, &s); err != nil {
		return defaultSettings, err
	}

	s.GithubToken, _ = cpass.Cpass("").Decode(s.GithubToken)

	return s, nil
}

func saveSettings(s settings) error {
	configPath := configdir.LocalConfig("github-notify")
	if err := configdir.MakePath(configPath); err != nil {
		return err
	}

	configFile := filepath.Join(configPath, "settings.json")

	s.GithubToken, _ = cpass.Cpass("").Encode(s.GithubToken)

	configData, err := json.MarshalIndent(s, "", " ")
	if err != nil {
		return err
	}

	if err := ioutil.WriteFile(configFile, configData, 0644); err != nil {
		return err
	}

	return nil
}

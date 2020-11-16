package main

import (
	"fmt"
	"io/ioutil"

	"github.com/getlantern/systray"
)

func getAccessToken() string {
	// https://github.com/settings/tokens

	dat, err := ioutil.ReadFile("./config/token")
	if err != nil {
		fmt.Println(err)
		systray.SetTitle("Error")
		systray.SetTooltip(fmt.Sprintf("Error: %s", err))
	}
	return string(dat)
}

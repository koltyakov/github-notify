package main

import (
	"io/ioutil"
)

func getAccessToken() (string, error) {
	// https://github.com/settings/tokens

	dat, err := ioutil.ReadFile("./config/token")
	if err != nil {
		return "", err
	}

	return string(dat), nil
}

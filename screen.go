package main

import (
	"github.com/zserge/lorca"
)

// dimension struct for defining height and width
type dimension struct {
	Width  int
	Heigth int
}

var screenSize = dimension{}

// getScreenSize gets screen width and height
func getScreenSize() (dimension, error) {
	if screenSize.Width != 0 && screenSize.Heigth != 0 {
		return screenSize, nil
	}

	// Open Chrome in headless mode
	ui, err := lorca.New("data:text/html,", "", 0, 0, "--headless")
	if err != nil {
		// Can't open Chrome, likely is not installed
		return screenSize, err
	}

	defer func() { _ = ui.Close() }()

	screenSize.Width = ui.Eval("screen.availWidth").Int()
	screenSize.Heigth = ui.Eval("screen.availHeight").Int()

	return screenSize, nil
}

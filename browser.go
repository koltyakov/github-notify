package main

import (
	"fmt"
	"os/exec"
	"runtime"
)

// openBrowser opens a page in default browser
func openBrowser(url string) error {
	var err error = nil
	switch runtime.GOOS {
	case "linux":
		err = exec.Command("xdg-open", url).Start()
	case "windows":
		err = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		err = exec.Command("open", url).Start()
	default:
		err = fmt.Errorf("unsupported platform")
	}
	return err
}

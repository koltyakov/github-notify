//+build windows
// Copy of https://github.com/emersion/go-autostart/blob/master/autostart_windows.go
// with replacement of CGO implemantation for cross build compatibility

package boot

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/go-ole/go-ole"
	"github.com/go-ole/go-ole/oleutil"
)

// NewBooter creates an instance of autostart application
func NewBooter(name string, desc string, exec []string) Booter {
	startupDir := filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Roaming", "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
	lnkPath := filepath.Join(startupDir, name+".lnk")

	return &bootWin{
		exec:       exec,
		startupDir: startupDir,
		lnkPath:    lnkPath,
	}
}

// bootWin app struct
type bootWin struct {
	exec       []string
	startupDir string
	lnkPath    string
}

// IsEnabled checks if the app is in auto start
func (w *bootWin) IsEnabled() bool {
	_, err := os.Stat(w.lnkPath)
	return err == nil
}

// Enable enables auto start
func (w *bootWin) Enable() error {
	exePath := w.exec[0]
	args := strings.Join(w.exec[1:], " ")

	if err := os.MkdirAll(w.startupDir, 0777); err != nil {
		return err
	}
	if err := createShortcut(w.lnkPath, exePath, args); err != nil {
		return err
	}
	return nil
}

// Disable disables auto start
func (w *bootWin) Disable() error {
	return os.Remove(w.lnkPath)
}

// SetExec exec property setter
func (w *bootWin) SetExec(exec []string) {
	w.exec = exec
}

// GetExec exec property getter
func (w *bootWin) GetExec() []string {
	return w.exec
}

/* Helper method(s) */

// createShortcut creates Windows shortcut (.lnk) file
func createShortcut(lnkPath string, exePath string, args string) error {
	exePath, _ = filepath.Abs(exePath)
	dirPath, _ := filepath.Abs(filepath.Dir(exePath))

	ole.CoInitializeEx(0, ole.COINIT_APARTMENTTHREADED|ole.COINIT_SPEED_OVER_MEMORY)
	oleShellObject, err := oleutil.CreateObject("WScript.Shell")
	if err != nil {
		return err
	}
	defer oleShellObject.Release()
	wshell, err := oleShellObject.QueryInterface(ole.IID_IDispatch)
	if err != nil {
		return err
	}
	defer wshell.Release()
	cs, err := oleutil.CallMethod(wshell, "CreateShortcut", lnkPath)
	if err != nil {
		return err
	}
	idispatch := cs.ToIDispatch()
	oleutil.PutProperty(idispatch, "TargetPath", exePath)
	oleutil.PutProperty(idispatch, "WorkingDirectory", dirPath)
	oleutil.PutProperty(idispatch, "Arguments", args)
	oleutil.CallMethod(idispatch, "Save")
	return nil
}

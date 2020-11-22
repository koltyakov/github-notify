package main

import (
	"os"
	"path/filepath"

	"github.com/nightlyone/lockfile"
)

var lockfilePath = filepath.Join(os.TempDir(), appname+".lock")

// lockSession locks application instance session
func lockSession() error {
	lock, err := lockfile.New(lockfilePath)
	if err != nil {
		return err
	}
	return lock.TryLock()
}

// unlockSession unlocks application instance session
func unlockSession() {
	lock, _ := lockfile.New(lockfilePath)
	_ = lock.Unlock()
}

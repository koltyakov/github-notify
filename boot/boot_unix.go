//+build linux darwin

package boot

import (
	"github.com/emersion/go-autostart"
)

// NewBooter creates an instance of autostart application
func NewBooter(name string, desc string, exec []string) Booter {
	return &boot{
		App: &autostart.App{
			Name:        name,
			DisplayName: desc,
			Exec:        exec,
		},
	}
}

// boot app struct
type boot struct {
	*autostart.App
}

// SetExec exec property setter
func (b *boot) SetExec(exec []string) {
	b.Exec = exec
}

// GetExec exec property getter
func (b *boot) GetExec() []string {
	return b.Exec
}

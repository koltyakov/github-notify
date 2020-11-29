package boot

// Booter autostarter interface
type Booter interface {
	IsEnabled() bool
	Enable() error
	Disable() error

	SetExec(exec []string)
	GetExec() []string
}

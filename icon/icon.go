package icon

// Icon struct
type Icon struct {
	Data []byte
	Name string
}

// Base bytes array icon representation
var Base = &Icon{
	Data: baseIcon,
	Name: "base",
}

// Err bytes array icon representation
var Err = &Icon{
	Data: errIcon,
	Name: "error",
}

// Notice bytes array icon representation
var Notice = &Icon{
	Data: noticeIcon,
	Name: "notice",
}

// Warn bytes array icon representation
var Warn = &Icon{
	Data: warnIcon,
	Name: "warning",
}

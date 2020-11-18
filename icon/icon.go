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

// Noti bytes array icon representation
var Noti = &Icon{
	Data: notiIcon,
	Name: "notification",
}

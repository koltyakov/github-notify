install:
	go get -u ./... && go mod tidy

format:
	gofmt -s -w .

icons:
	cd icon/ && ./gen.sh

build-win:
	GOOS=windows GOARCH=amd64 go build -ldflags "-H=windowsgui" -o bin/github-notify.exe ./

build:
	go build -o bin/github-notify ./

run:
	pkill github-notify || true
	nohup go run ./ >/dev/null 2>&1 &
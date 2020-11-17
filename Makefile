install:
	go get -u ./... && go mod tidy

format:
	gofmt -s -w .

icons:
	cd icon/ && ./gen.sh

build-win:
	GOOS=windows GOARCH=amd64 go build -ldflags "-H=windowsgui" -o bin/github-notify.exe ./

build-darwin:
	GOOS=darwin GOARCH=amd64 go build -o bin/github-notify ./

build: build-win build-darwin

run:
	pkill github-notify || true
	nohup go run ./ >/dev/null 2>&1 &
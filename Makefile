install:
	go get -u ./... && go mod tidy

format:
	gofmt -s -w .

icons:
	cd icon/ && ./gen.sh

build-win:
	GOOS=windows GOARCH=amd64 go build -v -ldflags "-H=windowsgui" -o bin/win/github-notify.exe ./

build-darwin:
	GOOS=darwin GOARCH=amd64 go build -v -o bin/darwin/github-notify ./

build-linux:
	GOOS=linux GOARCH=amd64 go build -v -o bin/linux/github-notify ./

# build: clean build-win build-darwin build-linux
build: clean
	go build -v -o bin/github-notify ./

clean:
	rm -rf bin/

run:
	pkill github-notify || true
	nohup go run ./ >/dev/null 2>&1 &
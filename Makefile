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

bundle-darwin: clean build-darwin
	# Package solution to .app folder
	go get github.com/machinebox/appify
	cd bin/darwin/ && \
		appify \
			-author "Andrew Koltyakov" \
			-id com.koltyakov.ghnotify \
			-version 0.1.0 \
			-name "GitHub Notify" \
			-icon ../../assets/icon.png \
			./github-notify
	/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' 'bin/darwin/GitHub Notify.app/Contents/Info.plist'
	rm 'bin/darwin/GitHub Notify.app/Contents/README'
	# Package solution to .dmg image
	cd bin/darwin/ && \
		create-dmg --dmg-title='GitHub Notify' 'GitHub Notify.app' ./

start: run # alias for run
run:
	pkill github-notify || true
	nohup go run ./ >/dev/null 2>&1 &
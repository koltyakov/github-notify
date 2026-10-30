#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

gopath="$(go env GOPATH)"
if [[ ! -x "$gopath/bin/2goarray" ]]; then
    go install github.com/cratonica/2goarray@latest
fi

# Both implementations use the original artwork in the root assets directory.
generate_icon() {
    local file="$1" output="$2" name="$3" platform="$4"
    {
        echo "//go:build $platform"
        echo "// +build $platform"
        echo
        "$gopath/bin/2goarray" "$name" icon < "../../assets/tray/$file"
    } > "$output"
}

generate_icon base.png icon_base.go baseIcon linux
generate_icon base.ico icon_base_win.go baseIcon windows
generate_icon error.png icon_error.go errIcon linux
generate_icon error.ico icon_error_win.go errIcon windows
generate_icon notice.png icon_notice.go noticeIcon linux
generate_icon notice.ico icon_notice_win.go noticeIcon windows
generate_icon warn.png icon_warn.go warnIcon linux
generate_icon warn.ico icon_warn_win.go warnIcon windows
gofmt -w .

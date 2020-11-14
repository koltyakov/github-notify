#/bin/sh

if [ -z "$GOPATH" ]; then
  echo GOPATH environment variable not set
  exit
fi

if [ ! -e "$GOPATH/bin/2goarray" ]; then
  echo "Installing 2goarray..."
  go get github.com/cratonica/2goarray
  if [ $? -ne 0 ]; then
    echo Failure executing go get github.com/cratonica/2goarray
    exit
  fi
fi

IMGPATH="./assets/unix.png"
OUTPUT=iconunix.go

echo Generating $OUTPUT
echo "//+build linux darwin" > $OUTPUT
echo >> $OUTPUT
cat "$IMGPATH" | $GOPATH/bin/2goarray Data icon >> $OUTPUT
if [ $? -ne 0 ]; then
  echo Failure generating $OUTPUT
  exit
fi

IMGPATH="./assets/win.ico"
OUTPUT=iconwin.go

echo Generating $OUTPUT
echo "//+build windows" > $OUTPUT
echo >> $OUTPUT
cat "$IMGPATH" | $GOPATH/bin/2goarray Data icon >> $OUTPUT
if [ $? -ne 0 ]; then
  echo Failure generating $OUTPUT
  exit
fi

echo Finished
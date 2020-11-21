FROM golang:buster

ENV GO111MODULE=on \
    CGO_ENABLED=1 \
    GOOS=linux \
    GOARCH=amd64

RUN apt-get update && apt-get install -y gcc libgtk-3-dev libappindicator3-dev

WORKDIR /build
COPY go.mod .
COPY go.sum .
RUN go mod download

COPY . .
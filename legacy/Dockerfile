FROM golang:1.27

ENV GO111MODULE=on \
    CGO_ENABLED=1 \
    GOOS=linux

RUN apt-get update && apt-get install -y --no-install-recommends gcc libgtk-3-dev libayatana-appindicator3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY go.mod .
COPY go.sum .
RUN go mod download

COPY . .

# Github Notify

> Simple tray application (mostly for macOS) for getting GitHub notifications

![demo](./assets/demo.gif)

**Scenario**

- I'm a maintainer or active watcher of some repositories at GitHub
- I want to react to issues quickly
- I prefer a status based humble info rather than agressive email or pop-ups
- My daily driver is macOS machine
- I prefer default Safari for browsing

## Build

```bash
make build
```

## Config

- Generate [GitHub access token](https://github.com/settings/tokens) (better select only Notifications access).
- Create `./config/token` file (relative to the start folder) and paste the token.

## Run

```bash
./bin/github-notify &
```
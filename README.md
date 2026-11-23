# claude code permission popups

made cus i was bored. it's a little menu bar app that shows claude code's permission requests as a floating card over whatever app you're in, so you don't have to keep switching back to claude.

you get allow, deny and always allow. the card won't steal your focus, so you can keep typing.

## install

you need a mac (macOS 13+) and swift (`xcode-select --install` gets you that, no full xcode needed).

```sh
make install
```

then click the shield in the menu bar and hit **Install Claude Code Hook…**. it shows you exactly what it'll change in `~/.claude/settings.json` and backs the file up first.

## using it

- click **Allow**, **Deny** or **Always Allow** on the card
- or click the card and press return / escape
- or from anywhere: ctrl+option+return to allow, ctrl+option+escape to deny

if the app isn't running, nothing breaks, claude just asks you like normal.

the menu bar icon has the rest: turn popups on/off, move the cards to another corner, sound, open at login, and a history of what you allowed/denied.

## uninstall

uninstall the hook from the menu, then:

```sh
make uninstall
```

## dev stuff

```sh
make build
make test
make app
```

how it works under the hood is in [docs/architecture.md](docs/architecture.md).

## credits

me (and claude)

MIT license

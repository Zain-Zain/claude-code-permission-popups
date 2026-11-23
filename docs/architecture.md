# how it works

there are three bits:

- **permission-hook**: a tiny helper inside the app. claude code runs it every time it wants permission for something.
- **the menu bar app**: shows the cards and remembers your choices.
- **PermissionCore**: the shared code both of them use (and where most of the tests are).

```
claude code ──runs──▶ permission-hook
                         │  passes the request along
                         ▼
                   menu bar app ──▶ shows a card
                         │  you click allow / deny / always allow
                         ▼
                   permission-hook ──▶ tells claude code what you picked
```

## the flow

1. claude wants to do something, so it runs the helper and hands it the request (the tool, the command, which folder, etc).
2. the helper sends that to the app over a private socket file in `~/Library/Application Support/local.permission-popups/`.
3. the app shows a card. you pick something.
4. the app sends your answer back, the helper prints it in the format claude code expects, and claude carries on (or doesn't).

if anything goes wrong at any step (app not running, app crashed, popups turned off, weird input), the helper just prints nothing. claude takes that as "no answer" and asks you in its own window like normal. **it never says yes on its own.**

what claude gets back:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

deny sends `"behavior":"deny"` plus a message saying you denied it from the popup. always allow sends `"allow"` plus the rule claude offered to save, and claude code saves the rule itself.

## stuff it skips

- **questions claude asks you** (AskUserQuestion): not a permission thing, so they stay in claude.
- **plan approvals** (ExitPlanMode): claude needs the plan sent back with the approval, which a card can't really do, and claude's own dialog has more options anyway. so these stay in claude too.

## keeping it safe

- **only you can talk to it.** the socket is locked to your user account, and both sides check who's on the other end.
- **no stealing focus.** cards float on top but never grab your keyboard unless you click one, so you can't approve something by accident while typing.
- **no accidental clicks.** a card ignores clicks and keys for half a second after it shows up or moves, so you don't hit allow on a card you haven't read yet.
- **holding the shortcut does nothing extra.** ctrl+option+return answers one card per press, not a whole stack.
- **always allow is limited.** it only saves the exact rule claude offered for that request, never anything bigger like "allow all edits". the helper double-checks this too.
- **claude's deny rules still win.** the popup can't approve something your claude settings block.
- **long commands say they're cut off**, so nothing hides past the edge of the card.
- **no internet.** the app never goes online. your history stays in a local file only you can read (last 1,000 entries).
- **settings edits are careful.** the hook installer shows you the change first, backs up your settings file, and won't touch it if it looks off.
- **why a socket and not a local web server?** any web page could poke a local server and spam you with fake cards. a socket file locked to your account can't be reached like that.

## what i tested by hand

tested on 2026-11-23 in the claude desktop app (macOS 15, apple silicon):

- allow, deny and always allow all work. deny tells claude you said no, and always allow saves the rule in the project's `.claude/settings.local.json`.
- three requests at once show up as three stacked cards. the shortcut answers the oldest and focus stays where you were.
- answering on the card closes claude's own prompt too.
- quitting the app: claude just asks you itself, no delay.
- the hook works in a session that was already open, no restart needed. (in auto mode claude doesn't ask for anything, so no cards show up. that's expected.)
- uses about 30 MB of memory when idle.

not tested yet: what happens if you answer in claude's own prompt *first* while a card is up. worst case the card hangs around until the hook times out (10 min).

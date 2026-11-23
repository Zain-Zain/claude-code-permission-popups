# Floating permission popups for Claude Code — design

Date: 2026-11-23
Status: draft, awaiting approval

## 1. Intent

Claude Code stops and waits whenever it needs permission to run a command, edit a
file, or use a tool. Today the user has to switch back into Claude to answer. The
goal is a small macOS background app that shows each permission request as a
floating card over whatever app the user is in, so they can Allow, Deny, or Always
Allow without leaving their current window. Decisions must reach Claude Code's real
permission flow, so execution truly continues or stops.

The user runs Claude Code in the Claude desktop app (Code tab). The `claude` CLI is
not installed on this machine. VS Code and the CLI should work too, since they read
the same hooks, but the desktop app is the main target.

## 2. Goals, non-goals, anti-goals

Goals, in priority order (the user's own ranking):
1. Reliable detection of real permission requests.
2. Correct communication of decisions back to Claude Code.
3. A floating card that appears over every app and never takes keyboard focus.
4. Security: Claude Code's existing model is preserved, and nothing is ever approved
   automatically.
5. Minimal resource use.
6. Clean, maintainable code.

Features:
- A floating card per request, bottom-left by default. The corner (bottom-left,
  bottom-right, top-left, top-right) can be changed from the menu bar.
- Allow, Deny, and Always Allow (where Claude Code offers a rule).
- Enter = Allow and Escape = Deny, once the card has focus (see 5.4).
- Global shortcuts that work from any app without focusing the card.
- Several requests at once, stacked.
- A card stays until answered and disappears once answered, or once Claude Code
  stops waiting for it.
- A menu bar icon, launch at login, a "popups on/off" toggle, and a history of
  decisions.

Non-goals:
- A dashboard, statistics, theming, or a complex settings window. The menu bar menu
  is the whole settings UI, plus one small history window.
- Replacing Claude's own permission prompt. It stays as the fallback.
- Answering Claude's questions to the user (the AskUserQuestion tool). Those are not
  permission decisions.
- Remote or phone approval.
- Product naming, branding, or marketing copy.

Anti-goals (these would make it a failure even if it technically works):
- Taking keyboard focus when a card appears. A stray Enter typed into the user's
  editor must never approve a command.
- Ever approving something the user did not click or shortcut. No silent defaults,
  no "allow on timeout".
- Breaking Claude Code when the app is not running, crashes, or is paused. In every
  such case Claude must fall back to its normal prompt.
- Fake or simulated requests. Every card corresponds to a real pending request.
- Heavy resource use (Electron-class memory).

## 3. Research findings (Claude Code integration)

Source: the official hooks reference, code.claude.com/docs/en/hooks.

- **`PermissionRequest` hook.** It fires only when Claude Code is about to show a
  permission prompt, so allow-listed and auto-approved calls never reach it. It also
  fires in places where Claude would otherwise auto-deny because nobody can answer.
  - Input on stdin includes `session_id`, `transcript_path`, `cwd`,
    `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`, and an optional
    `permission_suggestions` array. MCP tools also get `mcp_server`.
  - Output is JSON on stdout:
    `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}`.
    The `decision` object holds:
    - `behavior`: `"allow"` or `"deny"`.
    - `updatedPermissions`: allow only. Uses entries such as `addRules` with a
      `destination` (`session`, `localSettings`, `projectSettings`,
      `userSettings`).
    - `message`: deny only. Shown to Claude.
    - `interrupt`: deny only. Stops Claude when true.
  - A hook cannot override a deny rule. Claude Code's own rules always win.
- **Desktop app and VS Code.** Hooks fire there too. Permission requests in those
  hosts also go to the app's own prompt (`canUseTool`). The hook and the in-app
  prompt run side by side, and whichever answers first applies. So Claude's own
  prompt is always still there.
- **Timeouts.** Command hooks time out after 600 s by default (configurable per hook).
  When a hook times out, or exits without printing a decision, the normal permission
  flow continues as if the hook were not there.
- **Always Allow.** `permission_suggestions` carries the exact rule Claude Code would
  save if the user picked "always allow" in its own prompt, for example
  `{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm install:*"}],"behavior":"allow","destination":"localSettings"}`.
  Returning that as `updatedPermissions` makes Claude Code write the rule itself, so
  this app never edits permission rules by hand.
- **Hook registration.** Hooks are read from settings files. For all projects that
  means `~/.claude/settings.json`, which does not exist yet on this machine. The
  shape is:
  `{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"<path>","timeout":600}]}]}}`.
- **HTTP hooks** exist too, but were rejected (see section 4).

### Things to verify during testing (the docs don't settle them)
1. Whether Claude Code kills the hook process when the user answers in Claude's own
   prompt first. The design handles both outcomes (section 5.3).
2. The exact deny output shape. The docs give fields but no example. It will be
   confirmed against a live session.
3. Whether the desktop app picks up a newly added hook without a restart.

## 4. Approaches considered

| Approach | Trade-offs | Verdict |
|---|---|---|
| **A. Native Swift: AppKit `NSPanel` + SwiftUI, Swift hook helper, Unix socket** | About 25–40 MB of memory and a small bundle. macOS has a panel type built for floating without taking focus. Login items and global hotkeys use system APIs. The code is Swift rather than React. | **Chosen by the user** |
| B. Electron + React | Familiar, but 150–300 MB of memory and about 200 MB on disk. Floating without focus is a known weak spot (full-screen spaces, switching spaces). | Rejected: resources and focus reliability |
| C. Tauri + React | Small, but needs a third-party plugin for the non-focusing panel and the Rust toolchain (not installed). | Rejected: fragility in the most important area |

Bridge between Claude Code and the app:
- **Chosen: a command hook plus a Unix domain socket.** Claude Code runs a tiny helper
  binary. The helper connects to a socket that only the user's account can open, and
  the app checks the peer's user ID on connect.
- **Rejected: an HTTP hook to a localhost server.** Any local process or web page
  could post fake requests and flood the user with cards.

## 5. Design

### 5.1 Components

```
Claude Code ──runs──▶ hook helper (CLI, inside the .app bundle)
                         │  stdin: PermissionRequest JSON
                         │  connects to Unix socket
                         ▼
                   menu bar app (agent, no Dock icon)
                         │  shows floating card(s)
                         │  user clicks / shortcut
                         ▼
                   decision ──▶ helper ──stdout JSON──▶ Claude Code
```

1. **Hook helper** (`permission-hook`, a Swift executable in
   `App.app/Contents/MacOS/`):
   - Reads stdin, and exits silently (no output, exit 0) in each of these cases, so
     Claude's normal prompt handles the request:
     - the input does not parse;
     - `tool_name` is `AskUserQuestion`;
     - the socket is missing or refuses the connection;
     - the app replies "pass" (popups are turned off, for example).
   - Otherwise it sends the request to the app and waits for a decision line, then
     prints the Claude Code decision JSON and exits 0.
   - It never decides anything on its own.
   - It handles SIGTERM and SIGINT by closing the socket and exiting, so the app sees
     the disconnect.
   - It needs no third-party code. It uses Foundation and POSIX sockets only.
2. **Menu bar app** (`LSUIElement`, so there is no Dock icon):
   - A socket server on a background queue. One connection is one request.
   - A request queue (`@MainActor` store) that drives the cards.
   - The panel controller (positioning, stacking).
   - The menu bar menu, the history store, settings (`UserDefaults`), login item
     registration, and global hotkeys.
3. **Shared module**: the protocol types and the encode/decode of Claude Code's
   hook input and output. Unit tests cover it.

### 5.2 Wire protocol (helper ↔ app)

Newline-delimited JSON over `~/Library/Application Support/<bundle-id>/agent.sock`.
The directory is mode 0700 and the socket mode 0600. On accept, the app calls
`getpeereid` and rejects any UID other than its own.

- **helper → app:** `{"v":1,"request":<the raw PermissionRequest JSON from Claude Code>}`
- **app → helper:** one of:
  - `{"v":1,"decision":"allow"}`
  - `{"v":1,"decision":"allow_always","updatedPermissions":[...]}`
    (copied from the request's `permission_suggestions`)
  - `{"v":1,"decision":"deny","message":"..."}`
  - `{"v":1,"decision":"pass"}`

The helper turns the app's reply into Claude Code's output format. That keeps
knowledge of Claude Code's schema in one shared, tested place.

### 5.3 Request lifecycle

1. A connection arrives and is parsed into a `PendingRequest`. It gets an id, the
   arrival time, the tool, a human summary, `cwd`, the session id (shortened), and
   the suggestions.
2. If popups are off, the app replies `pass` and closes. Claude's own prompt handles
   it.
3. Otherwise a card appears, without taking focus, and optionally plays a soft sound
   (see 5.6).
4. The user decides. The app writes the reply, closes the connection, removes the
   card, and appends to history.
5. If the connection closes before a decision (Claude got its answer in its own
   prompt, the session ended, or the hook timed out), the card is removed and
   history records "answered elsewhere / expired". If the desktop app turns out not
   to kill the helper when answered in-app, the card stays until the 600 s hook
   timeout. Answering it then is harmless, because Claude Code ignores late hook
   output. This is documented as a known limitation if testing confirms it.
6. If the app quits with requests pending, every connection closes. The helpers exit
   silently and Claude falls back to its own prompts.

### 5.4 Floating card

- Each card is its own `NSPanel`. The settings: style `.nonactivatingPanel` +
  `.borderless`, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary, .stationary]`, `hidesOnDeactivate = false`,
  `becomesKeyOnlyIfNeeded = true`. It is shown with `orderFrontRegardless()`, never
  with `makeKey`. Content is SwiftUI in an `NSHostingView` with a
  `.regularMaterial`-style visual-effect background and rounded corners, about
  360 pt wide, so it looks like a macOS notification.
- **Card content:**
  ```
  ┌───────────────────────────────────────────┐
  │ ◆ Claude wants to run a command      2s   │
  │ ┌───────────────────────────────────────┐ │
  │ │ npm install express                   │ │  monospaced, up to 6 lines, scrolls
  │ └───────────────────────────────────────┘ │
  │ "Install express" (Claude's description)  │
  │ in ~/Desktop/vscode/my-app                │
  │ Always allow: Bash(npm install:*)         │  shown only if a suggestion exists
  │ [Deny ⎋]       [Always Allow]  [Allow ↩]  │
  └───────────────────────────────────────────┘
  ```
- **Per-tool summaries:**
  - `Bash`: "run a command", showing `command` and `description`.
  - `Edit` / `Write` / `MultiEdit` / `NotebookEdit`: "edit a file" or "create a
    file", showing the path. Edit and MultiEdit also get a short old → new preview.
  - `Read` / `Glob` / `Grep`: "read …" or "search …" with the path or pattern.
  - `WebFetch` / `WebSearch`: "fetch" with the URL, or "search the web" with the
    query.
  - MCP tools (`mcp__server__tool`): "use <tool> from <server>", plus the compact
    JSON input.
  - `ExitPlanMode`: "approve its plan", with the first lines of the plan.
  - Anything else: the tool name plus compact JSON of the input, truncated.
- **Keyboard (decided by the user: never steal focus):**
  - Clicking a card makes that card the key window, without activating the app. Then
    Enter = Allow and Escape = Deny for that card.
  - Hover only highlights the card. It does not give it focus. *Builder's call, a
    change from what was said in chat:* if hovering gave focus, a mouse resting in
    that corner while the user types elsewhere would send their keystrokes, and a
    stray Enter, to the card. That is exactly the accident the user wants to avoid.
  - Global hotkeys, registered with Carbon `RegisterEventHotKey` (no Accessibility
    permission needed):
    - ⌃⌥↩ allows the oldest pending card.
    - ⌃⌥⎋ denies the oldest pending card.
    - The card these target gets a subtle "next" indicator.
  - Always Allow has no shortcut on purpose. It changes settings for good, so it
    needs a click.
- **Stacking:**
  - Cards stack from the chosen corner, oldest nearest the corner, with 8 pt gaps
    and an 16 pt screen margin.
  - At most 4 are visible. Past that, a small "+N more" pill appears, and the next
    card takes the freed slot as one is answered.
  - Cards appear on the screen that has the mouse when they arrive.
- **Motion:** a short fade and slide in (about 150 ms) and a fade out. There are no
  other animations.

### 5.5 Decisions

- **Allow:** `{"behavior":"allow"}`.
- **Always Allow:** `{"behavior":"allow","updatedPermissions":<filtered suggestions>}`.
  - *Builder's call:* only `addRules` entries with `behavior: "allow"` are
    forwarded.
    - All such entries go together. A compound command such as `npm i && npm test`
      can produce several rules, and Claude's own "don't ask again" option covers
      them all.
    - `setMode` entries (for example switching the session to accept-edits) are
      dropped, along with `addDirectories`, `replaceRules`, and anything else. Each
      of those grants more than "this kind of action".
    - If nothing is left after filtering, the button is hidden.
  - Claude Code writes the rule itself, to wherever the suggestion says (usually the
    project's local settings).
  - The card lists every rule that will be saved, with its destination ("this
    project" or "all projects"), before you click.
- **Deny:** `{"behavior":"deny","message":"The user denied this request from the
  permission popup.","interrupt":false}`. Claude stays running and can adapt.
  Whether to also offer "Deny and stop Claude" (`interrupt: true`) is left out of v1
  to keep the card simple.

### 5.5a Which requests get a card, and timeouts (builder's calls)

- **Requests Claude Code would otherwise auto-deny** (no one could answer in Claude
  itself, for example a background agent) still get a card.
  - A card is always an explicit human decision, and the hooks reference names a
    PermissionRequest hook as the supported way to answer these.
  - If the card is ignored, the hook times out and Claude Code's normal behaviour
    (deny) applies.
  - The card can't reliably tell these apart from normal requests, so it does not
    try.
- **Hook timeout stays at 600 s.**
  - In the desktop app (the main target) the hook runs alongside Claude's own
    prompt, so a card waiting there never blocks Claude.
  - Each request has its own helper process, so a leftover helper never delays later
    requests.
  - The CLI and VS Code "should work" but aren't part of v1's end-to-end checks. If
    a host waits for the hook before showing its own prompt, an ignored card holds
    that request for up to 10 minutes. The README documents this and how to shorten
    the timeout.

### 5.6 Menu bar menu (the whole settings UI)

```
● 2 pending requests           (or "No pending requests")
─────────────
Popups                    ✓    (off = every request goes to Claude's own prompt)
Sound                     ✓
Position             ▸  Bottom Left ✓ / Bottom Right / Top Left / Top Right
Open at Login             ✓
─────────────
History…
Hook: Installed ✓   /   Install Claude Code Hook…
─────────────
Quit
```
The menu bar icon is a small SF Symbol, and it shows a dot when requests are
pending.

### 5.7 Hook installation

"Install Claude Code Hook…" works like this:
1. It shows a confirmation sheet with the exact JSON it will add, and the target file
   `~/.claude/settings.json`.
2. It backs the file up to `settings.json.bak-<timestamp>`.
3. It merges in one `PermissionRequest` entry pointing at the helper's absolute path
   inside the installed app. It is idempotent: an existing entry for that helper is
   replaced, and every other content is preserved.
4. It writes atomically.

"Uninstall" removes only that entry. The README also documents the manual JSON, for
people who prefer to edit the file themselves. The app checks on launch whether the
hook is installed and points to the current app path, and shows that in the menu.

### 5.8 History

- An append-only JSON Lines file at
  `~/Library/Application Support/<bundle-id>/history.jsonl`, mode 0600.
- Each entry holds: time, decision (allowed / always allowed / denied / answered
  elsewhere), tool, summary, cwd, and the session id prefix.
- It is capped at the latest 1,000 entries, trimmed on launch.
- The history window is a plain, resizable SwiftUI list (newest first) with a
  "Clear History" button.
- Commands can contain secrets, so history stays local and is never sent anywhere.

### 5.9 Launch at login and resources

- `SMAppService.mainApp.register()` (macOS 13+), toggled from the menu. It is on by
  default after the first launch, with the menu item showing that state.
- When idle the app does nothing: no polling and no timers. The socket accept blocks
  on a GCD source. Each panel exists only while its card is shown.

## 6. Constraints

- macOS 13 or newer, because of `SMAppService`. The user is on macOS 15.5, Apple
  Silicon.
- Toolchain: Swift 6.1 from the Command Line Tools. Xcode.app is not installed, so
  the build uses Swift Package Manager, and a script assembles the `.app` bundle
  (Info.plist, both executables, icon) and code-signs it ad hoc.
- The `.app` should live in `/Applications` (or `~/Applications`) so that the login
  item and the hook path stay stable. `make install` does this.
- No third-party dependencies.
- An ad-hoc signed app gets the Gatekeeper "unidentified developer" prompt on first
  open when it's downloaded. Built locally, it doesn't. The README explains this.
  Notarization is out of scope (it needs a paid Apple Developer account).
- The hook must not slow Claude Code down when the app is closed. The helper fails
  fast on a missing socket, in milliseconds.

## 7. Repository

Located at `~/Desktop/vscode/claude-code-permission-popups/`. It is a git repo, and
nothing gets pushed until the user has reviewed it. There is no product name: the
app bundle is named "Permission Popups" as a plain description.

```
Package.swift
Sources/PermissionCore/     shared protocol, Claude Code I/O mapping, summaries, settings merge
Sources/PermissionApp/      menu bar app
Sources/permission-hook/    hook helper
Tests/PermissionCoreTests/
Resources/Info.plist, AppIcon
scripts/build-app.sh, scripts/install.sh
Makefile                    build / test / app / install / uninstall
docs/architecture.md        how the integration works, security model, limitations
docs/superpowers/specs/     this document
README.md                   what it does, requirements, install, configure, develop, troubleshoot
.gitignore                  .build/, *.app, .DS_Store, xcuserdata, .env*, *.bak-*
.env.example                not needed: the app has no secrets or env config. The README says so instead of shipping an empty file.
LICENSE                     MIT (builder's call; the user can change it)
```

## 8. Testing

- **Unit tests** (`swift test`) for the core logic:
  - Decoding of PermissionRequest inputs for each tool type, including real samples
    captured from this machine.
  - Encoding of each decision into the exact Claude Code output JSON.
  - Summary text per tool.
  - The settings.json merge: no file, existing hooks, already installed, malformed
    file (refuse and report, never overwrite).
  - Wire protocol round-trip.
- **Integration test:** a script that starts the app's socket server headless, pipes
  sample stdin into the helper, simulates a decision, and checks the stdout JSON.
  Plus the "app not running" path: no output, exit 0, under 50 ms.
- **End-to-end** (with the user, in the real desktop app):
  1. Install the hook.
  2. Ask Claude to run a command that needs approval.
  3. The card appears without taking focus while typing in another app.
  4. Allow: Claude continues.
  5. Deny: Claude reports the denial and adapts.
  6. Always Allow: the rule appears in settings, and the next identical command
     doesn't prompt.
  7. Several parallel requests (for example subagents).
  8. Answering in Claude's own prompt: confirms the item 1 behaviour in the section 3
     list.
  9. Full-screen app, other spaces, multiple monitors.
  10. Paused popups and a quit app: Claude's normal prompt.

## 9. Left to the builder

- Exact visual details: padding, fonts, icon choice, colors in light and dark mode.
- Internal type names and file layout within the targets.
- The history window layout.
- The choice of test framework: XCTest or Swift Testing, whichever the Command Line
  Tools toolchain supports.
- The exact deny message wording.

# Architecture

## Components

```
Claude Code ──runs──▶ permission-hook (helper, inside the .app bundle)
                         │  stdin: PermissionRequest JSON
                         │  connects to the Unix socket
                         ▼
                   menu bar app (no Dock icon)
                         │  shows floating card(s)
                         │  user clicks or uses a shortcut
                         ▼
                   decision ──▶ helper ──stdout JSON──▶ Claude Code
```

- **`permission-hook`** reads the hook input from stdin, forwards it to the app over the socket, waits for one reply line, prints Claude Code's decision JSON, and exits 0. It uses Foundation and POSIX sockets only. It never decides anything itself.
- **`PermissionApp`** is the menu bar app. It runs the socket server, the request queue, the card panels, the menu, the history store and the hotkeys.
- **`PermissionCore`** is the shared library: wire types, the mapping to and from Claude Code's hook JSON, request summaries, the queue, the settings.json editor, history, and socket code.

## Hook interface

Claude Code runs the helper for each `PermissionRequest` event. Input on stdin is JSON with `session_id`, `cwd`, `tool_name`, `tool_input`, and an optional `permission_suggestions` array. Output on stdout is:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

- Allow: `{"behavior":"allow"}`.
- Always Allow: `{"behavior":"allow","updatedPermissions":[...]}`, copied from the request's suggestions after filtering.
- Deny: `{"behavior":"deny","message":"The user denied this request from the permission popup.","interrupt":false}`.
- No decision: print nothing and exit 0. Claude Code then continues with its normal prompt.

## Request sequence

```
Claude Code        helper              app                    user
    │ PermissionRequest │                │                      │
    │──stdin JSON──────▶│                │                      │
    │                   │──connect──────▶│ check peer UID       │
    │                   │──request line─▶│ queue, show card     │
    │                   │                │─────────────────────▶│
    │                   │                │◀──Allow/Deny/Always──│
    │                   │◀─reply line────│ close, record history│
    │◀──stdout JSON─────│ exit 0         │                      │
```

## Wire protocol

Newline-delimited JSON over `~/Library/Application Support/local.permission-popups/agent.sock`. One connection carries one request.

- Helper to app: `{"v":1,"request":<the raw PermissionRequest JSON>}`
- App to helper, one of:
  - `{"v":1,"decision":"allow"}`
  - `{"v":1,"decision":"allow_always","updatedPermissions":[...]}`
  - `{"v":1,"decision":"deny","message":"..."}`
  - `{"v":1,"decision":"pass"}`

The helper maps the reply to Claude Code's output format, so knowledge of that schema lives in one tested place. `pass`, an unknown decision, a version other than 1, or an `allow_always` without any offered `addRules`/`allow` entry produce no output.

## Request lifecycle

1. A connection arrives. The app checks the peer UID, reads the request line, and builds a pending request (id, time, tool, summary, `cwd`, short session id, suggestions).
2. If popups are off, the request is unreadable, or its wire version is not 1, the app replies `pass` and closes the connection. Turning popups off also replies `pass` to every open request and records each as "answered elsewhere".
3. Otherwise a card appears without taking focus, with an optional sound. If there is no screen to show it on (for example every display is asleep), the request is passed after 5 s and recorded as "answered elsewhere"; layout still retries whenever the screens change.
4. On a decision the app writes the reply, closes the connection, removes the card, and appends a history entry.
5. If the connection closes first (the session ended, the hook timed out, or Claude Code ended the helper after you answered in its own prompt; the last is not verified), the card is removed and history records "answered elsewhere / expired".
6. If the app quits with requests pending, it replies `pass` to each. If it crashes, the helpers see the closed connection and print nothing. Either way Claude falls back to its own prompts.

If the host does not end the helper when you answer in Claude's own prompt, the card may stay until the hook timeout. What Claude Code does with a late answer is not documented and is listed under Verification results.

According to the Claude Code hooks reference, PermissionRequest also fires where Claude Code would otherwise auto-deny because nobody can answer, so those requests get a card too. According to the same reference, a hook that times out or exits without a decision leaves the normal permission flow unchanged. `AskUserQuestion` and `ExitPlanMode` never reach the app: the helper exits silently for them, so Claude's own dialog handles them.

This is a deliberate deviation from the design (§5.4 lists `ExitPlanMode` as a normal "approve its plan" card). The hooks reference says `ExitPlanMode` needs `updatedInput` on allow and that returning `"allow"` alone is not sufficient. The popup has no reliable way to send the plan back, and Claude's own plan dialog offers more choices (such as accepting edits automatically), so plan approvals stay there. The plan summary in `RequestSummary` is kept but is not reached through the helper.

## Security model

- **Socket access.** The support directory is mode 0700 and `agent.sock` is mode 0600. On accept the app calls `getpeereid` and closes any connection whose UID differs from its own. A stale socket from a crash is unlinked and rebound at launch.
- **Never deciding by default.** Every failure path in the helper (bad or oversized input, missing socket, refused connection, read or write error, `pass`) prints nothing. There is no allow-on-timeout and no default answer. Only a click or a hotkey produces Allow, and the hotkeys target the oldest card.
- **No focus stealing.** Cards are non-activating panels shown with `orderFrontRegardless()`. A card can become key only after a mouse-down on that card (`canBecomeKey` is false otherwise), so AppKit can never hand key status to a card nobody clicked when another window closes. Hover does not focus it.
- **No input on a card the user has not seen.** `ArmState` (PermissionCore) arms a card only once it has stood still at its slot for 500 ms after it was shown or moved. Until then its buttons are dimmed, and a click on it is swallowed whole (mouse-down, drags and mouse-up never reach the card, so no button acts and the card does not become key); Return and Escape do nothing either. The hotkeys act only on an oldest card that is armed and has been the oldest for 500 ms.
- **One hotkey press, one decision.** The arming delay alone would let a held ⌃⌥Return approve another card about every 650 ms. `HotKeyLatch` (PermissionCore) fires a hotkey once per press and ignores it until Carbon reports the key released (`kEventHotKeyReleased`), so holding the keys approves at most one card.
- **Truncated text is announced.** A command or input longer than 2,000 characters is cut with "…", and the card shows "(N more characters not shown)" under the text box, visible without scrolling.
- **Deny rules always win.** According to the Claude Code hooks reference, a PermissionRequest hook cannot approve something a deny rule refuses, so Claude Code's configured rules still apply.
- **Always Allow filtering.** Only `addRules` suggestions with `behavior: "allow"` are forwarded, all together, since a compound command can produce several rules. `setMode`, `addDirectories`, `replaceRules` and anything else are dropped because each grants more than "this kind of action". If nothing is left the button is hidden. The card lists the rules and destinations first. Claude Code writes the rules itself; this app never edits permission rules.
- **Server check in the helper.** After connecting, the helper calls `getpeereid` and treats a server owned by another user as no server (a silent pass), before sending anything.
- **The helper enforces Always Allow itself.** It re-filters the app's `updatedPermissions` to `addRules`/`allow` entries that equal an entry Claude Code offered in this request, and prints nothing if none are left. Neither a buggy app nor another socket server can make it grant a mode change or an unoffered rule.
- **Wire version.** Both sides accept only `"v":1`. The app answers any other version with `pass`, and the helper prints nothing for a reply with any other version.
- **Socket override.** `PERMISSION_POPUPS_SOCKET` is honoured only by debug builds of the helper (tests and the integration script). Release builds always use the support-directory socket.
- **No HTTP hook.** A localhost HTTP server could be reached by any local process or web page, which could post fake requests and flood the screen with cards. A Unix socket restricted to the user's account, with a peer UID check, avoids that.
- **No network.** The app opens no network connections. History stays on disk (mode 0600, latest 1,000 entries).
- **settings.json edits** show the exact change first, refuse invalid or unexpected content (writing nothing), keep a timestamped backup, follow symlinks, re-read after confirmation, and preserve file permissions.

## Verification results

Items from the design's research section that documentation could not settle. To be filled in after the end-to-end test.

1. Does Claude Code end the hook process when the user answers in Claude's own prompt first? Pending end-to-end test.
2. The exact deny output shape, confirmed against a live session. Pending end-to-end test.
3. Does the desktop app pick up a newly added hook without a restart? Pending end-to-end test.
4. What does Claude Code do with hook output that arrives after the user answered in its own prompt? Pending end-to-end test.

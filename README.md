# Claude Code permission popups for macOS

A menu bar app that shows each Claude Code permission request as a floating card over whatever app you are using. You can allow, deny, or always allow a request without switching back to Claude, and the decision goes back through Claude Code's own permission flow. The cards never take keyboard focus, so a stray keystroke in your editor cannot approve anything.

## Requirements

- macOS 13 or newer.
- To build from source: Command Line Tools with Swift 6 (`xcode-select --install`). Full Xcode is not needed.
- Claude Code (the desktop app, VS Code extension, or CLI).

## Install

```sh
make install
```

This builds the app, copies `Permission Popups.app` to `/Applications` (override with `make install PREFIX=~/Applications`), and opens it. Then choose **Install Claude Code Hook…** from the menu bar icon. The app shows the exact change, asks for confirmation, and edits `~/.claude/settings.json`:

- It refuses to touch a file that is not valid JSON, has an unexpected shape, or contains numbers that cannot be preserved exactly. Nothing is written in those cases.
- It saves a backup next to the file as `settings.json.bak-<yyyyMMdd-HHmmss>` before writing.
- If `settings.json` is a symlink, it updates the target and keeps the link. A dangling symlink is refused.
- It re-reads the file after you confirm, and keeps the file's permissions (0600 for a new file).
- Everything else in the file is preserved.

Keep the app in `/Applications` (or wherever you installed it). The hook points at the helper inside the app bundle, and the menu shows when it points somewhere else.

### Manual hook configuration

To edit the file yourself, add this under `hooks.PermissionRequest` in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "'/Applications/Permission Popups.app/Contents/MacOS/permission-hook'",
            "timeout": 600
          }
        ]
      }
    ]
  }
}
```

The command is single-quoted because the app name contains a space. `timeout` is in seconds and can be lowered. When a hook times out, Claude Code continues with its normal prompt. In hosts that wait for the hook before showing their own prompt, a card you ignore holds the request until the timeout.

## Usage

Each request appears as a card in a screen corner (bottom left by default), on the screen that has the mouse. A card shows what Claude wants to do, the working directory, and three buttons:

- **Allow** lets this one request run.
- **Deny** refuses it. Claude is told the user denied it and keeps running.
- **Always Allow** appears only when Claude Code offers a rule to save. The card lists each rule and where it will be saved. Claude Code writes the rule itself.

Keyboard:

- Cards never take focus. Click a card to make it the active window, then press Return to allow or Escape to deny.
- Control-Option-Return allows and Control-Option-Escape denies the oldest card, from any app. These need no Accessibility permission.
- Always Allow has no shortcut and cannot be reached with Tab or Space. It needs a click.

Up to four cards are shown, oldest nearest the corner, with a "+N more" pill for the rest. A card is removed when it is answered, or when the connection closes because the session ended or the hook timed out. Whether the card also disappears when you answer in Claude's own prompt is not verified; see [Verification results](docs/architecture.md#verification-results). If it stays, it clears at the hook timeout.

According to the Claude Code hooks reference, in the desktop app and the VS Code extension the hook runs alongside Claude's own permission prompt, and whichever decides first applies.

## Configuration

The menu bar icon is the whole settings UI:

- **Popups**: when off, every request goes to Claude's own prompt.
- **Sound**: a short sound when a card appears.
- **Position**: Bottom Left, Bottom Right, Top Left, or Top Right.
- **Open at Login**: registered on first launch; toggle it here.
- **History…**: a window listing past decisions, with Clear History.
- **Hook**: install, uninstall, or reinstall the Claude Code hook.
- **Quit**.

The app has no environment variables or secrets, so there is no `.env` file.

## Where data lives

- `~/Library/Application Support/local.permission-popups/` (mode 0700)
  - `agent.sock`: the socket the helper connects to (mode 0600).
  - `history.jsonl`: decisions, with the tool, a summary, the working directory and a session id prefix (mode 0600). The latest 1,000 entries are kept. Commands can contain secrets, so this file stays local and is never sent anywhere.
- Preferences are stored in `UserDefaults` for `local.permission-popups`.
- The app makes no network connections.

The `HOME` environment variable is honoured when it is an absolute path.

## Uninstall

1. From the menu, choose **Hook: Installed** then **Uninstall Claude Code Hook**. This removes only this app's entry from `~/.claude/settings.json`.
2. Run `make uninstall` (quits the app and removes it from `/Applications`).
3. Optionally delete `~/Library/Application Support/local.permission-popups/` and turn off the login item if it is still listed in System Settings.

## Development

```sh
make build   # swift build (debug)
make test    # swift test, then scripts/integration-test.sh
make app     # release build, assembled and ad-hoc signed at dist/Permission Popups.app
make clean
```

Layout:

- `Sources/PermissionCore`: shared library. Wire protocol, hook input and output mapping, request summaries, request queue, settings.json editing, history, and the Unix socket server and client.
- `Sources/PermissionApp`: the menu bar app (AppKit panels with SwiftUI content).
- `Sources/permission-hook`: the helper Claude Code runs.
- `Tests/PermissionCoreTests`: unit tests (Swift Testing). `scripts/integration-test.sh` runs the real helper with no app listening.
- `Resources/Info.plist`: bundle metadata (`LSUIElement`, so no Dock icon).

The helper accepts a `PERMISSION_POPUPS_SOCKET` environment variable that overrides the socket path. The integration test uses it. It is available in release builds too.

There are no third-party dependencies. See [docs/architecture.md](docs/architecture.md) for how the pieces fit together.

## Troubleshooting

- **The hook does not fire.** Whether a newly added hook takes effect in a running session is not verified. If it does not fire, start a new Claude Code session.
- **No card appears.** Check that the app is running (menu bar icon), **Popups** is on, and the menu shows **Hook: Installed**. If the app is off, was quit, or crashed, the helper prints nothing and Claude shows its own prompt as usual.
- **No card for a question Claude asks you.** The AskUserQuestion tool is never shown; it is not a permission decision.
- **No card for a plan approval.** When Claude asks to leave plan mode (ExitPlanMode), answer in Claude's own dialog. Claude Code needs the plan sent back with an approval, which the popup does not do, so the helper stays silent for it. Claude's dialog also offers more choices, such as accepting edits automatically.
- **Gatekeeper blocks the app.** A build you compiled yourself opens normally. A build downloaded from elsewhere is ad-hoc signed and not notarized, so macOS may say it is from an unidentified developer. On macOS 15 and later, open System Settings, Privacy & Security, and choose "Open Anyway" for the app, or rebuild it from source.
- **`codesign --verify --strict` fails.** A checkout inside an iCloud-synced folder can gain extended attributes that fail strict verification. `codesign --verify` without `--strict` passes.

## Limitations

- Builds made with Command Line Tools only are host-architecture-only (arm64 on Apple Silicon). A universal (arm64 and x86_64) bundle needs full Xcode; the build script falls back to the host architecture.
- The app is ad-hoc signed and not notarized.
- Always Allow forwards only Claude Code's `addRules` allow suggestions. Mode changes (such as switching to accept-edits) and other suggestion types are never forwarded.
- There is no "deny and stop Claude" option.
- VS Code and the CLI were not part of the end-to-end checks; only the desktop app was tested.

## License

MIT. See [LICENSE](LICENSE).

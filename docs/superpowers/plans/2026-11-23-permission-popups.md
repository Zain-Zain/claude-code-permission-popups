# Floating Permission Popups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS menu bar app and a hook helper. Together they show Claude Code's real permission requests as floating cards that never take focus, and they return Allow, Deny or Always Allow to Claude Code.

**Architecture:**
- **Hook helper.** Claude Code runs a Swift CLI (`permission-hook`) as its `PermissionRequest` command hook. The helper forwards the request over a per-user Unix socket to the menu bar app (`PermissionApp`). It blocks until the app replies, then prints Claude Code's decision JSON.
- **Shared core.** All protocol, mapping, summary, settings-merge, history, queue and layout logic lives in a UI-free `PermissionCore` library with unit tests.
- **Thin UI layer.** The app target is only the AppKit/SwiftUI shell around that library.

**Tech Stack:**
- Swift 6.1 toolchain, in Swift 5 language mode (`swift-tools-version:5.10`).
- Swift Package Manager and the Swift Testing framework (`import Testing`). XCTest is not available with the Command Line Tools.
- Frameworks: AppKit, SwiftUI, Carbon (hotkeys), ServiceManagement (login item), Darwin sockets.
- No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-23-permission-popups-design.md`

## Global Constraints

**Platform and build**
- Minimum macOS 13.0 (`platforms: [.macOS(.v13)]`, `LSMinimumSystemVersion` 13.0).
- No third-party dependencies, and no network access of any kind.
- Bundle identifier: `local.permission-popups`. App bundle name: `Permission Popups.app`. Executables: `PermissionApp` and `permission-hook`.
- `LSUIElement = true`, so the app has no Dock icon.

**Socket and file locations**
- Support directory: `~/Library/Application Support/local.permission-popups/`, mode 0700.
- Socket: `<support>/agent.sock`, mode 0600. The peer UID must equal `getuid()`, or the connection is closed.
- History: `<support>/history.jsonl`, mode 0600, keeping the latest 1,000 entries.

**Hook entry in `~/.claude/settings.json`**
- `{"matcher":"*","hooks":[{"type":"command","command":"<abs path to permission-hook>","timeout":600}]}`, under `hooks.PermissionRequest`.

**Helper output**
- The helper prints nothing and exits 0 in all of these cases:
  - invalid input;
  - `tool_name == "AskUserQuestion"`;
  - no socket, or the connection is refused;
  - an app reply of `pass`;
  - any read or write error.
- It never decides anything by itself.

**Deny message**
- Exact text: `"The user denied this request from the permission popup."`, with `interrupt: false`.

**Always Allow**
- Forward only `permission_suggestions` entries where `type == "addRules"` and `behavior == "allow"`. Drop everything else.
- Hide the button when the filtered list is empty.

**Cards**
- Never take focus: `.nonactivatingPanel`, shown with `orderFrontRegardless()`, never `makeKey`.
- A card becomes key only when clicked. Hovering over a card never makes it key.
- Size and stacking: about 360 pt wide, 16 pt screen margin, 8 pt gap, at most 4 visible plus a "+N more" pill, oldest nearest the corner.
- The default corner is bottom-left.
- Cards appear on the screen that contains the mouse.

**Shortcuts**
- Global hotkeys: ⌃⌥Return allows the oldest card, and ⌃⌥Escape denies it.
- Always Allow has no shortcut.

**Repository rules**
- No product name or branding.
- Never commit secrets, `.env` files, or `*.bak-*` files.

## Review Focus

1. **Bad or unexpected hook stdin.** Empty input, non-JSON, a missing `tool_name`, a non-object `tool_input`, or a multi-MB input must make the helper exit 0 silently. It must never crash and never print partial JSON. Pinned in Task 4.
2. **Stale socket file after a crash.** The helper must fail fast with ECONNREFUSED and no output. The app must unlink the stale file and rebind on launch. Pinned in Task 3.
3. **Unusual `~/.claude/settings.json` files.** For a file with invalid JSON, or a non-object `hooks`, installation must throw and leave the file untouched. Other hook events, and other `PermissionRequest` entries, must survive installation and uninstallation byte-for-meaning. Pinned in Task 5.
4. **Very long or multi-line commands, and huge MCP inputs.** The card must stay bounded. Summary text is capped at 2,000 chars with an ellipsis, and the view caps visible lines at 6 and scrolls the rest. Pinned in Task 2 (summary cap); the visual check is in Task 8.
5. **More than 4 simultaneous requests, answered out of order.** The remaining cards must reflow, hotkeys must target the oldest pending request, and a closed connection must remove exactly its own card. Pinned in Task 6 (queue) and Task 7 (layout).

---

## File Structure

```
Package.swift
Sources/PermissionCore/JSONValue.swift          generic Codable JSON (round-trips tool_input/suggestions untouched)
Sources/PermissionCore/PermissionRequest.swift  decode Claude Code PermissionRequest stdin
Sources/PermissionCore/Decision.swift           Decision enum, Claude Code output encoding, Always-Allow filter
Sources/PermissionCore/WireProtocol.swift       helper<->app NDJSON messages
Sources/PermissionCore/RequestSummary.swift     human-readable card text per tool
Sources/PermissionCore/AppPaths.swift           bundle id, support dir, socket & history paths
Sources/PermissionCore/SocketServer.swift       app-side Unix socket server, peer-UID check, close detection
Sources/PermissionCore/SocketClient.swift       helper-side blocking exchange
Sources/PermissionCore/HookRunner.swift         helper logic (stdin -> socket -> stdout)
Sources/PermissionCore/HookSettings.swift       settings.json install/uninstall/status (pure, Data in/out)
Sources/PermissionCore/HistoryStore.swift       JSONL history
Sources/PermissionCore/RequestQueue.swift       pending-request state, oldest, resolve/expire
Sources/PermissionCore/PanelLayout.swift        Corner enum + card frame math
Sources/permission-hook/main.swift              thin wrapper over HookRunner + signal handling
Sources/PermissionApp/main.swift                NSApplication bootstrap
Sources/PermissionApp/AppDelegate.swift         wiring: server, queue, history, settings
Sources/PermissionApp/Preferences.swift         UserDefaults-backed settings
Sources/PermissionApp/CardPanel.swift           NSPanel subclass (non-activating, key-on-click)
Sources/PermissionApp/CardView.swift            SwiftUI card
Sources/PermissionApp/PanelController.swift     creates/positions/removes panels; "+N more" pill
Sources/PermissionApp/HotKeys.swift             Carbon RegisterEventHotKey wrapper
Sources/PermissionApp/StatusMenu.swift          NSStatusItem + menu
Sources/PermissionApp/HistoryWindow.swift       SwiftUI history list window
Sources/PermissionApp/HookInstallFlow.swift     confirm sheet, backup, atomic write
Tests/PermissionCoreTests/*.swift               one test file per core file
Tests/PermissionCoreTests/Fixtures/*.json       sample PermissionRequest inputs
Resources/Info.plist
scripts/build-app.sh  scripts/integration-test.sh
Makefile  README.md  docs/architecture.md  .gitignore  LICENSE
```

---

### Task 1: Package scaffold, JSON model, request decoding, decision encoding

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/PermissionCore/JSONValue.swift`, `Sources/PermissionCore/PermissionRequest.swift`, `Sources/PermissionCore/Decision.swift`, `Sources/PermissionCore/WireProtocol.swift`
- Create: `Sources/permission-hook/main.swift` (temporarily `print("")`), `Sources/PermissionApp/main.swift` (temporarily empty `NSApplication.shared.run()` stub). Both exist only so the package builds.
- Test: `Tests/PermissionCoreTests/DecodingTests.swift`, `Tests/PermissionCoreTests/DecisionTests.swift`, `Tests/PermissionCoreTests/Fixtures/bash.json`, `edit.json`, `mcp.json`, `ask_user_question.json`

**Interfaces (produces):**
- `public indirect enum JSONValue: Codable, Equatable, Sendable { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) }`
  - Helpers: `subscript(key: String) -> JSONValue?`, `var stringValue: String?`, `var arrayValue: [JSONValue]?`, `var objectValue: [String: JSONValue]?`, `func compactString(maxLength: Int) -> String` (sorted keys).
- `public struct PermissionRequest: Equatable, Sendable`
  - Fields: `sessionId: String`, `cwd: String?`, `permissionMode: String?`, `toolName: String`, `toolInput: JSONValue`, `mcpServer: String?`, `permissionSuggestions: [JSONValue]`, `raw: JSONValue`.
  - `public init(json: Data) throws`. It requires `hook_event_name == "PermissionRequest"` and a string `tool_name`. `tool_input` defaults to `.object([:])`, and `permission_suggestions` defaults to `[]`.
- `public enum Decision: Equatable, Sendable { case allow, allowAlways(updatedPermissions: [JSONValue]), deny(message: String), pass }`
- `public enum ClaudeHookOutput { public static func encode(_ d: Decision) -> Data? }`. Returns nil for `.pass`.
- `public func alwaysAllowUpdates(from suggestions: [JSONValue]) -> [JSONValue]`
- `public let denyMessage = "The user denied this request from the permission popup."`
- `public struct WireRequest: Codable { public let v: Int; public let request: JSONValue }`
- `public struct WireReply: Codable, Equatable`
  - Fields: `v: Int`, `decision: String` (`"allow"|"allow_always"|"deny"|"pass"`), `updatedPermissions: [JSONValue]?`, `message: String?`.
  - Methods: `init(_ d: Decision)` and `func toDecision() -> Decision?`. An unknown string becomes nil.

- [ ] **Step 1: Write the package scaffold**

  `Package.swift` has these targets:
  - `PermissionCore` (library);
  - `permission-hook` (executable, depends on `PermissionCore`);
  - `PermissionApp` (executable, depends on `PermissionCore`);
  - `PermissionCoreTests` (test target, resources `.copy("Fixtures")`).

  `.gitignore` contains: `.build/`, `*.app`, `dist/`, `.DS_Store`, `xcuserdata/`, `.swiftpm/`, `.env`, `.env.*`, `*.bak-*`.

- [ ] **Step 2: Write failing tests**

  Fixture `bash.json`:
  ```json
  {"session_id":"abc123def456","transcript_path":"/tmp/t.jsonl","cwd":"/Users/me/proj","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm install express","description":"Install express"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm install:*"}],"behavior":"allow","destination":"localSettings"},{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
  ```
  Write `edit.json`, `mcp.json` (`"tool_name":"mcp__github__create_issue"`, `"mcp_server":"github"`) and `ask_user_question.json` in the same shape.

  Tests:
  - `decodesBashFixture`: `toolName == "Bash"`, `toolInput["command"]?.stringValue == "npm install express"`, `cwd == "/Users/me/proj"`, `permissionSuggestions.count == 2`.
  - `rejectsWrongEvent`: input `{"hook_event_name":"PreToolUse","tool_name":"Bash"}` throws.
  - `rejectsMissingToolName`: throws.
  - `rejectsNonJSON`: `Data("hello".utf8)` throws.
  - `defaultsMissingInputAndSuggestions`: `toolInput == .object([:])` and `permissionSuggestions.isEmpty`.
  - `encodesAllow`: the parsed output equals `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`.
  - `encodesDeny`: the decision equals `{"behavior":"deny","message":denyMessage,"interrupt":false}`.
  - `encodesAllowAlways`: the decision equals `{"behavior":"allow","updatedPermissions":[<the addRules entry>]}`.
  - `passEncodesNil`: `ClaudeHookOutput.encode(.pass) == nil`.
  - `filtersSuggestions`: for the bash fixture, `alwaysAllowUpdates` returns exactly the one `addRules` entry. A `setMode`-only list returns `[]`. An `addRules` entry with `behavior: "deny"` is dropped.
  - `wireRoundTrip`: for each `Decision`, `WireReply(d).toDecision() == d` after a JSON encode and decode. `WireReply(v:1, decision:"bogus")` gives nil.

  Compare JSON by decoding both sides into `JSONValue`, never by comparing strings.

- [ ] **Step 3: Run the tests and confirm they fail**

  Run: `swift test`. Expected: compile errors about missing types.

- [ ] **Step 4: Implement the four core files**

  Decode `JSONValue` with `singleValueContainer`. Try the types in this order: `Bool`, `Double`, `String`, array, object, null.

- [ ] **Step 5: Run the tests and confirm they pass**

  Run: `swift test`. Expected: all pass.

- [ ] **Step 6: Commit**

  `git commit -m "Add core request decoding and decision encoding"`

---

### Task 2: Request summaries (card text)

**Files:**
- Create: `Sources/PermissionCore/RequestSummary.swift`
- Test: `Tests/PermissionCoreTests/SummaryTests.swift`

**Interfaces:**
- Consumes: `PermissionRequest`, `JSONValue`, `alwaysAllowUpdates`.
- Produces: `public struct RequestSummary: Equatable, Sendable`
  - Fields:
    - `headline: String` (the "Claude wants to …" text);
    - `primary: String?` (monospaced block);
    - `detail: String?`;
    - `cwd: String?` (with `~` abbreviation);
    - `alwaysAllowRules: [String]` (display strings such as `"Bash(npm install:*) — this project"`).
  - `public init(_ r: PermissionRequest, homeDirectory: String = NSHomeDirectory())`
  - `public static let maxPrimaryLength = 2000`

- [ ] **Step 1: Write failing tests**

  | Test | Input | Expected |
  |---|---|---|
  | `bashSummary` | the bash fixture | headline `"Claude wants to run a command"`, primary `"npm install express"`, detail `"Install express"`, cwd `"~/proj"` when home is `"/Users/me"`, rules `["Bash(npm install:*) — this project"]` |
  | `editSummary` | `Edit` with `file_path` | headline `"Claude wants to edit a file"`, primary is the path, detail starts with `"−"` and contains `old_string` and `new_string`, each capped at 200 chars |
  | `writeSummary` | `Write` | headline `"Claude wants to create a file"` |
  | `readSummary` | `Read` | headline `"Claude wants to read a file"` |
  | `grepSummary` | `Grep` / `Glob` | headline `"Claude wants to search files"`, primary is the pattern |
  | `webFetchSummary` | `WebFetch` | headline `"Claude wants to fetch a web page"`, primary is the URL |
  | `webSearchSummary` | `WebSearch` | headline `"Claude wants to search the web"`, primary is the query |
  | `mcpSummary` | `mcp__github__create_issue` | headline `"Claude wants to use create_issue from github"`, primary is the compact JSON of the input |
  | `exitPlanSummary` | `ExitPlanMode` with `plan` | headline `"Claude wants to approve its plan"`, primary is the first 6 lines of the plan |
  | `unknownToolSummary` | an unknown tool `Foo` | headline `"Claude wants to use Foo"`, primary is compact JSON |
  | `capsHugePrimary` | a 10,000-char command | `primary!.count <= 2001` and it ends with `"…"` |
  | `destinationLabels` | destinations | `localSettings` and `projectSettings` give `"this project"`, `userSettings` gives `"all projects"`, `session` gives `"this session"` |
  | `ruleWithoutContent` | rule `{"toolName":"WebSearch"}` | displays `"WebSearch — this project"` |

- [ ] **Step 2: Run, confirm failure; implement; run, confirm pass**

  Run: `swift test --filter SummaryTests`.

- [ ] **Step 3: Commit**

  `git commit -m "Add per-tool request summaries"`

---

### Task 3: Unix socket transport and app paths

**Files:**
- Create: `Sources/PermissionCore/AppPaths.swift`, `Sources/PermissionCore/SocketServer.swift`, `Sources/PermissionCore/SocketClient.swift`
- Test: `Tests/PermissionCoreTests/SocketTests.swift`

**Interfaces:**
- `public enum AppPaths`
  - `static let bundleIdentifier = "local.permission-popups"`
  - `static var supportDirectory: URL`
  - `static var socketPath: String`
  - `static var historyURL: URL`
  - `static func ensureSupportDirectory() throws` (creates the directory with mode 0700)
- `public final class SocketServer`
  - `public init(path: String, onRequest: @escaping (WireRequest, SocketResponder) -> Void)`
  - `public func start() throws`, which:
    - unlinks a stale file at the path;
    - binds and calls `chmod 0600`;
    - listens and accepts on a background `DispatchQueue`;
    - per connection: checks `getpeereid`, reads one `\n`-terminated line (max 8 MB, or closes), decodes `WireRequest`, then calls `onRequest` on the **main queue**.
  - `public func stop()`, which closes all connections and unlinks the file.
  - Throws `SocketError.pathTooLong` if `path.utf8.count >= 104`.
- `public final class SocketResponder`
  - `public func reply(_ r: WireReply)`, which writes JSON + `\n`, then closes. Calling it again does nothing.
  - `public var onClose: (() -> Void)?`
    - Fires on the main queue when the peer disconnects before `reply`.
    - Detected with a `DispatchSourceRead` on the fd: a 0-byte read means EOF.
  - `public let id: UUID`
- `public enum SocketClient`
  - `public static func exchange(path: String, line: Data) throws -> Data`
  - Connects and writes `line + "\n"`, then blocks until a `\n` or EOF. Returns the bytes before the `\n`.
  - Throws `.connectFailed` when the socket is missing or refused, and `.closed` on EOF without a line.

- [ ] **Step 1: Write failing tests**

  These use a temporary socket path under `/tmp/pp-test-<short uuid>.sock`. Keep it short, because of the 104-byte limit.
  - `roundTrip`: the server replies `WireReply(.allow)` from `onRequest`. The client exchange returns bytes that decode to `decision == "allow"`.
  - `clientFailsFastWithoutServer`: `exchange` on a missing path throws `.connectFailed` in under 100 ms.
  - `staleSocketIsReplaced`: create a regular file at the path, then `start()` succeeds and a round trip works.
  - `socketFileMode`: after `start()`, `stat` gives mode `0o600`.
  - `onCloseFiresWhenClientDisappears`: the client connects, sends a request, and closes its fd without reading. The server's `onClose` fires within 1 s. Use `confirmation` with a timeout loop.
  - `rejectsOversizeLine`: 9 MB without a newline makes the server close the connection, and the client gets `.closed`.
  - `pathTooLong`: a 120-char path throws `.pathTooLong`.
  - `supportPathsFitSocketLimit`: `AppPaths.socketPath.utf8.count < 104` for the current user.

- [ ] **Step 2: Run, confirm failure; implement; run, confirm pass**

  Run: `swift test --filter SocketTests`.

  Use `socket(AF_UNIX, SOCK_STREAM, 0)` and `sockaddr_un`. Set `SO_NOSIGPIPE` on the fds.

- [ ] **Step 3: Commit**

  `git commit -m "Add Unix socket transport with peer UID check"`

---

### Task 4: Hook helper

**Files:**
- Create: `Sources/PermissionCore/HookRunner.swift`
- Modify: `Sources/permission-hook/main.swift`
- Create: `scripts/integration-test.sh`
- Test: `Tests/PermissionCoreTests/HookRunnerTests.swift`

**Interfaces:**
- Consumes: `PermissionRequest(json:)`, `WireRequest`, `WireReply.toDecision()`, `ClaudeHookOutput.encode`, `SocketClient.exchange`.
- Produces: `public enum HookRunner { public static func run(stdin: Data, socketPath: String) -> Data? }`
  - Returns the stdout bytes to print, or nil for "print nothing".
  - Order of checks:
    1. Parse the input; on failure return nil.
    2. If the tool is `AskUserQuestion`, return nil.
    3. Exchange over the socket; on an error return nil.
    4. Decode the reply; on failure return nil.
    5. Encode the decision.

- [ ] **Step 1: Write failing tests**

  These use a test `SocketServer` from Task 3.
  - `allowFlowsThrough`: the server replies allow. The result parses to the allow output from Task 1.
  - `denyFlowsThrough` and `allowAlwaysFlowsThrough`: the same, for the other two decisions.
  - `passPrintsNothing`: nil.
  - `askUserQuestionSkipsSocket`: nil, and the server's `onRequest` is never called.
  - `noServerPrintsNothing`: nil.
  - `garbageInputPrintsNothing`, for each of these inputs:
    - `Data()`
    - `"{"`
    - `"[]"`
    - `{"hook_event_name":"PermissionRequest"}`
    - 5 MB of `"a"`

    Each returns nil.
  - `garbageReplyPrintsNothing`: the server writes `"nope\n"`, and the result is nil.

- [ ] **Step 2: Run, confirm failure; implement `HookRunner`; run, confirm pass**

- [ ] **Step 3: Write `main.swift`**

  - Read all of stdin with `FileHandle.standardInput.readDataToEndOfFile()`.
  - Install SIGTERM, SIGINT and SIGHUP handlers that call `_exit(0)`. The socket fd then closes and the app sees EOF.
  - Write the result to stdout if it isn't nil, then `exit(0)`.

- [ ] **Step 4: Write `scripts/integration-test.sh`**

  It builds with `swift build`, then pipes `Tests/PermissionCoreTests/Fixtures/bash.json` into `.build/debug/permission-hook` with no app running. It asserts:
  - empty stdout;
  - exit code 0;
  - wall time under 0.2 s.

  Run it: `bash scripts/integration-test.sh`. Expected: `OK`.

- [ ] **Step 5: Commit**

  `git commit -m "Add permission-hook helper"`

---

### Task 5: settings.json hook installer (pure logic)

**Files:**
- Create: `Sources/PermissionCore/HookSettings.swift`
- Test: `Tests/PermissionCoreTests/HookSettingsTests.swift`

**Interfaces:**
- `public enum HookStatus: Equatable { case notInstalled, installed, installedAtOtherPath(String) }`
- `public enum HookSettingsError: Error { case invalidJSON, unexpectedShape(String) }`
- `public enum HookSettings`
  - `static let timeout = 600`
  - `static func install(into existing: Data?, helperPath: String) throws -> Data`
  - `static func uninstall(from existing: Data, helperPath: String) throws -> Data`
  - `static func status(of existing: Data?, helperPath: String) -> HookStatus`
  - `static func entry(helperPath: String) -> JSONValue`. This is the exact entry from Global Constraints, and the confirm sheet shows it.
- An entry counts as "ours" if any hook's `command` has the last path component `permission-hook`. So a moved app is still recognised and replaced, not duplicated.
- Output is pretty-printed with sorted keys and a trailing newline.

- [ ] **Step 1: Write failing tests**

  **Installing**
  - `installIntoNil`: gives `{"hooks":{"PermissionRequest":[entry]}}`.
  - `installPreservesOtherKeys`: an existing `{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[...]}}` keeps `permissions` and `Stop` unchanged and adds `PermissionRequest`.
  - `installPreservesOtherPermissionRequestHooks`: someone else's `PermissionRequest` entry stays, and ours is appended.
  - `installIsIdempotent`: installing twice gives exactly one of our entries.
  - `installReplacesMovedApp`: an entry with `/Old/Path/permission-hook` is replaced by the new path, leaving one entry.

  **Bad files**
  - `invalidJSONThrows`: `"{ // comment"` throws `.invalidJSON`.
  - `nonObjectHooksThrows`: `{"hooks":[]}` throws `.unexpectedShape`.

  **Uninstalling and status**
  - `uninstallRemovesOnlyOurs`: other entries stay. If the `PermissionRequest` array becomes empty, the key is removed. If `hooks` becomes empty, it is removed too.
  - `statusReports`: `.notInstalled`, `.installed` and `.installedAtOtherPath("/Old/Path/permission-hook")` in the matching cases.

- [ ] **Step 2: Run, confirm failure; implement; run, confirm pass**

- [ ] **Step 3: Commit**

  `git commit -m "Add settings.json hook install logic"`

---

### Task 6: History store and request queue

**Files:**
- Create: `Sources/PermissionCore/HistoryStore.swift`, `Sources/PermissionCore/RequestQueue.swift`
- Test: `Tests/PermissionCoreTests/HistoryTests.swift`, `Tests/PermissionCoreTests/QueueTests.swift`

**Interfaces:**
- `public struct HistoryEntry: Codable, Equatable, Identifiable`
  - Fields: `id: UUID`, `date: Date`, `outcome: Outcome`, `tool: String`, `headline: String`, `primary: String?`, `cwd: String?`, `sessionPrefix: String`.
  - `public enum Outcome: String, Codable { case allowed, alwaysAllowed, denied, answeredElsewhere }`
- `public final class HistoryStore`
  - `init(fileURL: URL, limit: Int = 1000)`
  - `func append(_ e: HistoryEntry) throws` creates the file with mode 0600.
  - `func load() -> [HistoryEntry]` returns newest first and skips bad lines.
  - `func trim() throws` keeps the newest `limit`.
  - `func clear() throws`
  - Dates use ISO 8601.
- `public struct PendingRequest: Identifiable`
  - Fields: `id: UUID`, `request: PermissionRequest`, `summary: RequestSummary`, `arrived: Date`, `alwaysAllowUpdates: [JSONValue]`.
- `public final class RequestQueue: ObservableObject` (main-thread use only)
  - `@Published public private(set) var pending: [PendingRequest]`, oldest first
  - `var oldest: PendingRequest?`
  - `func add(_ p: PendingRequest, respond: @escaping (Decision) -> Void)`
  - `func resolve(id: UUID, with d: Decision) -> HistoryEntry.Outcome?`
    - Calls `respond`, removes the request, and returns the outcome.
    - Returns nil if the id is unknown.
  - `func expire(id: UUID) -> Bool`
    - Removes the request without calling `respond`.
    - Returns true if it was present.
  - `func passAll()` responds `.pass` to every request and clears the queue (used on quit).

- [ ] **Step 1: Write failing tests**

  **History**
  - `appendAndLoadNewestFirst`.
  - `fileModeIs0600`.
  - `trimKeepsLimit`: 1,005 appends then `trim()` leaves 1,000, and the newest survives.
  - `loadSkipsCorruptLine`.
  - `clearEmpties`.

  **Queue**
  - `oldestIsFirstAdded`.
  - `resolveCallsRespondOnceAndRemoves`: a second `resolve` on the same id returns nil, and `respond` was called exactly once.
  - `resolveMapsOutcomes`: allow gives `allowed`, allowAlways gives `alwaysAllowed`, deny gives `denied`.
  - `expireRemovesWithoutResponding`.
  - `outOfOrderResolution`: add 6, resolve #3 and #5, then `pending` holds ids 1, 2, 4, 6 in order and `oldest` is #1.
  - `passAllRespondsPass`.

- [ ] **Step 2: Run, confirm failure; implement; run, confirm pass**

- [ ] **Step 3: Commit**

  `git commit -m "Add history store and request queue"`

---

### Task 7: Panel layout math

**Files:**
- Create: `Sources/PermissionCore/PanelLayout.swift`
- Test: `Tests/PermissionCoreTests/LayoutTests.swift`

**Interfaces:**
- `public enum Corner: String, CaseIterable, Codable { case bottomLeft, bottomRight, topLeft, topRight }`
  - `var title: String`, which gives `"Bottom Left"` and so on.
- `public enum PanelLayout`
  - Constants: `static let width: CGFloat = 360`, `margin: CGFloat = 16`, `gap: CGFloat = 8`, `maxVisible = 4`.
  - `static func frames(heights: [CGFloat], corner: Corner, visibleFrame: CGRect) -> [CGRect]`
    - Takes the heights of the cards to show, oldest first, at most `maxVisible`.
    - Returns frames in the same order.
    - The oldest card sits nearest the corner, and later cards stack away from it (upward for bottom corners, downward for top corners).
  - `static func overflowPillFrame(afterLast: CGRect, corner: Corner) -> CGRect`. The pill is 28 pt tall and the same width.

- [ ] **Step 1: Write failing tests**

  The visible frame is `CGRect(x: 0, y: 25, width: 1440, height: 875)`. In AppKit, y grows upward.
  - `bottomLeftFirstCard`: `frames(heights:[120], .bottomLeft, vf)[0] == CGRect(x: 16, y: 41, width: 360, height: 120)`.
  - `bottomLeftStacksUp`: the second card's `y == 41 + 120 + 8`.
  - `bottomRightX`: `x == 1440 - 16 - 360`.
  - `topLeftFirstCard`: `maxY == 25 + 875 - 16`.
  - `topStacksDown`: the second card's `maxY == firstCard.minY - 8`.
  - `pillBeyondLastCard` for both a bottom and a top corner.
  - `offsetVisibleFrame`: with a second screen at `x: 1440`, the frames shift with it.

- [ ] **Step 2: Run, confirm failure; implement; run, confirm pass**

- [ ] **Step 3: Commit**

  `git commit -m "Add card stacking layout"`

---

### Task 8: Floating card UI and app wiring

**Files:**
- Modify: `Sources/PermissionApp/main.swift`
- Create:
  - `Sources/PermissionApp/AppDelegate.swift`
  - `Sources/PermissionApp/Preferences.swift`
  - `Sources/PermissionApp/CardPanel.swift`
  - `Sources/PermissionApp/CardView.swift`
  - `Sources/PermissionApp/PanelController.swift`
  - `Sources/PermissionApp/HotKeys.swift`

**Interfaces:**
- Consumes: `SocketServer`, `SocketResponder`, `RequestQueue`, `PendingRequest`, `RequestSummary`, `alwaysAllowUpdates`, `HistoryStore`, `PanelLayout`, `Corner`, `AppPaths`, `denyMessage`.
- Produces:
  - `final class Preferences: ObservableObject`, with these `@AppStorage`-style properties:
    - `popupsEnabled: Bool = true`
    - `soundEnabled: Bool = true`
    - `corner: Corner = .bottomLeft`
    - `openAtLoginInitialized: Bool = false`
  - `final class PanelController`
    - `init(queue: RequestQueue, prefs: Preferences, decide: @escaping (UUID, Decision) -> Void)`
    - It observes `queue.pending` and keeps one `CardPanel` per visible request, plus the pill.
    - `func highlightOldest()`
  - `final class HotKeys`
    - `init(onAllow: @escaping () -> Void, onDeny: @escaping () -> Void)`
    - `func register()` and `func unregister()`
  - `AppDelegate.decide(id: UUID, decision: Decision)` is the single path every decision goes through: `queue.resolve` + history append.

**How it fits together:**
- **`AppDelegate.applicationDidFinishLaunching`:**
  - Set `NSApp.setActivationPolicy(.accessory)`.
  - Call `AppPaths.ensureSupportDirectory()` and `history.trim()`.
  - Start the `SocketServer(path: AppPaths.socketPath)`, register the hotkeys, and create the `PanelController`.
  - If `!prefs.openAtLoginInitialized`, register `SMAppService.mainApp` and set the flag.
- **`onRequest`:**
  - Decode `PermissionRequest(json:)` from `wire.request` by re-encoding it. If it fails, `reply(.pass)`.
  - If `!prefs.popupsEnabled`, `reply(.pass)`.
  - Otherwise build a `PendingRequest` and call `queue.add` with `respond = { responder.reply(WireReply($0)) }`.
  - Set `responder.onClose = { if queue.expire(id) { history.append(.answeredElsewhere) } }`.
  - If sound is on, play `NSSound(named: "Tink")`.
- **`applicationWillTerminate`:** `queue.passAll()`, then `server.stop()`.
- **`CardPanel: NSPanel`:**
  - styleMask `[.nonactivatingPanel, .borderless, .fullSizeContentView]`
  - `level = .statusBar`
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
  - `hidesOnDeactivate = false`, `isFloatingPanel = true`, `becomesKeyOnlyIfNeeded = true`
  - `backgroundColor = .clear`, `hasShadow = true`
  - Override `canBecomeKey` to return `true`, so a click makes it key without activating the app.
  - Override `keyDown`: Return or Enter (keyCodes 36, 76) goes to `onAllow`, and Escape (53) goes to `onDeny`.
  - Show it with `orderFrontRegardless()` only.
- **`CardView` (SwiftUI):**
  - `NSVisualEffectView` with `.hudWindow`/`.popover` material and a 14 pt corner radius.
  - Layout follows spec 5.4: headline row with an elapsed timer, then a monospaced primary block (`lineLimit` 6 inside a `ScrollView` with max height of about 6 lines), then detail, cwd and the Always Allow rule lines.
  - Buttons: Deny / Always Allow (only if `!alwaysAllowUpdates.isEmpty`) / Allow, with Allow as the default-styled button.
  - A small "next" dot when this card is the oldest (the one the hotkeys target).
  - The hover highlight is visual only.
- **`PanelController`:**
  - Measure each card's height with `NSHostingView.fittingSize` at width 360.
  - Position the cards with `PanelLayout.frames` on the screen that contains `NSEvent.mouseLocation`, decided when a card first appears.
  - Fade in over 0.15 s with `NSAnimationContext` and `animator().alphaValue`.
  - On removal, fade out and reflow the rest.
- **`HotKeys`:**
  - Use Carbon `RegisterEventHotKey`: keycode 36 for allow and 53 for deny, modifiers `controlKey | optionKey`.
  - Install the handler with `InstallEventHandler(GetApplicationEventTarget(), …)`.
  - The handlers act on `queue.oldest`.

- [ ] **Step 1: Implement the files above**

  Run `swift build`. Expected: it builds with no warnings about main-actor isolation. Keep the app target in the Swift 5 language mode.

- [ ] **Step 2: Manual smoke test of the card without Claude**

  Run the app with `swift run PermissionApp`. In another shell, pipe the fixtures in:
  `for f in bash edit mcp bash bash bash; do .build/debug/permission-hook < Tests/PermissionCoreTests/Fixtures/$f.json & done`.

  Check all of these:
  - 4 cards appear bottom-left, plus a "+2 more" pill.
  - The frontmost app (for example TextEdit, while typing) keeps keyboard focus.
  - Clicking a card and pressing Return makes that helper print the allow JSON.
  - ⌃⌥Escape from TextEdit denies the oldest card.
  - `kill` on a waiting helper's pid removes its card.
  - A 10,000-char command is bounded and scrolls.
  - Quitting the app makes the remaining helpers exit with no output.

  Capture a screenshot with `screencapture -x` for the record.

- [ ] **Step 3: Commit**

  `git commit -m "Add floating cards, hotkeys and app wiring"`

---

### Task 9: Menu bar, history window, hook install flow, login item

**Files:**
- Create: `Sources/PermissionApp/StatusMenu.swift`, `Sources/PermissionApp/HistoryWindow.swift`, `Sources/PermissionApp/HookInstallFlow.swift`
- Modify: `Sources/PermissionApp/AppDelegate.swift`

**Interfaces:**
- Consumes: `RequestQueue`, `Preferences`, `HistoryStore`, `HookSettings`, `HookStatus`, `Corner`.
- Produces: `final class HookInstallFlow`
  - `static var settingsURL: URL` (`~/.claude/settings.json`)
  - `static var helperPath: String`: `Bundle.main.bundleURL/Contents/MacOS/permission-hook`. Under `swift run`, it is the sibling `permission-hook` in the executable's directory.
  - `func install(presentingConfirm: Bool = true) throws` and `func uninstall() throws`
  - `var status: HookStatus`

**What to build:**
- **Status item:**
  - SF Symbol `checkmark.shield`; `checkmark.shield.fill` plus a badge count when anything is pending.
  - The menu is exactly as in spec 5.6.
  - The "Open at Login" toggle calls `SMAppService.mainApp.register()` or `unregister()`, and shows `status == .enabled`.
  - "Position" sets `prefs.corner` and reflows the cards immediately.
  - The hook row depends on the hook's status:
    - `.notInstalled` shows "Install Claude Code Hook…".
    - `.installed` shows "Hook: Installed ✓", with a submenu item "Uninstall Claude Code Hook".
    - `.installedAtOtherPath` shows "Hook points to an old location — Reinstall…".
  - The status is refreshed every time the menu opens (`menuWillOpen`).
- **Install flow:**
  1. Show an `NSAlert` with an accessory `NSTextView` containing the pretty JSON from `HookSettings.entry` and the target path.
  2. On confirm:
     - If the file exists, copy it to `settings.json.bak-<yyyyMMdd-HHmmss>`.
     - Create `~/.claude` if it is missing.
     - Write `HookSettings.install` output atomically (`Data.write(options: .atomic)`).
  3. If `HookSettingsError` is thrown, show an alert that names the problem and leave the file untouched.
- **History window:**
  - One `NSWindow` hosting a SwiftUI `List` of `history.load()`.
  - Each row shows outcome icon, headline, primary (one line, monospaced), cwd and relative time.
  - "Clear History" asks for confirmation.
  - Opening the window calls `NSApp.activate`. This is the one place the app takes focus, and only because the user explicitly asked.

- [ ] **Step 1: Implement**

  Run `swift build`. Expected: it builds.

- [ ] **Step 2: Manual check against a temporary HOME**

  Run with `HOME=/tmp/pp-home swift run PermissionApp`. Confirm `HookInstallFlow.settingsURL` honors `HOME` (it uses `FileManager.default.homeDirectoryForCurrentUser`, which follows `HOME`). Then:
  - Install, and confirm `/tmp/pp-home/.claude/settings.json` holds the entry.
  - Install again: there is still one entry, and a backup file exists.
  - Uninstall: the entry is removed.
  - The history window lists the decisions from the Task 8 smoke run.

- [ ] **Step 3: Commit**

  `git commit -m "Add status menu, history window and hook installer UI"`

---

### Task 10: App bundle, install script, Makefile

**Files:**
- Create: `Resources/Info.plist`, `scripts/build-app.sh`, `Makefile`

**What each file contains:**
- **`Info.plist`:**
  - `CFBundleIdentifier` `local.permission-popups`
  - `CFBundleName` and `CFBundleDisplayName` `Permission Popups`
  - `CFBundleExecutable` `PermissionApp`
  - `CFBundlePackageType` `APPL`
  - `LSUIElement` true
  - `LSMinimumSystemVersion` 13.0
  - `CFBundleShortVersionString` 0.1.0
  - `NSHumanReadableCopyright` empty
  - No custom `.icns` in v1, so the system default icon is used. The app only shows in the menu bar, where an SF Symbol is used. This is a deliberate trim of the spec's "AppIcon".
- **`build-app.sh`:**
  1. `swift build -c release --arch arm64 --arch x86_64`. If the universal build fails under the Command Line Tools, fall back to the host architecture and print a note.
  2. Assemble `dist/Permission Popups.app/Contents/{MacOS,Resources,Info.plist}` and copy both executables into `MacOS/`.
  3. Sign ad hoc: `codesign --force --deep --sign - "dist/Permission Popups.app"`.
  4. Verify with `codesign --verify`.
- **`Makefile` targets:**
  - `build` (`swift build`)
  - `test` (`swift test` plus `scripts/integration-test.sh`)
  - `app` (`scripts/build-app.sh`)
  - `install`: `make app`, then copy to `/Applications/Permission Popups.app`, replacing any existing copy after quitting the running instance with `osascript -e 'quit app "Permission Popups"'`. Then `open` it.
  - `uninstall`: quit the app and delete it from `/Applications`. It prints a reminder to uninstall the hook from the menu first.
  - `clean`

- [ ] **Step 1: Implement, then run `make test && make app`**

  Expected:
  - The tests pass.
  - `dist/Permission Popups.app` exists.
  - `codesign --verify` exits 0.
  - `du -sh` is under 10 MB.

- [ ] **Step 2: Run `make install`**

  Confirm that the menu bar icon appears, there is no Dock icon, and "Open at Login" shows as checked. Measure idle memory with `ps -o rss= -p $(pgrep PermissionApp)`, and record the value (target under 60 MB RSS).

- [ ] **Step 3: Commit**

  `git commit -m "Add app bundling and Makefile"`

---

### Task 11: Documentation

**Files:**
- Create: `README.md`, `docs/architecture.md`, `LICENSE` (MIT, with the copyright holder line left as `<your name>` for the user to fill in)

**What each document covers:**
- **README sections:**
  - What it does (two sentences, no branding)
  - Requirements (macOS 13+, Command Line Tools / Swift 6)
  - Install (`make install`, then menu → Install Claude Code Hook…)
  - Manual hook configuration: the JSON, plus a note that `timeout` can be lowered
  - Usage: the buttons, Enter and Escape after clicking, ⌃⌥↩ and ⌃⌥⎋
  - Configuration: the menu items
  - Where data lives (support dir, history)
  - Uninstall
  - Development (`make build/test/app`, the layout of the targets)
  - Troubleshooting: Gatekeeper on downloaded builds, the hook not firing until a new Claude session, and the app not running meaning Claude's normal prompt
  - Limitations
  - Note that the app has no environment variables or secrets, so there is no `.env`.
- **`docs/architecture.md`:**
  - The sequence diagram from spec 5.1
  - The wire protocol
  - The security model: socket permissions and peer UID, never deciding by default, deny rules always win, filtering of Always Allow suggestions, no HTTP hook and why
  - The request lifecycle, including "answered elsewhere"
  - The results of the three verification items from spec section 3, filled in from Task 12

- [ ] **Step 1: Write the docs**

  Check that every command in the README has been run during Tasks 1–10.

- [ ] **Step 2: Commit**

  `git commit -m "Add README and architecture docs"`

---

### Task 12: End-to-end testing in the Claude desktop app (with the user)

There is no code in this task, unless a defect is found (then use superpowers:systematic-debugging).

- [ ] **Step 1: Install the hook**

  The installed app is running. Use menu → Install Claude Code Hook… and confirm the real `~/.claude/settings.json`. Show the user the resulting file.

- [ ] **Step 2: Start a fresh Code-tab session with permission prompts on**

  The session uses the default "ask" mode, not auto. Ask Claude to run `echo hello-from-popup` with Bash.

  Expected:
  - A card appears while the user is in another app, and focus doesn't change.
  - Allow makes Claude continue and print the output.
  - Claude's own prompt disappears.

- [ ] **Step 3: Deny**

  Ask Claude to run `touch /tmp/pp-deny-test`, then Deny. Expected:
  - Claude reports the denial message.
  - `/tmp/pp-deny-test` does not exist.

  This confirms the deny output shape from the spec's verification list.

- [ ] **Step 4: Always Allow**

  Use a command with a suggestion, such as `npm --version`. Expected:
  - The rule appears in `.claude/settings.local.json` of that project.
  - Running the command a second time doesn't prompt.

- [ ] **Step 5: Several requests at once**

  Ask Claude to run 3 commands in parallel, or use subagents. The cards stack, and both hotkeys work from another app.

- [ ] **Step 6: Answer elsewhere**

  Answer a request in Claude's own prompt instead. Record whether the card disappears, which means Claude killed the helper. If it doesn't, record the known limitation.

- [ ] **Step 7: Other conditions**

  - **Full-screen app or another Space:** the card is visible.
  - **Popups off:** only Claude's prompt appears.
  - **App quit:** only Claude's prompt appears, with no delay.

- [ ] **Step 8: Record the results**

  Write the results into the `docs/architecture.md` verification section. Commit with `git commit -m "Record end-to-end verification results"`.

- [ ] **Step 9: Stop before publishing**

  Run `git status` and `git log`, and grep for the home path, email address and tokens:
  `git grep -nE "$(whoami)|@gmail|sk-ant|api[_-]?key" || echo clean`. Build the pattern at run time, so that the username is never written into a committed file.

  Hand the repo to the user for review. Nothing is pushed. The `gh` CLI isn't installed, so publishing waits until the user approves the repository.

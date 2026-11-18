# AGENTS.md — maintenance guide for oscontrol

This file is for any AI coding agent (or human) who changes, tests, documents, or releases **oscontrol**. Read it fully before editing. If something here conflicts with what you observe in the code, trust the code, then fix this file in the same change.

---

## 1. What this project is

oscontrol is a single macOS binary (Swift, no third-party dependencies) that gives software agents and people:

- **Screen capture** of every connected display, returned as JPEG/PNG with exact coordinate metadata.
- **Mouse control**: move, click (left/right/middle, single/double/triple), press-hold-release, drag, scroll.
- **Keyboard control**: named keys with modifiers, and text typing.
- **Two interfaces over the same code**:
  1. a **CLI** (`oscontrol <command>`), and
  2. an **MCP server** over stdio (`oscontrol mcp`), usable by any MCP client.

It targets macOS 13+ on Apple Silicon. Windows is a planned future port; do not add Windows code paths without a design discussion.

The primary audience is LLM agents that need to "see and act" on a Mac, so **tool names, argument names, output shapes, and the server instructions are public API**. Treat changes to them as breaking changes.

---

## 2. Repository map

```
oscontrol/
├── AGENTS.md                         ← this file
├── README.md                         ← product page / user documentation
├── CHANGELOG.md                      ← every released change, newest first
├── Package.swift                     ← SwiftPM: products `oscontrol` and `oscontrol-fixture`
├── .github/workflows/ci.yml          ← CI: build + tests/ci/check_protocol.py only
├── .gitignore
├── Sources/oscontrol/main.swift      ← THE product: CLI, MCP server, capture, input, benchmark
├── tests/
│   ├── ci/check_protocol.py          ← permission-free checks (the only tests CI runs)
│   ├── fixture/main.swift            ← test-only AppKit window with known UI elements + state recorder
│   └── e2e/
│       ├── run_e2e.py                ← end-to-end test runner (45 tests, Python 3 standard library only)
│       └── run_e2e.sh                ← builds, then runs run_e2e.py
├── scripts/
│   ├── install.sh                    ← release build → ~/.local/bin/oscontrol (copy, not symlink)
│   └── register-harnesses.sh         ← registers/removes the MCP server in each AI harness via its own CLI
└── docs/
    ├── llm-usage.md                  ← instructions to give an agent that uses oscontrol
    ├── images/                       ← README images (must not contain personal or third-party content)
    └── harnesses/
        ├── README.md                 ← install, support matrix, tool reference, troubleshooting
        ├── claude-code.md
        ├── pi.md
        ├── grok.md
        ├── agy.md
        └── kiro-cli.md
```

**Where things live in `Sources/oscontrol/main.swift`** (in file order):

| Section | Responsibility |
|---|---|
| Errors, JSON, `Args` | `ControlError`, `jsonString`, minimal `--name value` parser |
| Argument helpers | `num`, `optInt`, `str`, `strings` — shared by CLI and MCP |
| `DisplayInfo`, `Desktop` | display enumeration (`CGGetActiveDisplayList`), capture (`CGDisplayCreateImage`), JPEG/PNG encoding and downscale |
| `Input` | every event injection: move, click, down/up, drag, scroll, key, type, held-button detection, release logic |
| `runTool(name, args)` | **single dispatcher** for all tools; used by both the CLI and the MCP server |
| `schema`, `toolDefinitions()` | MCP tool schemas (what clients see in `tools/list`) |
| `serverInstructions` | text sent to clients in the `initialize` result |
| `runMCP()` | JSON-RPC 2.0 over stdin/stdout, one message per line |
| `runBenchmark` | capture-method timing (informational) |
| `usageText`, `runCLI` | CLI parsing and dispatch |

`tests/fixture/main.swift` is a separate executable (`oscontrol-fixture`). It must stay independent of the product code: it is a deterministic target the tests drive, not a library.

---

## 3. Environment

| Requirement | Value used to build and test |
|---|---|
| OS | macOS 27.2 (arm64). The code targets macOS 13+ (`Package.swift`). |
| Toolchain | Swift 6.4.2 (`swift --version`). `Package.swift` uses `swift-tools-version: 5.9`, which keeps Swift 5 language mode. |
| Python | 3.15 used for the test runner. Only the standard library is used. |
| Shell tools | `osascript`, `pbcopy`, `pbpaste`, `sips`, `screencapture` (all ship with macOS) |
| Permissions | The **terminal (or IDE) running the tests** needs **Accessibility** and **Screen & System Audio Recording**. Run `oscontrol doctor` to check. |

There are **no third-party Swift packages and no Python packages**. Do not add dependencies without a strong reason and a note in this file.

---

## 4. Commands you will use

```bash
# Build (debug, includes the test fixture)
swift build

# Release build + install to ~/.local/bin/oscontrol (copy)
scripts/install.sh

# Check permissions (must report all three true)
.build/debug/oscontrol doctor

# Permission-free checks (what CI runs; also safe on any Mac)
swift build -c release --product oscontrol
python3 tests/ci/check_protocol.py .build/release/oscontrol

# Full end-to-end suite: builds, then runs all 45 tests (≈ 2.5 minutes). Needs permissions; run locally only.
tests/e2e/run_e2e.sh

# Subset, and listing
tests/e2e/run_e2e.sh --only drag
tests/e2e/run_e2e.sh --list

# Report of the last run (JSON), written by the runner
cat /tmp/oscontrol-e2e/report.json

# Register / unregister the MCP server in installed harnesses
scripts/register-harnesses.sh --dry-run
scripts/register-harnesses.sh --remove
```

Run the **full** suite at least twice after touching input, timing, or the fixture (see §8 on flakiness). A single green run is not enough evidence.

---

## 5. Public contracts (do not break silently)

### 5.1 Coordinates
- All `x`/`y` values are **global desktop points** (not Retina pixels), origin = top-left of the **main** display. Secondary displays may have negative coordinates.
- Screenshot metadata (`origin_points`, `size_points`, `source_pixels`) is how a client maps image pixels to points. Keep these three keys in every screenshot response.

### 5.2 MCP tools (11)
`displays`, `screenshot`, `mouse_position`, `mouse_move`, `mouse_click`, `mouse_down`, `mouse_up`, `mouse_drag`, `mouse_scroll`, `key_press`, `type_text`.

- Names and argument names are snake_case (`display_id`, `max_width`, `delta_y`, `duration_ms`, `modifiers`, …).
- `modifiers` accepts an array **or** a comma-separated string of `command`, `control`, `option`, `shift` (`option`/`alt` and `command`/`cmd`/`meta` are aliases in `Input.flags`).
- Tool errors are returned as a successful JSON-RPC result with `isError: true` and a text block (so the model can read and recover). Unknown JSON-RPC methods return the standard error `-32601`. Messages without an `id` (notifications) get no response.
- `screenshot` returns one text block (JSON per display, one line each) followed by one `image` block per display (`mimeType` `image/jpeg` or `image/png`).

### 5.3 CLI
Commands: `displays`, `screenshot`, `mouse position|move|click|down|up|drag|scroll`, `key press`, `type`, `doctor`, `permissions`, `benchmark`, `mcp`, `version`, `help`.

- Success: exit 0. Output is JSON or the word `ok`.
- Failure: message on stderr, exit 1.
- The CLI and MCP share `runTool`. If you add a capability, add it to `runTool` first and wire the CLI to it, so the two cannot diverge.

### 5.4 Server instructions
`serverInstructions` is sent to every MCP client in `initialize`. It is the cheapest way to improve every harness at once. Changing it changes agent behavior everywhere, so keep it accurate and short, and update `docs/llm-usage.md` to match.

### 5.5 Version
`oscontrolVersion` in `main.swift` is reported by `oscontrol --version` and in the MCP `serverInfo`. Bump it on every release (see §9).

---

## 6. Platform facts learned the hard way

Each of these was verified by a test or a manual experiment. Do not "simplify" them away without re-running the suite.

1. **Event source and tap.** Input is posted with `CGEventSource(stateID: .hidSystemState)` to `.cghidEventTap`. This is the combination the whole suite is validated with; changing it requires a full re-run.
2. **Key hold time.** Key-down and key-up are separated by about 25 ms. Without it, Electron apps (VS Code) silently dropped shortcuts such as Command+N.
3. **Unicode typing.** Unicode-only key events (keycode 0 plus a Unicode payload) were ignored by VS Code. `Input.type` therefore sends real key codes, with Shift for capitals and shifted symbols, and uses Unicode events only for characters with no US key code.
4. **Held-button moves.** `mouse move` checks `CGEventSource.buttonState` and posts a *dragged* event when a button is held. Without this, `mouse down` → `move` → `up` does not drag.
5. **Click count.** Double/triple clicks set `mouseEventClickState` (1, 2, 3). Two separate clicks are not a double click for text editors.
6. **Release re-sends the final drag position.** The window server may coalesce drag events under load. Before the release, `Input.release` re-posts the drag position if a button is still down.
7. **Scroll routing.** The window server routes wheel events to the window under the pointer at the time it processes them. `Input.scroll` posts the pointer move, waits ~80 ms, and then posts the wheel event. Scroll events also set continuous pixel deltas (`scrollWheelEventIsContinuous`, point deltas).
8. **Scroll sign.** Positive `delta_y` scrolls content up (wheel up). Negative scrolls content down. Tests and docs depend on this.
9. **Menu-bar shortcuts need an Edit menu.** A bare AppKit app has no key equivalents for Command+X/C/V/A/Z. The fixture therefore builds an Edit menu. Your own AppKit apps need the same.
10. **Popup menus and Accessibility.** Right-click popup menus are not reliably exposed through Accessibility (`System Events`). The fixture places a known menu item under the click point instead, and the tests click that point.
11. **Scroll-event exception trap (fixture).** Reading `clickCount` or `buttonNumber` on an `NSEvent` of type `scrollWheel` raises an Objective-C exception, which silently stalls AppKit event dispatch. The fixture reads those properties only for mouse events.
12. **Timers during menu tracking.** Menu tracking uses its own run-loop mode. The fixture's state timer is registered in `.common` mode and flushes state before opening a menu.
13. **First-click activation.** A view that does not accept first mouse may swallow the click that activates a background window. The fixture's draggable box and context view return `true` from `acceptsFirstMouse`.
14. **Mouse-moved and scroll delivery.** AppKit delivers mouse-moved events to the key window only, and `acceptsMouseMovedEvents` must be true. The fixture waits for `keyWindow` before every test.
15. **Labels that steal clicks.** A text label on top of a target intercepts right-clicks. The fixture uses a pass-through label.
16. **Clipboard and smart cut.** macOS "smart cut" also removes an adjoining space. Tests accept either spacing.
17. **Pointer updates are asynchronous.** `CGEvent` posts are processed later; `mouse position` may briefly lag. Poll instead of sleeping for a fixed time (see `pointer_at` in the runner).
18. **Permissions attach to the host app.** For an MCP child, macOS uses the app that launched the process (terminal, IDE, desktop harness). `doctor` run inside that process reflects what the server sees.
19. **Screen capture method.** `CGDisplayCreateImage` measured ≈ 61 ms per capture against ≈ 166 ms for `screencapture` to disk (3 samples, 2 displays). It is deprecated in newer SDKs; ScreenCaptureKit is the successor (see §10).

---

## 7. Testing

### 7.1 Architecture
- `tests/fixture/main.swift` (`oscontrol-fixture`) opens a 900×620 window with: a text view (`The quick brown fox / jumps over the lazy dog / third line here`), a draggable red box, a button, a text field, a right-click context menu (Alpha, Beta, Gamma, Delete), and a scroll view with 80 lines.
- It records every mouse, scroll, and key event (global top-left coordinates) and writes a JSON state file every 0.1 s. Fields include `events`, `text`, `selectedRange`, `selectedText`, `wordRects`, `boxRect`, `buttonRect`, `pressCount`, `fieldRect`, `field`, `contextRect`, `menuOpenCount`, `menuAnchor`, `lastMenuChoice`, `scrollY`, `scrollRect`, `keyWindow`, `frontmostPid`, `ready`.
- `SIGUSR1` makes the fixture activate itself and become key. The runner sends it before every test.
- `tests/e2e/run_e2e.py` launches a **fresh fixture per test** (own state file under `/tmp/oscontrol-e2e/`), drives it only through the `oscontrol` binary (CLI or MCP), and asserts on the state file or on sampled screenshot pixels.

### 7.2 Rules for tests
- **Drive through the public interface.** Tests must call `oscontrol` (CLI or `mcp`), never the fixture's internals. The only exception is reading state.
- **Assert on observable effects**: state fields, clipboard contents, file bytes, image pixels. Do not assert on log text.
- **One fixture per test.** Never share state between tests.
- **Wait, don't sleep, for effects**: use `f.wait(predicate, timeout)` or `pointer_at(...)`. Fixed sleeps are allowed only to give the OS time to route an event.
- **Screenshot tests must delete their files** (`discard(...)` in `finally`). Screenshots capture the whole display.
- **Use tolerances** for pixel and point comparisons (±1–3 points).
- **Add a test for every new user-visible operation**, and register it in the coverage table in `README.md`.

### 7.3 Adding a test
```python
@test("area: what the user does, in plain words")
def _(f):
    x, y = center(f.state()["buttonRect"])
    cli_ok("mouse", "click", x, y)                  # act through the CLI
    f.wait(lambda s: s["pressCount"] == 1, desc="button pressed once")   # assert via state
```
If the fixture lacks the element you need, add it to `tests/fixture/main.swift`, expose its rectangle and state in `Store.snapshot()`, and document the field in §7.1.

### 7.4 Flakiness policy
The suite has, at times, shown intermittent failures from OS-level event timing (dropped pointer moves, coalesced drags, scroll routing). The policy is:

1. **Find the cause first.** Reproduce in a loop by hand (launch fixture, activate, act, read the state file). Log the event sequence. Do not just add retries.
2. **Fix the product or the fixture** when the cause is in them. Examples in this repo: the scroll routing delay, drag release re-send, `acceptsFirstMouse`, key-window waits.
3. **Re-send only where the OS is known to drop events** (pointer moves, hover). The runner records every re-send in its output (`note: N pointer move(s) had to be re-sent`). If the count rises, investigate.
4. **Never weaken an assertion** to make a test pass.
5. Before declaring a change done: **three consecutive full runs, all 45 passing**.

### 7.5 Known test-harness pitfalls
- A fixture left running from an earlier interrupted run can write to shared state. The runner now kills stale `oscontrol-fixture` processes at startup and uses unique state files.
- `pbcopy`/`pbpaste` affect the real clipboard. Tests overwrite it. Do not run tests while relying on the clipboard.
- Tests move the real pointer and type into whatever has focus during the run. Do not run them while using the Mac.

---

## 8. Documentation rules (keep these in sync)

Whenever you change behavior, update every place that describes it. Use this checklist.

| If you change… | Also update |
|---|---|
| a tool's name, arguments, or result | `toolDefinitions()`, `runTool`, CLI mapping, `README.md` tool table, `docs/harnesses/README.md` §5, `docs/llm-usage.md`, `serverInstructions`, `tests/e2e/run_e2e.py` (MCP tests), `CHANGELOG.md` |
| a CLI command or flag | `usageText`, `runCLI`, `README.md` CLI table, `docs/harnesses/README.md` §6, `CHANGELOG.md` |
| server instructions | `serverInstructions`, `docs/llm-usage.md`, `AGENTS.md` §5.4 |
| input behavior (timing, events) | `AGENTS.md` §6 (add the lesson), `README.md` "Implementation notes", tests that prove it |
| the fixture or test coverage | `AGENTS.md` §7, `README.md` testing table and test count (currently 45) |
| registration or install behavior | `scripts/*.sh`, `docs/harnesses/*.md` for that harness, `AGENTS.md` §2 |
| harness support | `docs/harnesses/README.md` support matrix (state what was *verified*, not what is expected) |
| version | `oscontrolVersion`, `CHANGELOG.md`, `README.md` status line |

**Documentation honesty rule:** only write "verified" when you ran the check in this environment and can say how. Mark anything else "not yet verified". The harness pages are the model for this.

**Images in docs** must show only the fixture window or synthetic content. Never commit a screenshot of a real desktop.

---

## 9. Release process

1. Make the change, with tests (§7) and documentation (§8).
2. Run `tests/e2e/run_e2e.sh` three times; all 45 must pass each time.
3. Bump `oscontrolVersion` (semver: breaking tool/CLI changes → major; new tools/flags → minor; fixes → patch). Pre-1.0, a minor bump may include breaking changes, but say so in `CHANGELOG.md`.
4. Add a `CHANGELOG.md` entry under a new version heading with the date. Group under Added / Changed / Fixed / Removed.
5. Update the README status line and the test count if it changed.
6. `scripts/install.sh`, then `oscontrol --version`, then `scripts/register-harnesses.sh` only if the install path or registration changed.
7. Commit with a clear message (imperative mood, first line ≤ 72 characters), then tag: `git tag -a vX.Y.Z -m "vX.Y.Z"`.
8. Push and create a GitHub release with the changelog section as its notes. Do not attach binaries built on your own machine unless you have checked they run on a clean machine.

---

## 10. Roadmap and open decisions

| Item | Status | Notes |
|---|---|---|
| License | **Decision needed** | The repository has no license file. Without one, nobody may legally use or modify the code. Choose one (for example MIT or Apache-2.0) with the owner and add `LICENSE`. |
| Publication approval | **Decision needed** | Confirm that publishing this project is approved by the owning organization before any change that makes it public. |
| Windows support | Not started | Would need a separate input and capture backend. Keep the `runTool` contract identical. |
| Accessibility-tree targeting | Idea | Read AX element frames to target controls by name rather than pixels. |
| ScreenCaptureKit capture | Idea | Successor to `CGDisplayCreateImage`. Needs re-measurement and permission testing. |
| Clipboard-paste typing | Idea | Faster for long text. Must restore the user's clipboard. |
| Live harness sessions | Partly done | Kiro CLI and Agy have not been exercised from an interactive session (see `docs/harnesses/`). |
| CI | Active, permission-free only | `.github/workflows/ci.yml` builds the release binary and runs `tests/ci/check_protocol.py` (21 checks: CLI errors, MCP handshake, tool list, error codes). It passed on a GitHub-hosted runner (Xcode 26.6, Swift 6.3.3). The end-to-end suite is **not** run in CI: hosted runners cannot grant Accessibility or Screen Recording. Run it locally. |

---

## 11. Security and privacy rules

- **Never commit secrets, tokens, keys, or personal data.** The repository must contain no names of people, customers, or internal systems. Use placeholders such as `/Users/you/` in docs.
- **Commit identity**: use the project's configured author. Do not commit with a corporate address into a public repository unless the owner has approved it.
- **Screenshots are sensitive by nature.** The tool captures everything on screen. Tests delete their images. Never write screenshots into the repository, and never include them in docs or issues.
- **Do not add telemetry, network calls, or auto-update** to the binary. It works offline and does only what the user asks.
- **Do not weaken macOS protections.** Do not add code that tries to bypass permission prompts, TCC, or the secure-input mode.
- **Do not change the user's harness configuration except through `scripts/register-harnesses.sh`**, which calls each harness's own `mcp add` / `mcp remove` command.
- **Input injection is powerful.** Any new tool that types, clicks, or reads the screen must be documented with its risks in `docs/harnesses/README.md` (safety) and in `serverInstructions` if it changes what the model should confirm.
- **Safety in the model's instructions** is advisory. Do not rely on it as a control. Do not add features that make it easier to act silently in sensitive apps.

---

## 12. Definition of done

A change is done only when all of the following hold:

- [ ] It builds: `swift build` (and `scripts/install.sh` if the binary changed).
- [ ] `python3 tests/ci/check_protocol.py .build/release/oscontrol` passes (this is what CI runs).
- [ ] The full suite passed three consecutive times: `tests/e2e/run_e2e.sh` (45/45).
- [ ] New behavior has a test; the coverage table in `README.md` reflects it.
- [ ] Every item in the §8 checklist for the kind of change is updated.
- [ ] `CHANGELOG.md` has an entry under "Unreleased" (or the release heading).
- [ ] No personal data, secrets, or real-desktop screenshots were added.
- [ ] Anything not verified is labeled as such in the docs.

---

## 13. Glossary

- **Global desktop point**: the coordinate unit used by macOS for pointer positions; equal to a logical pixel. Retina displays have 2 physical pixels per point.
- **Fixture**: the deterministic test window (`oscontrol-fixture`).
- **Harness**: an AI agent application or CLI that can use MCP servers (Claude Code, Kiro CLI, Pi, Agy, Grok, and others).
- **Held-button move**: a pointer move while a mouse button is down, posted as a drag event.
- **Key window**: the window that receives keyboard input and, in AppKit, mouse-moved events.

---

## 14. How to work on this project as an agent

1. Read this file, then `README.md`, then the code paths you will touch.
2. Check the state: `git status` (once the repository is initialized), `swift build`, `oscontrol doctor`.
3. Make small, verifiable changes. Prefer one concern per change.
4. Reproduce bugs with a short manual script before writing a test for them.
5. Keep the public contracts in §5 stable. If you must change one, update §5, the docs (§8), and the changelog in the same change, and say so in your summary to the owner.
6. Report honestly: list what you ran, what passed, and what you could not verify (for example, live harness sessions or behavior on other macOS versions).

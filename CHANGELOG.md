# Changelog

All notable changes to oscontrol are recorded here, newest first. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow [Semantic Versioning](https://semver.org/)
(while below 1.0.0, minor releases may contain breaking changes; they are always listed under *Changed* or *Removed*).

## [Unreleased]

### Added
- Continuous integration (`.github/workflows/ci.yml`): builds the release binary and runs the permission-free protocol checks in `tests/ci/check_protocol.py`. The end-to-end suite is not run in CI.

## [0.2.0] - 2026-11-18

### Added
- Mouse: `mouse drag`, `mouse down`, `mouse up`, `mouse position`, and MCP tools `mouse_drag`, `mouse_down`, `mouse_up`, `mouse_position`.
- Modifiers on mouse and key actions (`--modifiers command,control,option,shift`; MCP `modifiers` array or string).
- Click counts: `--count 2` (double-click) and `--count 3` (triple-click) set the click-state field, so text editors select words and lines.
- `mouse move` becomes a drag event while a button is held.
- `--version` flag and `oscontrol version` command; the version is also in the MCP `serverInfo`.
- MCP `instructions` in the `initialize` result: usage guidance sent to every MCP client.
- End-to-end test suite (`tests/e2e/`, 45 tests) driving a deterministic AppKit fixture (`tests/fixture/`).
- Harness tooling: `scripts/install.sh` and `scripts/register-harnesses.sh` (register and remove the MCP server in Claude Code, Kiro CLI, Pi, Agy, and Grok through their own `mcp add`/`mcp remove` commands).
- Documentation: `README.md`, `AGENTS.md`, `docs/harnesses/` (one page per harness), `docs/llm-usage.md`.

### Changed
- Key presses hold key-down for about 25 ms before key-up (fixes dropped shortcuts in Electron apps such as VS Code).
- Text typing uses real key codes with Shift, and Unicode events only for characters without a US key code.
- Scroll events set continuous pixel deltas and wait briefly after the pointer move, so the window server routes them correctly.
- Drag release re-sends the final drag position before the button is released.
- `doctor` also reports whether a left, right, or middle button is held.

### Fixed
- Command+X/C/V/A/Z had no effect in AppKit apps without an Edit menu (fixture); documented in AGENTS.md §6.
- Right-click on the fixture's text label swallowed the context menu (fixture).

## [0.1.0] - 2026-11-18

### Added
- Screen capture of all active displays (`displays`, `screenshot`), JPEG and PNG, with downscaling.
- Mouse: `mouse move`, `mouse click` (left, right, middle).
- Mouse scroll and keyboard key presses with modifiers.
- Typing text (`type`).
- MCP server over stdio with tools `displays`, `screenshot`, `mouse_move`, `mouse_click`, `mouse_scroll`, `key_press`, `type_text`.
- `doctor` and `permissions` commands; `benchmark` command comparing capture methods.

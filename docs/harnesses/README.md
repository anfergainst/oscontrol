# Using oscontrol from any AI harness

`oscontrol` gives an AI agent eyes and hands on a Mac: screenshots of every monitor, plus mouse and keyboard control. It is one binary that works in two ways:

| Interface | Who uses it | How |
|---|---|---|
| **MCP server** (`oscontrol mcp`) | Any MCP-capable harness | Harness launches the binary and calls tools over stdio |
| **CLI** (`oscontrol <command>`) | Any harness with a shell tool, or you | Harness runs shell commands |

Use MCP when the harness supports it. It is the richest option: screenshots come back as images the model can see, and the server sends usage guidance (`instructions`) automatically. Fall back to the CLI when a harness has no MCP support.

## 1. Install (once)

Requirements: macOS 13+, Xcode command line tools (Swift 5.9+).

```bash
scripts/install.sh                 # builds release, installs ~/.local/bin/oscontrol
~/.local/bin/oscontrol doctor      # all three values must be true
```

Grant the permissions `doctor` reports as missing in **System Settings → Privacy & Security**:

- **Accessibility**: mouse and keyboard events.
- **Screen & System Audio Recording**: screenshots.

macOS attributes these permissions to the app that launches the process. When a harness starts `oscontrol` as an MCP child, the grant that matters is the app hosting the harness: Terminal, iTerm, VS Code, Kiro, Grok, and so on. Grant it there, then **fully quit and reopen** that app.

## 2. Register with your harnesses

```bash
scripts/register-harnesses.sh --dry-run    # shows the exact commands, changes nothing
scripts/register-harnesses.sh              # registers every installed harness it supports
scripts/register-harnesses.sh claude pi    # or only some
scripts/register-harnesses.sh --remove     # unregister everywhere
```

The script calls each harness's own `mcp add` command, so the harness keeps ownership of its config file. Scope is chosen so the server is available in every project (`user` or `global`), not just one folder. Re-running replaces an existing `oscontrol` entry.

Each harness page below lists the exact command, where it is stored, how to verify it, and how to remove it.

## 3. Support matrix

Verified on this machine with the installed versions shown. "Connected" means the harness started `oscontrol mcp` and listed its tools.

| Harness | Version tested | MCP registration | Verified in this session | Page |
|---|---|---|---|---|
| Claude Code (`claude`) | 2.1.325 | `claude mcp add --scope user` | `claude mcp get oscontrol` reports Connected | [claude-code.md](claude-code.md) |
| Pi (`pi`) | 1.5.2 | `pi mcp add` (global `~/.pi/agent/mcp.json`) | `pi mcp list` reports connected, 11 tools | [pi.md](pi.md) |
| Grok (`grok`) | 1.0.77 | `grok mcp add --scope user` | `grok mcp doctor`: handshake OK, 11 tools | [grok.md](grok.md) |
| Agy (`agy`) | 1.5.10 | `agy mcp add` | `agy mcp list`: enabled | [agy.md](agy.md) |
| Kiro CLI (`kiro-cli`) | 3.3.0 | `kiro-cli mcp add --scope global` | Config entry present; **a live interactive session has not been tested** | [kiro-cli.md](kiro-cli.md) |

Any other MCP client (Claude Desktop, Cursor, Zed, Continue, your own agent) works with the generic configuration below.

## 4. Generic MCP configuration

For clients that read a JSON `mcpServers` map, use the absolute path to the installed binary (GUI apps do not inherit your shell `PATH`):

```json
{
  "mcpServers": {
    "oscontrol": {
      "command": "/Users/YOU/.local/bin/oscontrol",
      "args": ["mcp"]
    }
  }
}
```

Protocol: MCP over stdio (JSON-RPC 2.0, one message per line). The server echoes the `protocolVersion` the client requests. Handshakes were verified with 2025-03-26, 2025-06-18 (manual test), and the 2025-11-25 negotiated by Grok.

## 5. Tools (MCP)

| Tool | Purpose | Key arguments |
|---|---|---|
| `displays` | List monitors: origin, size in points, pixel size, scale | none |
| `screenshot` | Capture every monitor (or one). Returns metadata plus one image per display | `display_id?`, `max_width?` (default 1600, 0 = native), `format?` (`jpeg`/`png`), `quality?` |
| `mouse_position` | Current pointer position | none |
| `mouse_move` | Move the pointer (becomes a drag if a button is held) | `x`, `y`, `modifiers?` |
| `mouse_click` | Click; `count` 2 = double-click, 3 = triple-click | `x`, `y`, `button?` (left/right/middle), `count?`, `modifiers?` |
| `mouse_down` / `mouse_up` | Hold and release a button | `x`, `y`, `button?`, `modifiers?` |
| `mouse_drag` | Press, drag in steps, release | `x1`, `y1`, `x2`, `y2`, `button?`, `steps?`, `duration_ms?`, `modifiers?` |
| `mouse_scroll` | Scroll wheel at a point; negative `delta_y` scrolls content down | `x`, `y`, `delta_y`, `delta_x?`, `modifiers?` |
| `key_press` | Press a key with modifiers, e.g. `n` + `command` | `key`, `modifiers?` |
| `type_text` | Type text into the focused control | `text` |

Coordinates are **global desktop points**, origin at the top-left of the main display. Screenshot metadata gives `origin_points`, `size_points`, and `source_pixels` so the model can convert image positions to points. Modifiers: `command`, `control`, `option`, `shift`.

## 6. CLI (for shell-based agents and humans)

```bash
oscontrol displays
oscontrol screenshot --max-width 1280 --output /tmp/screen.jpg
oscontrol mouse position
oscontrol mouse click 640 400 --count 2
oscontrol mouse drag 600 300 800 300 --steps 30
oscontrol mouse scroll 640 400 -120
oscontrol key press n --modifiers command
oscontrol type "I got it!"
oscontrol doctor
```

Full reference: [`README.md`](../../README.md#cli). Every command prints JSON or `ok` on stdout; errors go to stderr with exit code 1, so a shell-based agent can check `$?`.

## 7. Give the model its instructions

MCP clients receive the guidance automatically (the `instructions` field). Harnesses that use the CLI, or whose clients ignore that field, need it in their system instructions or project file. Copy [`docs/llm-usage.md`](../llm-usage.md) into `CLAUDE.md`, `AGENTS.md`, Kiro's steering or agent prompt, or Pi's system prompt, as appropriate for that harness.

## 8. Safety

- oscontrol can click and type anywhere the logged-in user can. Treat it like handing someone your keyboard.
- Screenshots show **everything on screen**: chats, email, banking, password managers, tokens. Only grant an agent screen access on a desk you control, and close sensitive windows first.
- Ask for confirmation before send, delete, purchase, or permission-granting actions. The shipped instructions say this, but a harness may ignore instructions. Consider a confirmation step in the harness for `mouse_click` and `type_text` in sensitive apps.
- Register oscontrol only in harnesses you trust. `scripts/register-harnesses.sh --remove` removes it everywhere.

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Harness says the server failed to start | Binary path wrong or not executable | `ls -l ~/.local/bin/oscontrol`; re-run `scripts/install.sh` |
| Tools listed but clicks do nothing | Accessibility missing for the host app | Grant it, then fully restart the host app |
| Screenshot is an error or black | Screen Recording missing for the host app | Grant it, then restart the host app |
| Screenshot coordinates look wrong | Model used image pixels as points | Convert with `origin_points`, `size_points`, `source_pixels` (see section 5) |
| Shortcut does nothing (e.g. Ctrl+N) | macOS uses Command for app shortcuts | Use `modifiers: ["command"]` |
| Click lands but nothing reacts | Window not focused, or the first click only activated it | Click once more inside the window, then retry |
| Occasional dropped pointer move | Event coalescing under load | Verify with `mouse_position` or a screenshot; re-send the action |

To see the server's own view, run `oscontrol doctor` from a shell started **inside** the harness. If it reports a missing permission there, the harness's host app is the one to grant.

## Files

- `scripts/install.sh`: build and install the binary.
- `scripts/register-harnesses.sh`: register or remove the MCP server in each harness.
- `docs/harnesses/`: this index and one page per harness.
- `docs/llm-usage.md`: usage guide to paste into agent instructions.

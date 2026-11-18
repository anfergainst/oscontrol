# Pi (`pi`)

Tested with Pi **1.5.2** (`pi-coding-agent`). Pi reads MCP servers from `~/.pi/agent/mcp.json` (global) and `.pi/mcp.json` (per project, trusted projects only).

## Register

```bash
pi mcp add oscontrol -- ~/.local/bin/oscontrol mcp     # global
pi mcp add oscontrol -l -- ~/.local/bin/oscontrol mcp  # this project only (.pi/mcp.json)
```

Or: `scripts/register-harnesses.sh pi` (global).

## Verify

```bash
pi mcp list
```

Verified output in this environment:

```
oscontrol: connected, 11 tools (codemode, global)
  /Users/you/.local/bin/oscontrol mcp
  tools: displays, screenshot, mouse_position, mouse_move, mouse_click, mouse_down, mouse_up, mouse_drag, mouse_scroll, key_press, type_text
```

`pi mcp list` exits 1 when a server fails, so it can be used in scripts.

## Use

Start `pi` and ask in plain language. Pi exposes the tools through its codemode layer, so the model may call them through a script. Example prompts:

- "Screenshot the main display and describe the window in the top left."
- "Click the Press me button in the fixture window, then take a screenshot."

If you want the usage guide always in effect, add it to Pi's system prompt or project instructions (see [`docs/llm-usage.md`](../llm-usage.md)).

## Remove

```bash
pi mcp remove oscontrol          # global
pi mcp remove oscontrol -l       # project
```

## Notes

- The MCP child inherits macOS permissions from the terminal (or app) running Pi. Grant Accessibility and Screen Recording there.
- Pi's `mcp add` writes the file with the command you give; keep the absolute path to the binary.

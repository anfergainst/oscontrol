# Claude Code (`claude`)

Tested with Claude Code **2.1.325**. Registration uses the user scope, so oscontrol is available in every project.

## Register

```bash
claude mcp add --scope user oscontrol -- ~/.local/bin/oscontrol mcp
```

Or let the script do it: `scripts/register-harnesses.sh claude`.

Stored in `~/.claude.json` (user scope; the command reported "File modified: ~/.claude.json").

## Verify

```bash
claude mcp get oscontrol          # expect: Status: ✔ Connected, Type: stdio
claude mcp list                   # shows health of every server (slow: starts them)
```

Inside a session, run `/mcp` to see oscontrol and its tools. Claude Code usually names MCP tools `mcp__<server>__<tool>` (here, for example, `mcp__oscontrol__screenshot`); confirm the exact names in `/mcp`. Claude Code may ask you to approve tool calls; **not yet verified in this environment**, so check how the prompts appear the first time.

## Use

Example prompts:

- "Take a screenshot of every display and tell me what's open."
- "Open VS Code, press Command+N, and type 'I got it!'. Take a screenshot to confirm."
- "Select the word 'quick' in the TextEdit window by double-clicking it."

Claude Code also works with the CLI through its Bash tool if you prefer: `oscontrol screenshot --output /tmp/s.jpg`, then read the file.

## Instructions

oscontrol sends its usage guidance during the MCP handshake. For project-specific rules (apps you use, actions that need confirmation), add a section to `CLAUDE.md`. See [`docs/llm-usage.md`](../llm-usage.md).

## Remove

```bash
claude mcp remove oscontrol --scope user
```

## Notes

- Permissions: macOS grants Accessibility and Screen Recording to the terminal (or IDE) that runs `claude`. Grant them there and restart that app.
- If `claude mcp get oscontrol` shows "Failed to connect", run `~/.local/bin/oscontrol mcp` in a terminal: it should wait silently for input. Press Ctrl+C to exit.

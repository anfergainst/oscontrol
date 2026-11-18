# Agy (`agy`)

Tested with Agy **1.5.10**.

## Register

```bash
agy mcp add oscontrol ~/.local/bin/oscontrol mcp
```

Flags must come before the name. If an argument begins with `-`, put `--` before the command.

Or: `scripts/register-harnesses.sh agy`.

## Verify

```bash
agy mcp list
```

Verified output in this environment:

```
NAME       TYPE   STATUS   COMMAND/URL
oscontrol  stdio  enabled  /Users/you/.local/bin/oscontrol mcp
```

Disable or re-enable without removing: `agy mcp disable oscontrol` / `agy mcp enable oscontrol`.

## Use

Start Agy and describe the screen task. Example prompts:

- "Screenshot all monitors and list the apps you see."
- "In VS Code, create a new file and type 'I got it!'."

**Not yet verified:** the tools were not exercised from inside an interactive Agy session in this environment. Run one screenshot prompt first to confirm.

## Remove

```bash
agy mcp remove oscontrol
```

## Notes

- Permissions go to the terminal or app running Agy.
- The config file location is not printed by `agy mcp add`; use `agy mcp list` to confirm.

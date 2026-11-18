# Grok (`grok`)

Tested with Grok CLI **1.0.77**. Registration uses the user scope (`~/.grok/config.toml`).

## Register

```bash
grok mcp add --scope user oscontrol ~/.local/bin/oscontrol -- mcp
```

Note the `--` before `mcp`: arguments for the server go after it, so the server receives `mcp` and grok does not parse it.

Or: `scripts/register-harnesses.sh grok`.

## Verify

```bash
grok mcp list
grok mcp doctor            # checks command, starts the server, runs the handshake, counts tools
```

Verified output in this environment:

```
oscontrol (stdio: ~/.local/bin/oscontrol mcp)
  ✓ command found
  ✓ server started
  ✓ handshake OK (protocol 2025-11-25)
  ✓ 11 tools discovered
```

## Use

Start `grok` and ask for what you want done on screen. Example prompts:

- "Take a screenshot and tell me which app is in front."
- "Double-click the word 'lazy' in TextEdit and copy it."

## Remove

```bash
grok mcp remove oscontrol --scope user
```

## Notes

- Permissions go to the terminal or app running `grok`.
- `grok mcp doctor` is the fastest way to diagnose a broken registration; run it before anything else.

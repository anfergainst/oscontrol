# Kiro CLI (`kiro-cli`)

Tested with Kiro CLI **3.3.0**. Kiro organizes MCP servers by agent. The `global` scope is used so oscontrol is available to every agent.

## Register

```bash
kiro-cli mcp add --name oscontrol --scope global --command ~/.local/bin/oscontrol --args mcp
```

Or: `scripts/register-harnesses.sh kiro-cli`.

## Verify

```bash
kiro-cli mcp list                      # oscontrol appears under the default agent
kiro-cli mcp status --name oscontrol   # shows scope, agent, command, timeout
```

Verified in this environment: `mcp list` shows `oscontrol` with the binary path, and `mcp status` shows the command and default 120 s timeout. **A live interactive Kiro session has not been tested yet.** Start `kiro-cli` and ask for a screenshot to confirm.

## Where the config lives (important)

Kiro keeps its global agent and MCP config under the directory named by the environment variable `KIRO_HOME`. On the machine where this was tested, `KIRO_HOME` pointed into `/tmp`. Files in `/tmp` can be deleted on reboot or by cleanup tools.

- Check after a reboot with `kiro-cli mcp list`. If `oscontrol` is missing, run `scripts/register-harnesses.sh kiro-cli` again.
- To make the registration permanent, set `KIRO_HOME` to a persistent directory (for example `~/.kiro-home`) in your shell profile, then re-register. This changes where Kiro stores all its state, so check Kiro's documentation first.

## Use

Start `kiro-cli` and describe the task. Example prompts:

- "Take a screenshot of my main display and describe what's visible."
- "Click the Save button in the window on the left." (Kiro will need confirmation for clicks in sensitive apps.)

Kiro's steering files (`~/.kiro/steering/`) are a good place for the guidance in [`docs/llm-usage.md`](../llm-usage.md).

## Remove

```bash
kiro-cli mcp remove --name oscontrol --scope global
```

## Notes

- Permissions go to the terminal or IDE running Kiro.
- Kiro's `mcp add` reports the exact file it writes to. Check the output of the add command and of `echo $KIRO_HOME`.

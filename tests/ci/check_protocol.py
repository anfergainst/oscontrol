#!/usr/bin/env python3
"""Permission-free checks for oscontrol.

These checks run on any Mac, including GitHub-hosted runners, because they never click, type,
or capture the screen. They cover the build output, the CLI argument handling, and the MCP
protocol surface. The end-to-end suite (tests/e2e) needs Accessibility and Screen Recording
permissions and is NOT run in CI; see AGENTS.md.

Usage: python3 tests/ci/check_protocol.py [path/to/oscontrol]
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BIN = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build/release/oscontrol")
EXPECTED_TOOLS = {
    "displays", "screenshot", "mouse_position", "mouse_move", "mouse_click", "mouse_down",
    "mouse_up", "mouse_drag", "mouse_scroll", "key_press", "type_text",
}

failures = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f"  [{detail}]" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def run(*args, stdin=None):
    return subprocess.run([BIN, *args], input=stdin, capture_output=True, text=True, timeout=60)


def mcp(messages):
    payload = "\n".join(json.dumps(m) for m in messages) + "\n"
    p = subprocess.run([BIN, "mcp"], input=payload, capture_output=True, text=True, timeout=60)
    out = {}
    for line in p.stdout.splitlines():
        if line.strip():
            msg = json.loads(line)
            out[msg.get("id")] = msg
    return p.returncode, out


# 1. Basic commands
v = run("--version")
check("--version exits 0", v.returncode == 0, v.stderr)
check("--version prints the version", v.stdout.startswith("oscontrol "), v.stdout)
h = run("help")
check("help exits 0 and lists the mcp command", h.returncode == 0 and "| mcp |" in h.stdout)

# 2. CLI argument errors must fail cleanly (exit 1, message on stderr, no input sent)
bad = run("mouse", "click", "10")  # missing Y
check("missing argument exits 1", bad.returncode == 1, f"exit {bad.returncode}")
check("missing argument explains itself on stderr", "Missing or invalid number" in bad.stderr, bad.stderr)
unknown = run("nosuchcommand")
check("unknown command exits 1", unknown.returncode == 1)
badkey = run("key", "press", "a", "--modifiers", "hyper")
check("unknown modifier exits 1", badkey.returncode == 1, f"exit {badkey.returncode}")

# 3. doctor reports JSON with the expected keys (values depend on the machine, so not asserted)
d = run("doctor")
try:
    doc = json.loads(d.stdout)
    keys = {"accessibility_trusted", "post_event_access", "screen_capture_access"}
    check("doctor prints JSON with the permission keys", keys <= set(doc), d.stdout)
except json.JSONDecodeError:
    check("doctor prints JSON", False, d.stdout)

# 4. MCP handshake and tool list
init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}
rc, resp = mcp([init, {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
check("mcp exits 0 when stdin closes", rc == 0)
result = resp.get(1, {}).get("result", {})
check("initialize echoes the requested protocol version", result.get("protocolVersion") == "2025-03-26", str(result))
check("initialize reports serverInfo.name oscontrol", result.get("serverInfo", {}).get("name") == "oscontrol")
check("initialize sends non-empty instructions", len(result.get("instructions", "")) > 100)
check("initialize advertises tools capability", "tools" in result.get("capabilities", {}))

tools = resp.get(2, {}).get("result", {}).get("tools", [])
names = {t["name"] for t in tools}
check("tools/list exposes exactly the 11 documented tools", names == EXPECTED_TOOLS,
      f"missing={EXPECTED_TOOLS - names} extra={names - EXPECTED_TOOLS}")
check("every tool has an object input schema",
      all(t.get("inputSchema", {}).get("type") == "object" for t in tools))
check("every tool has a description", all(t.get("description") for t in tools))

# 5. Unknown method and unknown tool
rc, resp = mcp([init, {"jsonrpc": "2.0", "id": 3, "method": "no/such/method"},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                 "params": {"name": "no_such_tool", "arguments": {}}}])
check("unknown method returns JSON-RPC error -32601",
      resp.get(3, {}).get("error", {}).get("code") == -32601, str(resp.get(3)))
check("unknown tool returns isError without crashing",
      resp.get(4, {}).get("result", {}).get("isError") is True, str(resp.get(4)))

# 6. Argument validation through the MCP path (fails before any input is sent)
rc, resp = mcp([init, {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                       "params": {"name": "mouse_click", "arguments": {"x": "not-a-number", "y": 1}}}])
check("bad argument is reported as isError", resp.get(5, {}).get("result", {}).get("isError") is True,
      str(resp.get(5)))

print()
if failures:
    print(f"{len(failures)} check(s) failed: {', '.join(failures)}")
    sys.exit(1)
print("All permission-free checks passed.")

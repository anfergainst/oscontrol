#!/usr/bin/env python3
"""End-to-end test suite for oscontrol.

Every test:
  1. launches a fresh `oscontrol-fixture` window (known text, box, button, menu, field, scroll view),
  2. drives it ONLY through the real `oscontrol` CLI or MCP server (no shortcuts into the app),
  3. verifies the effect by reading the fixture's recorded state (events, selection, rectangles),
     or, for screenshots, by sampling pixels from the captured image.

Requirements (macOS):
  - Terminal (or the app running this script) has Accessibility and Screen & System Audio Recording.
  - Build first:  swift build            (run_e2e.sh does this for you)

Usage:
  python3 tests/e2e/run_e2e.py                 # run everything
  python3 tests/e2e/run_e2e.py --list          # list tests
  python3 tests/e2e/run_e2e.py --only drag     # run tests whose name contains "drag"
"""
import argparse
import base64
import json
import os
import signal
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OSC = os.environ.get("OSCONTROL_BIN", str(ROOT / ".build/debug/oscontrol"))
FIXTURE = os.environ.get("OSCONTROL_FIXTURE_BIN", str(ROOT / ".build/debug/oscontrol-fixture"))
WORK = Path(os.environ.get("OSCONTROL_E2E_DIR", "/tmp/oscontrol-e2e"))
WORK.mkdir(parents=True, exist_ok=True)
_fixture_counter = 0

TESTS = []  # (name, fn, needs_fixture)


def test(name, needs_fixture=True):
    def deco(fn):
        TESTS.append((name, fn, needs_fixture))
        return fn
    return deco


class Skip(Exception):
    pass


# MARK: - Helpers -------------------------------------------------------------

def cli(*args, timeout=60):
    p = subprocess.run([OSC, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def cli_ok(*args):
    code, out, err = cli(*args)
    assert code == 0, f"`oscontrol {' '.join(map(str, args))}` failed: {err or out}"
    return out


def mcp(messages, timeout=60):
    """Send JSON-RPC messages to `oscontrol mcp` and return responses keyed by id."""
    payload = "\n".join(json.dumps(m) for m in messages) + "\n"
    p = subprocess.run([OSC, "mcp"], input=payload, capture_output=True, text=True, timeout=timeout)
    responses = {}
    for line in p.stdout.splitlines():
        if line.strip():
            msg = json.loads(line)
            responses[msg.get("id")] = msg
    return responses


def mcp_call(name, arguments, rid=2):
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}
    call = {"jsonrpc": "2.0", "id": rid, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    return mcp([init, call])[rid]["result"]


def center(rect):
    return int(rect[0] + rect[2] / 2), int(rect[1] + rect[3] / 2)


def left_edge(rect, dx=2):
    return int(rect[0] + dx), int(rect[1] + rect[3] / 2)


def right_edge(rect, dx=2):
    return int(rect[0] + rect[2] - dx), int(rect[1] + rect[3] / 2)


def run_osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)


class Fixture:
    """Context manager: start a fresh fixture window, bring it to the front, stop it on exit."""

    def __enter__(self):
        global _fixture_counter
        _fixture_counter += 1
        # Unique state file per fixture, so a stale fixture can never overwrite the current one.
        self.state_path = WORK / f"state-{os.getpid()}-{_fixture_counter}.json"
        self.proc = subprocess.Popen([FIXTURE, str(self.state_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 20
        while time.time() < deadline and not self.state().get("ready"):
            time.sleep(0.2)
        if not self.state().get("ready"):
            raise RuntimeError("fixture did not become ready")
        self.activate()
        return self

    def __exit__(self, *exc):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def activate(self):
        """Ask the fixture (SIGUSR1) to make itself the active app with focus on the text view."""
        for attempt in range(5):
            os.kill(self.proc.pid, signal.SIGUSR1)
            try:
                self.wait(lambda s: s.get("keyWindow") is True and s.get("frontmostPid") == self.proc.pid,
                          timeout=2, desc="fixture window is key")
                time.sleep(0.3)
                return
            except AssertionError:
                continue
        raise AssertionError("could not make the fixture window key/frontmost (check focus stealing settings)")

    def state(self):
        try:
            return json.loads(self.state_path.read_text())
        except Exception:
            return {}

    def wait(self, predicate, timeout=4.0, desc="condition"):
        """Poll the fixture state until predicate(state) is truthy. Returns the state."""
        end = time.time() + timeout
        last = {}
        while time.time() < end:
            last = self.state()
            try:
                if predicate(last):
                    return last
            except (KeyError, IndexError, TypeError):
                pass
            time.sleep(0.1)
        raise AssertionError(f"timed out waiting for {desc}; last text={last.get('text')!r} "
                             f"selected={last.get('selectedText')!r} box={last.get('boxRect')}")

    def word(self, w):
        return self.state()["wordRects"][w]


def near(a, b, tol):
    return abs(a - b) <= tol


def has_event(state, **match):
    for e in state.get("events", []):
        if all(e.get(k) == v for k, v in match.items()):
            return True
    return False


def clipboard_text():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def set_clipboard(text):
    subprocess.run(["pbcopy"], input=text, text=True, check=True)


# MARK: - Basics ----------------------------------------------------------------

@test("permissions: doctor reports all three grants", needs_fixture=False)
def _(_f=None):
    d = json.loads(cli_ok("doctor"))
    required = ["accessibility_trusted", "post_event_access", "screen_capture_access"]
    missing = [k for k in required if d.get(k) is not True]
    assert not missing, f"missing permissions: {missing}. Run `oscontrol permissions` and grant them."


@test("displays: one main display, every display has size and scale", needs_fixture=False)
def _(_f=None):
    ds = json.loads(cli_ok("displays"))
    assert ds, "no displays reported"
    assert sum(1 for d in ds if d["isMain"]) == 1, "expected exactly one main display"
    assert all(d["width"] > 0 and d["height"] > 0 and d["scale"] > 0 for d in ds), ds


# MARK: - Pointer --------------------------------------------------------------

MOVE_RETRIES = []  # (x, y, attempts) whenever a move needed to be re-sent; reported at the end of a run


def pointer_at(x, y, tol=1, timeout=3.0):
    """Wait until the reported pointer position is within tol points of (x, y).

    The pointer update is asynchronous. If it has not landed after a short wait, the move is re-sent
    (and recorded in MOVE_RETRIES so that dropped moves stay visible in the report).
    """
    end = time.time() + timeout
    p = None
    attempts = 1
    next_resend = time.time() + 0.6
    while time.time() < end:
        p = json.loads(cli_ok("mouse", "position"))
        if near(p["x"], x, tol) and near(p["y"], y, tol):
            if attempts > 1:
                MOVE_RETRIES.append((x, y, attempts))
            return p
        if time.time() >= next_resend:
            cli_ok("mouse", "move", x, y)
            attempts += 1
            next_resend = time.time() + 0.6
        time.sleep(0.05)
    raise AssertionError(f"asked {(x, y)}, pointer at {p} after {attempts} moves")


@test("pointer: move lands exactly where requested")
def _(f):
    for x, y in [(300, 300), (640, 410), (120, 90)]:
        cli_ok("mouse", "move", x, y)
        pointer_at(x, y)  # the pointer update is asynchronous; poll rather than sleep a fixed time


@test("pointer: hovering over the button produces mouseMoved events there")
def _(f):
    x, y = center(f.state()["buttonRect"])

    def hovered(s):
        return any(e["type"] == "mouseMoved" and near(e["x"], x, 2) and near(e["y"], y, 2) for e in s["events"])

    # Approach in two steps so the final move is a real change of position. Re-send if the event
    # has not arrived (move events can be dropped under load), up to three attempts.
    for attempt in range(3):
        cli_ok("mouse", "move", x - 40, y - 40)
        time.sleep(0.3)
        cli_ok("mouse", "move", x, y)
        try:
            f.wait(hovered, timeout=2, desc="mouseMoved over button")
            return
        except AssertionError:
            continue
    raise AssertionError("no mouseMoved event reached the button after 3 attempts")


@test("pointer: left click presses the button")
def _(f):
    x, y = center(f.state()["buttonRect"])
    cli_ok("mouse", "click", x, y)
    f.wait(lambda s: s["pressCount"] == 1, desc="button pressed once")


@test("pointer: left click twice presses the button twice (two separate clicks)")
def _(f):
    x, y = center(f.state()["buttonRect"])
    cli_ok("mouse", "click", x, y)
    time.sleep(0.6)
    cli_ok("mouse", "click", x, y)
    f.wait(lambda s: s["pressCount"] == 2, desc="button pressed twice")


@test("pointer: right click is delivered as rightMouseDown")
def _(f):
    x, y = center(f.state()["contextRect"])
    cli_ok("mouse", "click", x, y, "--button", "right")
    f.wait(lambda s: has_event(s, type="rightMouseDown"), desc="rightMouseDown")


@test("pointer: middle click is delivered as otherMouseDown button 2")
def _(f):
    x, y = center(f.state()["textRect"])
    cli_ok("mouse", "click", x, y, "--button", "middle")
    f.wait(lambda s: has_event(s, type="otherMouseDown", button=2), desc="middle button down")


@test("pointer: single click places the caret at the clicked word")
def _(f):
    s = f.state()
    x, y = left_edge(f.word("lazy"), dx=1)
    idx = s["text"].index("lazy")
    cli_ok("mouse", "click", x, y)
    f.wait(lambda st: near(st["selectedRange"][0], idx, 1) and st["selectedRange"][1] == 0,
           desc=f"caret at index {idx}")


@test("pointer: double click selects one word")
def _(f):
    x, y = center(f.word("quick"))
    cli_ok("mouse", "click", x, y, "--count", 2)
    f.wait(lambda s: s["selectedText"].strip() == "quick", desc="'quick' selected")


@test("pointer: triple click selects the whole line")
def _(f):
    x, y = center(f.word("brown"))
    cli_ok("mouse", "click", x, y, "--count", 3)
    f.wait(lambda s: s["selectedText"].strip() == "The quick brown fox", desc="first line selected")


@test("pointer: drag selects text from one word to another")
def _(f):
    sx, sy = left_edge(f.word("quick"))
    ex, ey = right_edge(f.word("brown"))
    cli_ok("mouse", "drag", sx, sy, ex, ey, "--steps", 15)
    f.wait(lambda s: s["selectedText"].strip() == "quick brown", desc="'quick brown' selected by drag")


@test("pointer: shift-click extends an existing selection")
def _(f):
    ax, ay = left_edge(f.word("jumps"))
    bx, by = right_edge(f.word("lazy"))
    cli_ok("mouse", "click", ax, ay)
    time.sleep(0.5)
    cli_ok("mouse", "click", bx, by, "--modifiers", "shift")
    f.wait(lambda s: s["selectedText"].strip() == "jumps over the lazy", desc="shift-click selection")


@test("pointer: command-click carries the command modifier in the event")
def _(f):
    x, y = center(f.state()["buttonRect"])
    cli_ok("mouse", "click", x, y, "--modifiers", "command")
    f.wait(lambda s: any(e["type"] == "leftMouseDown" and "command" in e["modifiers"] for e in s["events"]),
           desc="command-modified leftMouseDown")


@test("pointer: scroll wheel moves a scroll view down and back up")
def _(f):
    x, y = center(f.state()["scrollRect"])
    cli_ok("mouse", "scroll", x, y, -60)
    f.wait(lambda s: s["scrollY"] > 0, desc="content scrolled down")
    # Let scrolling settle (AppKit may animate) before measuring the peak.
    f.wait(lambda s: s["scrollY"] == f.state()["scrollY"] and s["scrollY"] > 0 and time.sleep(0.4) is None,
           timeout=3, desc="scrolling settled")
    peak = f.state()["scrollY"]
    cli_ok("mouse", "scroll", x, y, 60)
    f.wait(lambda s: s["scrollY"] < peak - 1, desc="content scrolled back up")


# MARK: - Keyboard and text ----------------------------------------------------

@test("keyboard: command+left then shift+right selects the first word")
def _(f):
    x, y = center(f.word("fox"))
    cli_ok("mouse", "click", x, y)
    time.sleep(0.4)
    cli_ok("key", "press", "left", "--modifiers", "command")
    time.sleep(0.2)
    for _ in range(3):
        cli_ok("key", "press", "right", "--modifiers", "shift")
    f.wait(lambda s: s["selectedText"] == "The", desc="'The' selected by keyboard")


@test("keyboard: command+a selects all, command+c copies to the clipboard")
def _(f):
    set_clipboard("sentinel-before-copy")
    x, y = center(f.word("fox"))
    cli_ok("mouse", "click", x, y)
    time.sleep(0.4)
    cli_ok("key", "press", "a", "--modifiers", "command")
    f.wait(lambda s: s["selectedText"] == s["text"], desc="all text selected")
    cli_ok("key", "press", "c", "--modifiers", "command")
    time.sleep(0.6)
    copied = clipboard_text().rstrip("\n")
    assert copied == f.state()["text"].rstrip("\n"), f"clipboard had {copied!r}"


@test("keyboard: command+v pastes clipboard contents at the end")
def _(f):
    set_clipboard("PASTED")
    x, y = center(f.word("fox"))
    cli_ok("mouse", "click", x, y)
    time.sleep(0.4)
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    cli_ok("key", "press", "v", "--modifiers", "command")
    f.wait(lambda s: s["text"].endswith("third line herePASTED"), desc="pasted at end")


@test("keyboard: cut with command+x removes the selected word")
def _(f):
    x, y = center(f.word("quick"))
    cli_ok("mouse", "click", x, y, "--count", 2)
    f.wait(lambda s: s["selectedText"].strip() == "quick", desc="'quick' selected")
    cli_ok("key", "press", "x", "--modifiers", "command")
    # macOS "smart cut" also removes the adjoining space, so accept either spacing.
    f.wait(lambda s: s["text"].startswith("The brown fox") and "quick" not in s["text"], desc="word removed")
    time.sleep(0.5)
    assert "quick" in clipboard_text(), "cut text did not reach the clipboard"


@test("keyboard: typing inserts text at the caret")
def _(f):
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    cli_ok("type", " Hello, World!")
    f.wait(lambda s: s["text"].endswith("third line here Hello, World!"), desc="typed text")


@test("keyboard: return inserts a newline, delete removes characters")
def _(f):
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    cli_ok("key", "press", "return")
    cli_ok("type", "abc")
    for _ in range(3):
        cli_ok("key", "press", "delete")
    f.wait(lambda s: s["text"].endswith("third line here\n"), desc="newline kept, abc removed")


@test("keyboard: arrow keys move the caret before inserting")
def _(f):
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    for _ in range(4):
        cli_ok("key", "press", "left")
    cli_ok("type", "XY")
    f.wait(lambda s: s["text"].endswith("third line XYhere"), desc="XY inserted before 'here'")


@test("keyboard: option+left jumps by word")
def _(f):
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    cli_ok("key", "press", "left", "--modifiers", "option")
    idx = f.state()["text"].index("here")
    f.wait(lambda s: s["selectedRange"][0] == idx, desc=f"caret at 'here' (index {idx})")


@test("keyboard: command+z undoes typing")
def _(f):
    original = f.state()["text"]
    cli_ok("key", "press", "down", "--modifiers", "command")
    time.sleep(0.2)
    cli_ok("type", "ZZZ")
    f.wait(lambda s: s["text"].endswith("ZZZ"), desc="typed ZZZ")
    time.sleep(0.8)  # separate undo group from later actions
    cli_ok("key", "press", "z", "--modifiers", "command")
    f.wait(lambda s: s["text"] == original, desc="undo restored original text")


@test("keyboard: typing capitals, digits, and symbols")
def _(f):
    x, y = center(f.state()["fieldRect"])
    cli_ok("mouse", "click", x, y)
    time.sleep(0.4)
    cli_ok("type", "Ab1!?")
    f.wait(lambda s: s["field"] == "Ab1!?", desc="field contains 'Ab1!?'")


@test("keyboard: text field accepts typing after a click")
def _(f):
    x, y = center(f.state()["fieldRect"])
    cli_ok("mouse", "click", x, y)
    time.sleep(0.4)
    cli_ok("type", "hello field")
    f.wait(lambda s: s["field"] == "hello field", desc="field text")


# MARK: - Moving objects -------------------------------------------------------

@test("drag: dragging the box moves it by the drag distance")
def _(f):
    r0 = f.state()["boxRect"]
    x, y = center(r0)
    cli_ok("mouse", "drag", x, y, x + 200, y, "--steps", 20)
    f.wait(lambda s: near(s["boxRect"][0], r0[0] + 200, 3), desc="box moved +200 points")


@test("drag: mouse down, move, mouse up moves the box (primitives compose)")
def _(f):
    r0 = f.state()["boxRect"]
    x, y = center(r0)
    cli_ok("mouse", "down", x, y)  # press on the box
    time.sleep(0.2)
    for step in range(1, 11):
        cli_ok("mouse", "move", x + step * 15, y)
        time.sleep(0.03)
    cli_ok("mouse", "up", x + 150, y)
    f.wait(lambda s: near(s["boxRect"][0], r0[0] + 150, 3), desc=f"box moved +150 points (start x={r0[0]})")


@test("drag: a drag with shift is recorded with the shift modifier")
def _(f):
    x1, y = center(f.word("third"))
    x2, _ = center(f.word("here"))
    cli_ok("mouse", "drag", x1, y, x2, y, "--modifiers", "shift")
    f.wait(lambda s: any(e["type"] == "leftMouseDragged" and "shift" in e["modifiers"] for e in s["events"]),
           desc="shift-modified drag events")


@test("drag: drag leaves the pointer at the release point")
def _(f):
    r0 = f.state()["boxRect"]
    x, y = center(r0)
    cli_ok("mouse", "drag", x, y, x + 60, y + 0, "--steps", 8)
    time.sleep(0.3)
    p = json.loads(cli_ok("mouse", "position"))
    assert near(p["x"], x + 60, 1) and near(p["y"], y, 1), p


# MARK: - Context menus --------------------------------------------------------

def open_context_menu(f):
    """Right-click the target and wait until the fixture reports the native menu is open.

    The fixture positions the menu item "Beta" under the click point and reports that point
    (menuAnchor), so the test knows where Beta is without relying on Accessibility.
    """
    x, y = center(f.state()["contextRect"])
    cli_ok("mouse", "click", x, y, "--button", "right")
    return f.wait(lambda s: s["menuOpenCount"] == 1, desc="context menu opened").get("menuAnchor")


@test("menu: right-click opens a menu at the pointer")
def _(f):
    x, y = center(f.state()["contextRect"])
    cli_ok("mouse", "click", x, y, "--button", "right")
    f.wait(lambda s: s["menuOpenCount"] == 1, desc="menu opened")
    anchor = f.state()["menuAnchor"]
    assert near(anchor[0], x, 2) and near(anchor[1], y, 2), f"menu anchored at {anchor}, right-click at {(x, y)}"
    cli_ok("key", "press", "escape")


@test("menu: right-click, then select an option with the mouse")
def _(f):
    ax, ay = open_context_menu(f)
    # "Beta" sits under the anchor point; click its text region.
    cli_ok("mouse", "click", int(ax + 30), int(ay))
    f.wait(lambda s: s["lastMenuChoice"] == "Beta", desc="menu choice 'Beta' by mouse")


@test("menu: right-click, then select an option with the keyboard (arrow keys + return)")
def _(f):
    open_context_menu(f)
    # Beta is the item under the pointer; move down to Gamma and back up to Beta, then choose it.
    cli_ok("key", "press", "down")
    time.sleep(0.2)
    cli_ok("key", "press", "up")
    time.sleep(0.2)
    cli_ok("key", "press", "return")
    f.wait(lambda s: s["lastMenuChoice"] == "Beta", desc="menu choice 'Beta' via keyboard")


@test("menu: escape closes the menu without choosing anything")
def _(f):
    open_context_menu(f)
    cli_ok("key", "press", "escape")
    time.sleep(0.8)
    assert f.state()["lastMenuChoice"] == "", "a menu item was chosen after escape"
    # With the menu gone, a second click on the option's spot must not choose anything.
    ax, ay = f.state()["menuAnchor"]
    cli_ok("mouse", "click", int(ax + 30), int(ay))
    time.sleep(0.8)
    assert f.state()["lastMenuChoice"] == "", "menu was still open after escape"


# MARK: - Screen capture -------------------------------------------------------

def discard(*paths):
    """Delete screenshot files: they capture the whole display, which may show unrelated content."""
    for p in paths:
        try:
            Path(p).unlink()
        except FileNotFoundError:
            pass


def sips_dims(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         capture_output=True, text=True).stdout
    vals = {}
    for line in out.splitlines():
        parts = line.split(":")
        if len(parts) == 2 and parts[0].strip() in ("pixelWidth", "pixelHeight"):
            vals[parts[0].strip()] = int(parts[1])
    return vals["pixelWidth"], vals["pixelHeight"]


def read_bmp_pixel(path, px, py):
    """Return (r,g,b) at pixel (px,py) of an uncompressed 24/32-bit BMP, top-left origin."""
    data = Path(path).read_bytes()
    offset = int.from_bytes(data[10:14], "little")
    width = int.from_bytes(data[18:22], "little", signed=True)
    height = int.from_bytes(data[22:26], "little", signed=True)
    bpp = int.from_bytes(data[28:30], "little")
    row = ((width * bpp + 31) // 32) * 4
    y = (height - 1 - py) if height > 0 else py
    i = offset + y * row + px * (bpp // 8)
    b, g, r = data[i], data[i + 1], data[i + 2]
    return r, g, b


@test("screen: full-resolution PNG has the display's native pixel size")
def _(f):
    displays = json.loads(cli_ok("displays"))
    main = next(d for d in displays if d["isMain"])
    out = WORK / "main-native.png"
    try:
        info = json.loads(cli_ok("screenshot", "--display", main["id"], "--format", "png", "--max-width", 0, "--output", out))
        assert out.exists() and out.stat().st_size > 10_000, "screenshot missing or empty"
        w, h = sips_dims(out)
        assert (w, h) == tuple(info["source_pixels"]), f"file {w}x{h} vs capture {info['source_pixels']}"
        assert (w, h) == (main["pixelWidth"], main["pixelHeight"]), f"{w}x{h} != display {main['pixelWidth']}x{main['pixelHeight']}"
    finally:
        discard(out)


@test("screen: JPEG downscale honors --max-width")
def _(f):
    displays = json.loads(cli_ok("displays"))
    main = next(d for d in displays if d["isMain"])
    out = WORK / "main-800.jpg"
    try:
        cli_ok("screenshot", "--display", main["id"], "--format", "jpeg", "--max-width", 800, "--output", out)
        w, _h = sips_dims(out)
        assert w == 800, f"width {w}, expected 800"
    finally:
        discard(out)


@test("screen: screenshot pixels show the red box where the state says it is")
def _(f):
    displays = json.loads(cli_ok("displays"))
    main = next(d for d in displays if d["isMain"])
    box = f.state()["boxRect"]
    out = WORK / "box.bmp"
    png = WORK / "box.png"
    try:
        cli_ok("screenshot", "--display", main["id"], "--format", "png", "--max-width", 0, "--output", png)
        subprocess.run(["sips", "-s", "format", "bmp", str(png), "--out", str(out)], capture_output=True, check=True)
        pw, _ph = sips_dims(png)
        scale = pw / main["width"]
        cx, cy = center(box)
        # Sample a patch around the box center (points relative to the main display origin).
        lx, ly = (cx - main["x"]) * scale, (cy - main["y"]) * scale
        samples = [read_bmp_pixel(out, int(lx) + dx, int(ly) + dy) for dx in (-4, 0, 4) for dy in (-4, 0, 4)]
        reddish = sum(1 for r, g, b in samples if r > 160 and g < 120 and b < 120)
        assert reddish >= 7, f"expected red box at {(cx, cy)}, samples {samples[:4]}..."
    finally:
        discard(out, png)


@test("screen: pointer can reach a secondary display (if one is connected)", needs_fixture=False)
def _(_f=None):
    displays = json.loads(cli_ok("displays"))
    others = [d for d in displays if not d["isMain"]]
    if not others:
        raise Skip("only one display connected")
    d = others[0]
    x, y = int(d["x"] + d["width"] / 2), int(d["y"] + d["height"] / 2)
    cli_ok("mouse", "move", x, y)
    pointer_at(x, y)
    main = next(d for d in displays if d["isMain"])
    cli_ok("mouse", "move", int(main["width"] / 2), int(main["height"] / 2))
    pointer_at(int(main["width"] / 2), int(main["height"] / 2))


# MARK: - MCP ------------------------------------------------------------------

@test("mcp: tools/list exposes every control tool")
def _(f):
    resp = mcp([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
    names = {t["name"] for t in resp[2]["result"]["tools"]}
    required = {"displays", "screenshot", "mouse_position", "mouse_move", "mouse_click", "mouse_down",
                "mouse_up", "mouse_drag", "mouse_scroll", "key_press", "type_text"}
    assert required <= names, f"missing tools: {required - names}"


@test("mcp: mouse_click presses the button")
def _(f):
    x, y = center(f.state()["buttonRect"])
    res = mcp_call("mouse_click", {"x": x, "y": y})
    assert res["isError"] is False, res
    f.wait(lambda s: s["pressCount"] == 1, desc="button pressed via MCP")


@test("mcp: mouse_drag moves the box")
def _(f):
    r0 = f.state()["boxRect"]
    x, y = center(r0)
    res = mcp_call("mouse_drag", {"x1": x, "y1": y, "x2": x, "y2": y + 100, "steps": 15})
    assert res["isError"] is False, res
    f.wait(lambda s: near(s["boxRect"][1], r0[1] + 100, 3), desc="box moved down 100 via MCP")


@test("mcp: mouse_click with count=2 selects a word")
def _(f):
    x, y = center(f.word("dog"))
    res = mcp_call("mouse_click", {"x": x, "y": y, "count": 2})
    assert res["isError"] is False, res
    f.wait(lambda s: s["selectedText"].strip() == "dog", desc="'dog' selected via MCP")


@test("mcp: key_press with modifiers + type_text work through the text view")
def _(f):
    x, y = center(f.word("here"))
    mcp_call("mouse_click", {"x": x, "y": y})
    time.sleep(0.4)
    res = mcp_call("key_press", {"key": "a", "modifiers": ["command"]})
    assert res["isError"] is False, res
    time.sleep(0.4)
    res = mcp_call("type_text", {"text": "MCP"})
    assert res["isError"] is False, res
    f.wait(lambda s: s["text"] == "MCP", desc="select-all + type replaced text")


@test("mcp: screenshot returns a decodable image block")
def _(f):
    displays = json.loads(cli_ok("displays"))
    main = next(d for d in displays if d["isMain"])
    res = mcp_call("screenshot", {"display_id": main["id"], "max_width": 800, "format": "jpeg"})
    images = [b for b in res["content"] if b["type"] == "image"]
    assert images, "no image block returned"
    raw = base64.b64decode(images[0]["data"])
    assert raw[:2] == b"\xff\xd8", "not a JPEG"
    assert images[0]["mimeType"] == "image/jpeg"


@test("mcp: unknown tool returns isError without crashing the server")
def _(f=None):
    resp = mcp([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "nope", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 3, "method": "ping"}])
    assert resp[2]["result"]["isError"] is True
    assert 3 in resp, "server stopped responding after an error"


# MARK: - Runner ---------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="run tests whose name contains this text")
    ap.add_argument("--list", action="store_true", help="list tests and exit")
    ap.add_argument("--report", default=str(WORK / "report.json"))
    args = ap.parse_args()

    if not Path(OSC).exists() or not Path(FIXTURE).exists():
        print(f"Build first: swift build  (missing {OSC} or {FIXTURE})")
        return 2

    # Stop any fixture left running by an earlier interrupted run.
    subprocess.run(["pkill", "-f", "oscontrol-fixture"], capture_output=True)
    time.sleep(0.3)

    selected = [t for t in TESTS if args.only.lower() in t[0].lower()]
    if args.list:
        for name, _, nf in selected:
            print(("   " if nf else "[no fixture] ") + name)
        return 0

    results = []
    passed = failed = skipped = 0
    for name, fn, needs in selected:
        started = time.time()
        status, detail = "PASS", ""
        try:
            if needs:
                with Fixture() as f:
                    fn(f)
            else:
                fn()
            passed += 1
        except Skip as e:
            status, detail = "SKIP", str(e)
            skipped += 1
        except Exception as e:  # noqa: BLE001 - report every failure, keep going
            status, detail = "FAIL", f"{type(e).__name__}: {e}"
            if os.environ.get("E2E_TRACE"):
                detail += "\n" + traceback.format_exc()
            failed += 1
        elapsed = time.time() - started
        results.append({"name": name, "status": status, "detail": detail, "seconds": round(elapsed, 2)})
        line = f"{status:4}  {elapsed:5.1f}s  {name}"
        if detail and status != "PASS":
            line += f"\n        {detail}"
        print(line, flush=True)

    if MOVE_RETRIES:
        print(f"note: {len(MOVE_RETRIES)} pointer move(s) had to be re-sent: {MOVE_RETRIES}")
    print(f"\n{passed} passed, {failed} failed, {skipped} skipped, {len(selected)} total")
    Path(args.report).write_text(json.dumps({"passed": passed, "failed": failed, "skipped": skipped,
                                             "results": results}, indent=2))
    print(f"report: {args.report}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

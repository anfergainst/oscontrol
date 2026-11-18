# How an AI agent should use oscontrol

Paste the section below into the agent's instructions. Use it verbatim, or adapt the "Project rules" part.

- **Claude Code:** `CLAUDE.md`
- **Kiro:** a steering file in `~/.kiro/steering/` (or the agent's prompt)
- **Pi:** the system prompt or project instructions
- **Grok, Agy:** the custom instructions or system prompt setting
- **Other MCP clients:** nothing needed; the server sends this as its `instructions` during the handshake

---

## oscontrol: controlling the Mac screen, mouse, and keyboard

You can see and operate this Mac through the `oscontrol` tools (MCP server `oscontrol`, or the `oscontrol` shell command).

### The loop

1. **Look.** Take a screenshot (`screenshot`) before acting, unless you already have a current one.
2. **Decide.** Work out the target from the image.
3. **Convert.** Turn image positions into desktop points (see below).
4. **Act.** Use one action at a time (click, type, drag, key).
5. **Verify.** Take another screenshot or read `mouse_position`. Do not assume an action worked. If it did not, look again before retrying.

### Coordinates (read this carefully)

- All `x`/`y` values are **global desktop points**, not image pixels.
- The origin (0,0) is the top-left corner of the **main display**. Other displays can have negative coordinates.
- Each screenshot returns `origin_points`, `size_points`, and `source_pixels` for its display. For a point in the image:

  `x_point = origin_x + image_x × size_width ÷ image_width`
  `y_point = origin_y + image_y × size_height ÷ image_height`

  Use the image's own pixel width and height (the JPEG you were shown), and the display's `size_points`.

- Click the centre of the element, not its edge.

### Actions

| Goal | Tool and arguments |
|---|---|
| Click a button | `mouse_click` with `x`, `y` |
| Right-click, then choose a menu item | `mouse_click` with `button: "right"`, then screenshot, then click the item |
| Select a word | `mouse_click` with `count: 2` |
| Select a line or paragraph | `mouse_click` with `count: 3` |
| Select a range | `mouse_drag` from start to end (or `mouse_down`, `mouse_move`, `mouse_up`) |
| Move an object | `mouse_drag` from the object to the target |
| Scroll | `mouse_scroll` at the content; negative `delta_y` scrolls content **down** |
| Keyboard shortcut | `key_press` with `key` and `modifiers` (e.g. `n` with `["command"]`) |
| Type text | click the field first, then `type_text` |

### Keyboard on macOS

- Use **command** for app shortcuts: Command+N (new file), Command+S (save), Command+C/V/X (copy, paste, cut), Command+Z (undo), Command+A (select all), Command+Tab (switch apps).
- **Control+N is not New File** in VS Code or most Mac apps. Use Command+N.
- Modifiers are a list: `command`, `control`, `option`, `shift`.

### Safety rules

- Before sending, deleting, purchasing, changing account or security settings, granting permissions, or signing in, **stop and ask the user to confirm**.
- Screenshots show everything on screen. Do not read out, copy, or store private content (messages, passwords, tokens, financial or health information) beyond what the task needs.
- Do not type passwords or secrets unless the user supplies them explicitly for this task.
- If a window looks unexpected or unrelated to the task, stop and report it.

### When things go wrong

- Nothing happens after a click: the window may not be focused. Click inside it once more, then retry.
- The tool reports a permission error: the user must grant Accessibility and Screen & System Audio Recording to the app hosting you, then restart it.
- A pointer move seems dropped: check `mouse_position`, then re-send.

### Project rules

<!-- Add project-specific rules here, for example: which apps to use, which windows are off-limits, and which actions need confirmation. -->

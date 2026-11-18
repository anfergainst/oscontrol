import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors, JSON, argument parsing

struct ControlError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func jsonString(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

/// `--name value` pairs become options; everything else is positional.
struct Args {
    private(set) var positional: [String] = []
    private(set) var options: [String: String] = [:]

    init(_ tokens: [String]) {
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.hasPrefix("--"), i + 1 < tokens.count {
                options[String(t.dropFirst(2))] = tokens[i + 1]
                i += 2
            } else {
                positional.append(t)
                i += 1
            }
        }
    }

    func option(_ key: String) -> String? { options[key] }
}

// MARK: - Argument helpers shared by CLI and MCP tools

func num(_ a: [String: Any], _ key: String) throws -> Double {
    if let n = a[key] as? NSNumber { return n.doubleValue }
    if let s = a[key] as? String, let d = Double(s) { return d }
    throw ControlError("Missing or invalid number argument '\(key)'")
}

func optInt(_ a: [String: Any], _ key: String) -> Int? {
    if let n = a[key] as? NSNumber { return n.intValue }
    if let s = a[key] as? String { return Int(s) }
    return nil
}

func str(_ a: [String: Any], _ key: String, _ fallback: String) -> String {
    (a[key] as? String) ?? fallback
}

/// Accepts ["shift","command"] or "shift,command".
func strings(_ a: [String: Any], _ key: String) -> [String] {
    if let arr = a[key] as? [String] { return arr }
    if let s = a[key] as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    return []
}

// MARK: - Displays and screen capture

struct DisplayInfo {
    let id: UInt32
    let x: Double, y: Double, width: Double, height: Double
    let pixelWidth: Int, pixelHeight: Int
    let scale: Double
    let isMain: Bool
    let isBuiltin: Bool
}

struct Capture {
    let display: DisplayInfo
    let image: CGImage
}

enum Desktop {
    static func displays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let b = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pw = Int(mode?.pixelWidth ?? 0), ph = Int(mode?.pixelHeight ?? 0)
            return DisplayInfo(id: id, x: b.origin.x, y: b.origin.y, width: b.width, height: b.height,
                               pixelWidth: pw, pixelHeight: ph,
                               scale: b.width > 0 ? Double(pw) / b.width : 1,
                               isMain: CGDisplayIsMain(id) != 0, isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }.sorted { $0.isMain && !$1.isMain }
    }

    static func displayDict(_ d: DisplayInfo) -> [String: Any] {
        ["id": d.id, "x": d.x, "y": d.y, "width": d.width, "height": d.height,
         "pixelWidth": d.pixelWidth, "pixelHeight": d.pixelHeight, "scale": d.scale,
         "isMain": d.isMain, "isBuiltin": d.isBuiltin]
    }

    static func capture(displayID: UInt32? = nil) throws -> [Capture] {
        let selected = displays().filter { displayID == nil || $0.id == displayID }
        guard !selected.isEmpty else {
            throw ControlError(displayID.map { "Display \($0) is not active" } ?? "No active displays found")
        }
        return try selected.map { info in
            guard let image = CGDisplayCreateImage(info.id) else {
                throw ControlError("Could not capture display \(info.id). Grant Screen Recording permission to the calling app/terminal.")
            }
            return Capture(display: info, image: image)
        }
    }

    static func encoded(_ image: CGImage, format: String, maxWidth: Int, quality: Double) throws -> Data {
        var scaled = image
        if maxWidth > 0 && image.width > maxWidth {
            let h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
            guard let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ControlError("Unable to create resize context")
            }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
            guard let resized = ctx.makeImage() else { throw ControlError("Unable to resize image") }
            scaled = resized
        }
        let type: UTType = format == "png" ? .png : .jpeg
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ControlError("Unable to initialize image encoder")
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, quality))]
        CGImageDestinationAddImage(dest, scaled, type == .png ? nil : options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ControlError("Image encoding failed") }
        return output as Data
    }

    /// Returns (capture, encoded bytes, normalized format) for each selected display.
    static func screenshot(displayID: UInt32?, format rawFormat: String, maxWidth: Int, quality: Double) throws
        -> (items: [(capture: Capture, data: Data)], format: String) {
        let lowered = rawFormat.lowercased()
        guard ["jpeg", "jpg", "png"].contains(lowered) else { throw ControlError("format must be jpeg or png") }
        let format = lowered == "png" ? "png" : "jpeg"
        let captures = try Desktop.capture(displayID: displayID)
        let items = try captures.map { (capture: $0, data: try encoded($0.image, format: format, maxWidth: maxWidth, quality: quality)) }
        return (items, format)
    }
}

// MARK: - Input injection

enum Input {
    /// hidSystemState source: events look like real hardware input to apps.
    static let source = CGEventSource(stateID: .hidSystemState)

    struct ButtonInfo {
        let button: CGMouseButton
        let down: CGEventType
        let up: CGEventType
        let dragged: CGEventType
        let number: Int64
    }

    static func ensureAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ControlError("Accessibility permission is required. Enable it for the calling app in System Settings → Privacy & Security → Accessibility.")
        }
    }

    static func buttonInfo(_ name: String) throws -> ButtonInfo {
        switch name.lowercased() {
        case "left": return ButtonInfo(button: .left, down: .leftMouseDown, up: .leftMouseUp, dragged: .leftMouseDragged, number: 0)
        case "right": return ButtonInfo(button: .right, down: .rightMouseDown, up: .rightMouseUp, dragged: .rightMouseDragged, number: 1)
        case "middle": return ButtonInfo(button: .center, down: .otherMouseDown, up: .otherMouseUp, dragged: .otherMouseDragged, number: 2)
        default: throw ControlError("button must be left, right, or middle")
        }
    }

    static func flags(_ names: [String]) throws -> CGEventFlags {
        var f: CGEventFlags = []
        for n in names {
            switch n.lowercased() {
            case "command", "cmd", "meta": f.insert(.maskCommand)
            case "control", "ctrl": f.insert(.maskControl)
            case "option", "alt": f.insert(.maskAlternate)
            case "shift": f.insert(.maskShift)
            default: throw ControlError("Unknown modifier '\(n)'. Use command, control, option, shift.")
            }
        }
        return f
    }

    static func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, number: Int64 = 0,
                     clickState: Int64? = nil, flags: CGEventFlags = []) throws {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
            throw ControlError("Could not create mouse event")
        }
        e.flags = flags
        e.setIntegerValueField(.mouseEventButtonNumber, value: number)
        if let c = clickState { e.setIntegerValueField(.mouseEventClickState, value: c) }
        e.post(tap: .cghidEventTap)
    }

    /// The button currently held down, if any (so moves become drags, as real hardware does).
    static func heldButton() throws -> ButtonInfo? {
        for name in ["left", "right", "middle"] where CGEventSource.buttonState(.hidSystemState, button: try buttonInfo(name).button) {
            return try buttonInfo(name)
        }
        return nil
    }

    static func position() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to p: CGPoint, flags: CGEventFlags = []) throws {
        try ensureAccessibility()
        if let held = try heldButton() {
            try post(held.dragged, at: p, button: held.button, number: held.number, flags: flags)
        } else {
            try post(.mouseMoved, at: p, flags: flags)
        }
    }

    /// Clicks `count` times. count 2 / 3 set clickState so apps see double/triple clicks.
    static func click(at p: CGPoint, button: String, count: Int, flags: CGEventFlags) throws {
        try ensureAccessibility()
        let b = try buttonInfo(button)
        try post(.mouseMoved, at: p, flags: flags)
        for i in 1...max(1, min(count, 3)) {
            try post(b.down, at: p, button: b.button, number: b.number, clickState: Int64(i), flags: flags)
            usleep(25_000)
            try post(b.up, at: p, button: b.button, number: b.number, clickState: Int64(i), flags: flags)
            usleep(70_000)
        }
    }

    static func mouseDown(at p: CGPoint, button: String, flags: CGEventFlags) throws {
        try ensureAccessibility()
        let b = try buttonInfo(button)
        try post(b.down, at: p, button: b.button, number: b.number, clickState: 1, flags: flags)
    }

    static func mouseUp(at p: CGPoint, button: String, flags: CGEventFlags) throws {
        try ensureAccessibility()
        try release(try buttonInfo(button), at: p, flags: flags)
    }

    /// Releases a button at `p`. The window server may coalesce drag events under load, so the final
    /// position is re-sent as a drag event (as hardware reports the pointer position) before the release.
    static func release(_ info: ButtonInfo, at p: CGPoint, flags: CGEventFlags) throws {
        if CGEventSource.buttonState(.hidSystemState, button: info.button) {
            usleep(40_000)
            try post(info.dragged, at: p, button: info.button, number: info.number, flags: flags)
            usleep(40_000)
        }
        try post(info.up, at: p, button: info.button, number: info.number, clickState: 1, flags: flags)
    }

    /// Press at `a`, interpolate drag events to `b`, release at `b`.
    static func drag(from a: CGPoint, to b: CGPoint, button: String, steps: Int, durationMs: Int, flags: CGEventFlags) throws {
        try ensureAccessibility()
        let info = try buttonInfo(button)
        try post(.mouseMoved, at: a, flags: flags)
        try post(info.down, at: a, button: info.button, number: info.number, clickState: 1, flags: flags)
        usleep(30_000)
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            try post(info.dragged, at: p, button: info.button, number: info.number, flags: flags)
            usleep(UInt32(max(1, durationMs) * 1000 / n))
        }
        try release(info, at: b, flags: flags)
    }

    /// Positive deltaY scrolls content down (wheel up), negative scrolls content up. Pixel units.
    static func scroll(at p: CGPoint, deltaY: Int, deltaX: Int, flags: CGEventFlags) throws {
        try ensureAccessibility()
        try post(.mouseMoved, at: p, flags: flags)
        // The window server routes wheel events to the window under the pointer as it is now;
        // give the pointer move time to be processed first.
        usleep(80_000)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 3,
                              wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
            throw ControlError("Could not create scroll event")
        }
        // Precise (continuous) pixel deltas, as trackpads and precise mice send; NSScrollView reads these.
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX))
        e.location = p
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32, " ": 0x31,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "escape": 0x35, "esc": 0x35, "command": 0x37, "shift": 0x38, "capslock": 0x39,
        "option": 0x3A, "alt": 0x3A, "control": 0x3B, "ctrl": 0x3B, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ControlError("Could not create keyboard events")
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(25_000) // apps such as Electron drop key-up events that follow key-down too quickly
        up.post(tap: .cghidEventTap)
    }

    static func key(_ name: String, flags: CGEventFlags) throws {
        try ensureAccessibility()
        guard let code = keyCodes[name.lowercased()] else {
            throw ControlError("Unsupported key '\(name)'. Use a letter/digit or a name such as return, tab, escape, left, home, f5.")
        }
        try postKey(code, flags: flags)
    }

    static let shiftedSymbols: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// Types text with real key codes (Shift for capitals and shifted symbols). Characters without a
    /// US key code fall back to a Unicode event.
    static func type(_ text: String) throws {
        try ensureAccessibility()
        for ch in text {
            if ch == "\n" || ch == "\r" { try postKey(0x24, flags: []); usleep(10_000); continue }
            if ch == "\t" { try postKey(0x30, flags: []); usleep(10_000); continue }
            var keyChar = ch
            var shift = false
            if ch.isLetter, ch.isUppercase {
                keyChar = Character(ch.lowercased())
                shift = true
            } else if let base = shiftedSymbols[ch] {
                keyChar = base
                shift = true
            }
            if let code = keyCodes[String(keyChar)] {
                try postKey(code, flags: shift ? .maskShift : [])
            } else {
                var units = Array(String(ch).utf16)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw ControlError("Could not create text events")
                }
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                down.post(tap: .cghidEventTap)
                usleep(25_000)
                up.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
    }
}

// MARK: - Tool dispatch (shared by CLI and MCP)

func textBlock(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }

func runTool(_ name: String, _ a: [String: Any]) throws -> [[String: Any]] {
    switch name {
    case "displays":
        return textBlock(jsonString(Desktop.displays().map(Desktop.displayDict)))

    case "screenshot":
        let displayID = optInt(a, "display_id").map { UInt32($0) }
        let result = try Desktop.screenshot(displayID: displayID, format: str(a, "format", "jpeg"),
                                            maxWidth: optInt(a, "max_width") ?? 1600,
                                            quality: (a["quality"] as? NSNumber)?.doubleValue ?? 0.78)
        var blocks = textBlock(result.items.map { item -> String in
            let c = item.capture
            return jsonString(["display_id": c.display.id, "origin_points": [c.display.x, c.display.y],
                               "size_points": [c.display.width, c.display.height],
                               "source_pixels": [c.image.width, c.image.height], "mime": "image/\(result.format)"] as [String: Any])
        }.joined(separator: "\n"))
        for item in result.items {
            blocks.append(["type": "image", "data": item.data.base64EncodedString(),
                           "mimeType": result.format == "png" ? "image/png" : "image/jpeg"])
        }
        return blocks

    case "mouse_move":
        try Input.move(to: CGPoint(x: try num(a, "x"), y: try num(a, "y")), flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("moved")

    case "mouse_position":
        let p = Input.position()
        return textBlock(jsonString(["x": p.x, "y": p.y]))

    case "mouse_click":
        try Input.click(at: CGPoint(x: try num(a, "x"), y: try num(a, "y")), button: str(a, "button", "left"),
                        count: optInt(a, "count") ?? 1, flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("clicked")

    case "mouse_down":
        try Input.mouseDown(at: CGPoint(x: try num(a, "x"), y: try num(a, "y")), button: str(a, "button", "left"),
                            flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("down")

    case "mouse_up":
        try Input.mouseUp(at: CGPoint(x: try num(a, "x"), y: try num(a, "y")), button: str(a, "button", "left"),
                          flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("up")

    case "mouse_drag":
        try Input.drag(from: CGPoint(x: try num(a, "x1"), y: try num(a, "y1")),
                       to: CGPoint(x: try num(a, "x2"), y: try num(a, "y2")),
                       button: str(a, "button", "left"), steps: optInt(a, "steps") ?? 20,
                       durationMs: optInt(a, "duration_ms") ?? 300, flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("dragged")

    case "mouse_scroll":
        try Input.scroll(at: CGPoint(x: try num(a, "x"), y: try num(a, "y")), deltaY: optInt(a, "delta_y") ?? 0,
                         deltaX: optInt(a, "delta_x") ?? 0, flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("scrolled")

    case "key_press":
        try Input.key(str(a, "key", ""), flags: try Input.flags(strings(a, "modifiers")))
        return textBlock("key sent")

    case "type_text":
        try Input.type(str(a, "text", ""))
        return textBlock("typed")

    default:
        throw ControlError("Unknown tool '\(name)'")
    }
}

// MARK: - MCP server (JSON-RPC 2.0 over stdio)

func schema(_ props: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

let coordProps: [String: [String: Any]] = [
    "x": ["type": "number", "description": "Global desktop point (top-left origin of main display)"],
    "y": ["type": "number", "description": "Global desktop point"],
]
let modifierProp: [String: Any] = ["type": "array", "items": ["type": "string"],
                                   "description": "Any of: command, control, option, shift"]
let buttonProp: [String: Any] = ["type": "string", "enum": ["left", "right", "middle"]]

func toolDefinitions() -> [[String: Any]] {
    func tool(_ name: String, _ description: String, _ inputSchema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
    func merged(_ extra: [String: [String: Any]], required: [String] = ["x", "y"]) -> [String: Any] {
        schema(coordProps.merging(extra) { $1 }, required: required)
    }
    return [
        tool("displays", "List active monitors with global point origin/size and pixel size.", schema()),
        tool("screenshot", "Capture all monitors (or one). Returns metadata text plus one image per display. Coordinates are global points.",
             schema(["display_id": ["type": "integer"], "max_width": ["type": "integer", "description": "Default 1600; 0 = native"],
                     "format": ["type": "string", "enum": ["jpeg", "png"]], "quality": ["type": "number"]])),
        tool("mouse_position", "Return the current pointer position in global points.", schema()),
        tool("mouse_move", "Move the pointer (becomes a drag if a button is held).", merged(["modifiers": modifierProp])),
        tool("mouse_click", "Click at a point. count=2 is a double-click, 3 a triple-click.",
             merged(["button": buttonProp, "count": ["type": "integer"], "modifiers": modifierProp])),
        tool("mouse_down", "Press a mouse button at a point and keep it held (use with mouse_move and mouse_up).",
             merged(["button": buttonProp, "modifiers": modifierProp])),
        tool("mouse_up", "Release a mouse button at a point.", merged(["button": buttonProp, "modifiers": modifierProp])),
        tool("mouse_drag", "Press at (x1,y1), drag to (x2,y2) in interpolated steps, release.",
             schema(["x1": ["type": "number"], "y1": ["type": "number"], "x2": ["type": "number"], "y2": ["type": "number"],
                     "button": buttonProp, "steps": ["type": "integer"], "duration_ms": ["type": "integer"], "modifiers": modifierProp],
                    required: ["x1", "y1", "x2", "y2"])),
        tool("mouse_scroll", "Scroll at a point. Negative delta_y scrolls content up (view moves down); positive the reverse.",
             merged(["delta_y": ["type": "integer"], "delta_x": ["type": "integer"], "modifiers": modifierProp], required: ["x", "y", "delta_y"])),
        tool("key_press", "Press and release a key with optional modifiers, e.g. key='n', modifiers=['command'].",
             schema(["key": ["type": "string"], "modifiers": modifierProp], required: ["key"])),
        tool("type_text", "Type text into the focused control.", schema(["text": ["type": "string"]], required: ["text"])),
    ]
}

let oscontrolVersion = "0.2.0"

/// Sent to MCP clients in the initialize result. Clients pass it to the model, so every harness gets the same guidance.
let serverInstructions = """
oscontrol controls the macOS mouse, keyboard, and screens.
Coordinates: every x/y is a GLOBAL DESKTOP POINT, origin at the top-left of the main display (not image pixels).
Screenshots: each image comes with origin_points, size_points, and source_pixels. To convert a point in the image to a desktop point: x = origin_x + image_x * size_width / image_width (same for y).
Work in a loop: take a screenshot, decide, act, then take another screenshot to verify. Do not assume an action worked.
Pointer: mouse_position reads the pointer; click_count 2 selects a word in text, 3 selects a line or paragraph.
Drag: mouse_drag does press-move-release; for finer control use mouse_down, mouse_move, mouse_up.
Keyboard: use "command" for macOS shortcuts (for example Command+N for a new file in VS Code, not Control+N). modifiers is a list of command, control, option, shift.
Typing: type_text types into whichever control has keyboard focus; click the field first.
Scrolling: negative delta_y scrolls content down.
Safety: screenshots show everything on screen. Ask the user before acting in banking, email, password managers, or chat windows, and before sending, deleting, or purchasing anything.
Permissions: if actions do nothing, the host app needs Accessibility and Screen & System Audio Recording permission in System Settings > Privacy & Security.
"""

func runMCP() {
    while let line = readLine() {
        guard let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        let method = request["method"] as? String ?? ""
        guard let id = request["id"] else { continue } // notifications get no response
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        do {
            switch method {
            case "initialize":
                let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
                response["result"] = ["protocolVersion": requested ?? "2025-03-26",
                                      "capabilities": ["tools": ["listChanged": false]],
                                      "serverInfo": ["name": "oscontrol", "version": oscontrolVersion],
                                      "instructions": serverInstructions]
            case "ping":
                response["result"] = [String: Any]()
            case "tools/list":
                response["result"] = ["tools": toolDefinitions()]
            case "tools/call":
                let params = request["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    response["result"] = ["content": try runTool(name, args), "isError": false]
                } catch {
                    response["result"] = ["content": textBlock(String(describing: error)), "isError": true]
                }
            default:
                response["error"] = ["code": -32601, "message": "Method not found: \(method)"]
            }
        }
        if let out = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed]) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}

// MARK: - Benchmark

func runBenchmark(iterations: Int) throws -> String {
    var cg: [Double] = []
    for _ in 0..<iterations {
        let t = Date()
        _ = try Desktop.capture()
        cg.append(Date().timeIntervalSince(t) * 1000)
    }
    var sc: [Double] = []
    for _ in 0..<iterations {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oscontrol-bench-\(UUID().uuidString).png")
        let t = Date()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", url.path]
        try p.run()
        p.waitUntilExit()
        sc.append(Date().timeIntervalSince(t) * 1000)
        try? FileManager.default.removeItem(at: url)
        if p.terminationStatus != 0 { throw ControlError("screencapture failed (Screen Recording permission?)") }
    }
    let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double(max(1, $0.count)) }
    return jsonString([
        "iterations": iterations, "displays": Desktop.displays().count,
        "methods": [
            "CGDisplayCreateImage": ["mean_ms": mean(cg), "samples_ms": cg],
            "screencapture_process_to_disk": ["mean_ms": mean(sc), "samples_ms": sc],
        ],
    ] as [String: Any])
}

// MARK: - CLI

let usageText = """
oscontrol — macOS mouse, keyboard, and multi-monitor screen control

Usage:
  oscontrol displays
  oscontrol screenshot [--display ID] [--output FILE] [--format jpeg|png] [--max-width PX] [--quality 0.78]
  oscontrol mouse position
  oscontrol mouse move X Y [--modifiers LIST]
  oscontrol mouse click X Y [--button left|right|middle] [--count 1|2|3] [--modifiers LIST]
  oscontrol mouse down X Y [--button B] [--modifiers LIST]
  oscontrol mouse up X Y [--button B] [--modifiers LIST]
  oscontrol mouse drag X1 Y1 X2 Y2 [--button B] [--steps N] [--duration-ms MS] [--modifiers LIST]
  oscontrol mouse scroll X Y DELTA_Y [--delta-x N] [--modifiers LIST]
  oscontrol key press KEY [--modifiers LIST]
  oscontrol type TEXT
  oscontrol doctor | permissions | benchmark [--iterations N] | mcp | version | help

LIST is comma-separated: command,control,option,shift.
Coordinates are global desktop points (not Retina pixels). See README.md.
"""

func printBlocks(_ blocks: [[String: Any]]) {
    for b in blocks where (b["type"] as? String) == "text" {
        if let t = b["text"] as? String { print(t) }
    }
}

func runCLI(_ raw: [String]) throws {
    guard let command = raw.first else { print(usageText); return }
    let args = Args(Array(raw.dropFirst()))
    let pos = args.positional
    func coord(_ i: Int, _ name: String) throws -> Double {
        guard i < pos.count, let d = Double(pos[i]) else { throw ControlError("Missing or invalid number <\(name)>") }
        return d
    }
    func modsDict() -> [String: Any] {
        ["modifiers": (args.option("modifiers") ?? "").split(separator: ",").map { String($0) }]
    }

    switch command {
    case "help", "--help", "-h":
        print(usageText)
    case "version", "--version", "-v":
        print("oscontrol \(oscontrolVersion)")
    case "doctor":
        print(jsonString(["accessibility_trusted": AXIsProcessTrusted(),
                          "post_event_access": CGPreflightPostEventAccess(),
                          "screen_capture_access": CGPreflightScreenCaptureAccess(),
                          "left_button_held": CGEventSource.buttonState(.hidSystemState, button: .left),
                          "right_button_held": CGEventSource.buttonState(.hidSystemState, button: .right),
                          "middle_button_held": CGEventSource.buttonState(.hidSystemState, button: .center)] as [String: Any]))
    case "permissions":
        _ = CGRequestPostEventAccess()
        _ = CGRequestScreenCaptureAccess()
        print("Requested. Grant the calling app in System Settings → Privacy & Security: Accessibility, Screen & System Audio Recording (and Input Monitoring if listed). Restart the app afterward.")
    case "mcp":
        runMCP()
    case "displays":
        printBlocks(try runTool("displays", [:]))
    case "benchmark":
        print(try runBenchmark(iterations: max(1, Int(args.option("iterations") ?? "5") ?? 5)))
    case "screenshot":
        var a: [String: Any] = ["format": args.option("format") ?? "jpeg", "max_width": Int(args.option("max-width") ?? "1600") ?? 1600]
        if let d = args.option("display") { a["display_id"] = Int(d) }
        if let q = args.option("quality") { a["quality"] = Double(q) ?? 0.78 }
        let result = try Desktop.screenshot(displayID: (a["display_id"] as? Int).map { UInt32($0) },
                                            format: a["format"] as? String ?? "jpeg",
                                            maxWidth: a["max_width"] as? Int ?? 1600,
                                            quality: (a["quality"] as? Double) ?? 0.78)
        let out = args.option("output")
        let ext = result.format == "png" ? "png" : "jpg"
        for item in result.items {
            let path: String
            if let out, result.items.count == 1 { path = out }
            else if let out { path = "\(out)-\(item.capture.display.id).\(ext)" }
            else { path = "display-\(item.capture.display.id).\(ext)" }
            try item.data.write(to: URL(fileURLWithPath: path))
            print(jsonString(["display_id": item.capture.display.id, "path": path, "bytes": item.data.count,
                              "source_pixels": [item.capture.image.width, item.capture.image.height]] as [String: Any]))
        }
    case "mouse":
        let sub = pos.first ?? ""
        let rest = Array(pos.dropFirst())
        switch sub {
        case "position":
            printBlocks(try runTool("mouse_position", [:]))
        case "move":
            _ = try runTool("mouse_move", ["x": try coord(1, "X"), "y": try coord(2, "Y")].merging(modsDict()) { $1 })
            print("ok")
        case "click":
            var a: [String: Any] = ["x": try coord(1, "X"), "y": try coord(2, "Y"), "button": args.option("button") ?? "left",
                                    "count": Int(args.option("count") ?? "1") ?? 1]
            a.merge(modsDict()) { $1 }
            _ = try runTool("mouse_click", a)
            print("ok")
        case "down", "up":
            var a: [String: Any] = ["x": try coord(1, "X"), "y": try coord(2, "Y"), "button": args.option("button") ?? "left"]
            a.merge(modsDict()) { $1 }
            _ = try runTool(sub == "down" ? "mouse_down" : "mouse_up", a)
            print("ok")
        case "drag":
            var a: [String: Any] = ["x1": try coord(1, "X1"), "y1": try coord(2, "Y1"), "x2": try coord(3, "X2"), "y2": try coord(4, "Y2"),
                                    "button": args.option("button") ?? "left",
                                    "steps": Int(args.option("steps") ?? "20") ?? 20,
                                    "duration_ms": Int(args.option("duration-ms") ?? "300") ?? 300]
            a.merge(modsDict()) { $1 }
            _ = try runTool("mouse_drag", a)
            print("ok")
        case "scroll":
            var a: [String: Any] = ["x": try coord(1, "X"), "y": try coord(2, "Y"), "delta_y": Int(rest.count > 2 ? rest[2] : "0") ?? 0,
                                    "delta_x": Int(args.option("delta-x") ?? "0") ?? 0]
            a.merge(modsDict()) { $1 }
            _ = try runTool("mouse_scroll", a)
            print("ok")
        default:
            throw ControlError("Unknown mouse command. Use position, move, click, down, up, drag, or scroll.")
        }
    case "key":
        guard pos.first == "press", pos.count >= 2 else { throw ControlError("Usage: oscontrol key press KEY [--modifiers LIST]") }
        var a: [String: Any] = ["key": pos[1]]
        a.merge(modsDict()) { $1 }
        _ = try runTool("key_press", a)
        print("ok")
    case "type":
        guard !pos.isEmpty else { throw ControlError("Usage: oscontrol type TEXT") }
        _ = try runTool("type_text", ["text": pos.joined(separator: " ")])
        print("ok")
    default:
        throw ControlError("Unknown command '\(command)'. Run `oscontrol help`.")
    }
}

do {
    try runCLI(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("oscontrol: \(error)\n".utf8))
    exit(1)
}

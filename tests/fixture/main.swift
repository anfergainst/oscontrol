// oscontrol-fixture — a deterministic AppKit window used by the end-to-end tests.
//
// It exposes known UI elements (text view, draggable box, button, right-click menu,
// text field, scroll view) and writes a JSON state file several times per second:
//   - every mouse/keyboard/scroll event it receives (global top-left coordinates)
//   - the text, caret/selection, and the screen rectangle of each element
// Tests drive it through `oscontrol` and then assert on that state.
//
// Usage: oscontrol-fixture [STATE_JSON_PATH]

import AppKit
import Foundation

let statePath: String = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/oscontrol-fixture/state.json"

func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 1000 }

/// Converts a rect in `view` coordinates to global top-left-origin points (oscontrol's coordinate space).
func globalRect(_ rect: NSRect, in view: NSView) -> [Double] {
    guard let window = view.window else { return [0, 0, 0, 0] }
    let r = window.convertToScreen(view.convert(rect, to: nil))
    return [Double(r.minX), Double(primaryHeight() - r.maxY), Double(r.width), Double(r.height)]
}

// MARK: - Shared state recorder

final class Store {
    static let shared = Store()
    var events: [[String: Any]] = []
    var ready = false
    var pressCount = 0
    var lastMenuChoice = ""
    var menuChoiceCount = 0
    var scrollY: Double = 0
    var menuOpenCount = 0
    var menuAnchor: [Double] = [0, 0]
    var wordRects: [String: [Double]] = [:]

    weak var textView: NSTextView?
    weak var field: NSTextField?
    weak var box: NSView?
    weak var button: NSButton?
    weak var contextView: NSView?
    weak var scrollView: NSScrollView?

    func modifierNames(_ f: NSEvent.ModifierFlags) -> [String] {
        var out: [String] = []
        if f.contains(.command) { out.append("command") }
        if f.contains(.control) { out.append("control") }
        if f.contains(.option) { out.append("option") }
        if f.contains(.shift) { out.append("shift") }
        return out
    }

    func typeName(_ t: NSEvent.EventType) -> String {
        switch t {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .otherMouseDown: return "otherMouseDown"
        case .otherMouseUp: return "otherMouseUp"
        case .otherMouseDragged: return "otherMouseDragged"
        case .mouseMoved: return "mouseMoved"
        case .scrollWheel: return "scrollWheel"
        case .keyDown: return "keyDown"
        default: return "other"
        }
    }

    func record(_ event: NSEvent) {
        var entry: [String: Any] = ["type": typeName(event.type), "modifiers": modifierNames(event.modifierFlags)]
        if event.type == .keyDown {
            entry["characters"] = event.characters ?? ""
            entry["keyCode"] = Int(event.keyCode)
        } else {
            let p: NSPoint
            if let w = event.window {
                p = w.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            } else {
                p = NSEvent.mouseLocation
            }
            entry["x"] = Double(p.x)
            entry["y"] = Double(primaryHeight() - p.y)
            // NSEvent raises an Objective-C exception for buttonNumber/clickCount on scroll events,
            // which wedges event dispatch. Read those properties only for mouse events that carry them.
            if event.type == .scrollWheel {
                entry["deltaY"] = Double(event.scrollingDeltaY)
                entry["deltaX"] = Double(event.scrollingDeltaX)
            } else {
                entry["button"] = Int(event.buttonNumber)
                if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
                    .contains(event.type) {
                    entry["clickCount"] = event.clickCount
                }
            }
        }
        events.append(entry)
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    func snapshot() -> [String: Any] {
        var s: [String: Any] = ["ready": ready, "events": events,
                                "frontmostPid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "pressCount": pressCount,
                                "lastMenuChoice": lastMenuChoice, "menuChoiceCount": menuChoiceCount,
                                "scrollY": scrollY, "wordRects": wordRects,
                                "menuOpenCount": menuOpenCount, "menuAnchor": menuAnchor,
                                "keyWindow": NSApp.keyWindow != nil]
        if let tv = textView {
            let r = tv.selectedRange()
            let ns = tv.string as NSString
            s["text"] = tv.string
            s["selectedRange"] = [r.location, r.length]
            s["selectedText"] = r.length > 0 ? ns.substring(with: r) : ""
            s["textRect"] = globalRect(tv.bounds, in: tv)
        }
        if let f = field {
            s["field"] = f.stringValue
            s["fieldRect"] = globalRect(f.bounds, in: f)
        }
        if let b = box { s["boxRect"] = globalRect(b.bounds, in: b) }
        if let b = button { s["buttonRect"] = globalRect(b.bounds, in: b) }
        if let c = contextView { s["contextRect"] = globalRect(c.bounds, in: c) }
        if let sv = scrollView { s["scrollRect"] = globalRect(sv.bounds, in: sv) }
        return s
    }

    func flush() {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: statePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - UI pieces

final class Canvas: NSView {
    override var isFlipped: Bool { true }
}

final class Handler: NSObject {
    @objc func pressed(_ sender: Any?) { Store.shared.pressCount += 1 }
    @objc func pickMenu(_ sender: NSMenuItem) {
        Store.shared.lastMenuChoice = sender.title
        Store.shared.menuChoiceCount += 1
    }
}
let handler = Handler()

/// Moves itself while the mouse is dragged inside it.
final class DragBox: NSView {
    private var grab = NSPoint.zero
    // Accept the click that activates the window, so the very first press is not swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        grab = NSPoint(x: p.x - frame.origin.x, y: p.y - frame.origin.y)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        let p = sv.convert(event.locationInWindow, from: nil)
        frame.origin = NSPoint(x: p.x - grab.x, y: p.y - grab.y)
    }
}

func computeWordRects(_ tv: NSTextView, _ words: [String]) {
    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
    lm.ensureLayout(for: tc)
    let ns = tv.string as NSString
    for w in words {
        let r = ns.range(of: w)
        if r.location == NSNotFound { continue }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        Store.shared.wordRects[w] = globalRect(rect, in: tv)
    }
}

// MARK: - Build the window

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// A standard main menu. Without an Edit menu AppKit does not map Command+X/C/V/A/Z to
// cut/copy/paste/select-all/undo, so keyboard shortcuts would silently do nothing.
func buildMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "Quit oscontrol-fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(redo)
    edit.addItem(.separator())
    edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = edit
    app.mainMenu = main
}
buildMainMenu()

let contentSize = NSSize(width: 900, height: 620)
let window = NSWindow(
    contentRect: NSRect(x: 100, y: primaryHeight() - 100 - contentSize.height, width: contentSize.width, height: contentSize.height),
    styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "oscontrol fixture"
let canvas = Canvas(frame: NSRect(origin: .zero, size: contentSize))
window.contentView = canvas

// Text view: caret, selection, undo, typing.
let textView = NSTextView(frame: NSRect(x: 20, y: 20, width: 420, height: 200))
textView.font = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
textView.isRichText = false
textView.isAutomaticQuoteSubstitutionEnabled = false
textView.allowsUndo = true
textView.string = "The quick brown fox\njumps over the lazy dog\nthird line here"
canvas.addSubview(textView)
Store.shared.textView = textView

// Draggable object.
let box = DragBox(frame: NSRect(x: 470, y: 20, width: 120, height: 120))
box.wantsLayer = true
box.layer?.backgroundColor = NSColor.systemRed.cgColor
canvas.addSubview(box)
Store.shared.box = box

// Button.
let button = NSButton(frame: NSRect(x: 470, y: 170, width: 120, height: 32))
button.title = "Press me"
button.bezelStyle = .rounded
button.target = handler
button.action = #selector(Handler.pressed(_:))
canvas.addSubview(button)
Store.shared.button = button

// Text field.
let field = NSTextField(frame: NSRect(x: 470, y: 230, width: 300, height: 28))
field.placeholderString = "Type here"
canvas.addSubview(field)
Store.shared.field = field

/// Right-click target. It pops up a native NSMenu with "Beta" positioned exactly under the click point,
/// so tests know where the item is without relying on Accessibility (which does not always expose popup menus).
final class ContextView: NSView {
    let popupMenu = NSMenu()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let w = window {
            let anchor = w.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
            Store.shared.menuAnchor = [Double(anchor.x), Double(primaryHeight() - anchor.y)]
        }
        Store.shared.menuOpenCount += 1
        Store.shared.flush()
        popupMenu.popUp(positioning: popupMenu.item(at: 1), at: p, in: self)
    }
}

// Right-click target with a context menu.
let contextView = ContextView(frame: NSRect(x: 20, y: 250, width: 380, height: 80))
contextView.wantsLayer = true
contextView.layer?.backgroundColor = NSColor.lightGray.cgColor
/// A label that lets mouse events pass through to the view beneath it.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
let label = PassThroughLabel(labelWithString: "Right-click here")
label.frame = NSRect(x: 10, y: 30, width: 200, height: 20)
contextView.addSubview(label)
let menu = contextView.popupMenu
for title in ["Alpha", "Beta", "Gamma"] {
    let item = NSMenuItem(title: title, action: #selector(Handler.pickMenu(_:)), keyEquivalent: "")
    item.target = handler
    menu.addItem(item)
}
menu.addItem(.separator())
let delete = NSMenuItem(title: "Delete", action: #selector(Handler.pickMenu(_:)), keyEquivalent: "")
delete.target = handler
menu.addItem(delete)
canvas.addSubview(contextView)
Store.shared.contextView = contextView

// Scroll view with 80 lines.
let scroll = NSScrollView(frame: NSRect(x: 20, y: 350, width: 420, height: 240))
scroll.hasVerticalScroller = true
let doc = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1400))
doc.isEditable = false
doc.string = (1...80).map { "Line \($0)" }.joined(separator: "\n")
scroll.documentView = doc
scroll.contentView.postsBoundsChangedNotifications = true
NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { _ in
    Store.shared.scrollY = Double(scroll.contentView.bounds.origin.y)
}
canvas.addSubview(scroll)
Store.shared.scrollView = scroll

// MARK: - Start

_ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                                .otherMouseDown, .otherMouseUp, .otherMouseDragged,
                                                .mouseMoved, .scrollWheel, .keyDown]) { event in
    Store.shared.record(event)
    return event
}

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
window.makeFirstResponder(textView)
computeWordRects(textView, ["The", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "third", "here"])
// SIGUSR1 asks the fixture to bring itself to the front (the test runner sends it before each test).
signal(SIGUSR1, SIG_IGN)
let activateSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
activateSource.setEventHandler {
    app.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(textView)
}
// Mouse-moved and scroll events are only delivered to the key window, so the fixture must be key.
window.acceptsMouseMovedEvents = true
activateSource.resume()

Store.shared.ready = true
Store.shared.flush()


// Register in the common modes so state keeps updating while a menu is open (menu tracking uses its own loop mode).
let stateTimer = Timer(timeInterval: 0.1, repeats: true) { _ in Store.shared.flush() }
RunLoop.main.add(stateTimer, forMode: .common)
app.run()

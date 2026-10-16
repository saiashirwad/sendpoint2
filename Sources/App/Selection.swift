import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Reading the frontmost app's selection, and pasting into it.
enum Selection {
    /// What Accessibility says about the selection, in a few milliseconds.
    /// `nil` means it can't say; the caller then starts `copyViaKeystroke`.
    static func read() -> String? {
        switch accessibilityText() {
        case .text(let text): return text
        case .none: return ""
        case .unknown: return nil
        }
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let revision = pb.changeCount
        Task {
            // The paste shortcut holds ⌃; let it go so the app sees a plain ⌘V.
            for _ in 0..<50 where heldModifiers { try? await Task.sleep(for: .milliseconds(10)) }
            guard pb.changeCount == revision else { return }
            postCommand(kVK_ANSI_V)
        }
    }

    // MARK: Accessibility

    private enum Answer { case text(String), none, unknown }

    private static func accessibilityText() -> Answer {
        guard AXIsProcessTrusted() else { return .unknown }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)   // a hung app can't stall the hotkey
        guard let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return .unknown }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        guard let text: String = attribute(focused, kAXSelectedTextAttribute) else { return .unknown }
        if !text.isEmpty { return .text(text) }
        // Empty is trustworthy only from a real text element with a collapsed caret.
        let count: Int = attribute(focused, kAXNumberOfCharactersAttribute) ?? 0
        guard count > 0, let rangeValue: AXValue = attribute(focused, kAXSelectedTextRangeAttribute) else { return .unknown }
        var range = CFRange()
        return AXValueGetValue(rangeValue, .cfRange, &range) && range.length == 0 ? .none : .unknown
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    // MARK: Keystrokes

    /// Posts ⌘C and returns at once. `deliver` gets the copied text, if any shows up within `timeout`,
    /// and the pasteboard is put back as it was. Call before the card takes focus, so the keystroke reaches the app.
    static func copyViaKeystroke(timeout: TimeInterval, deliver: @escaping (String) -> Void) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pb.changeCount
        postCommand(kVK_ANSI_C)
        let deadline = Date(timeIntervalSinceNow: timeout)
        func poll() {
            if pb.changeCount == before {
                if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005, execute: poll) }
                return
            }
            let copied = pb.string(forType: .string)
            pb.clearContents()
            pb.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
            if let copied { deliver(copied) }
        }
        poll()
    }

    /// ⌃, ⌥ or ⇧ still down. ⌘ is fine: every posted keystroke is a ⌘ chord anyway.
    private static var heldModifiers: Bool {
        !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty
    }

    private static func postCommand(_ key: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

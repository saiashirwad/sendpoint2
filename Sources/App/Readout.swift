import AppKit
import Core

/// The pill that flashes after a stack shortcut: the stack, its notes, and where it sits among the four.
/// Built at launch; shown while `world.readout` is set.
final class Readout: NSPanel {
    private let card = NSView()
    private let number = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let strip = (1...stackCount).map { NSTextField(labelWithString: "\($0)") }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        card.wantsLayer = true
        card.layer!.cornerRadius = cardRadius
        card.layer!.cornerCurve = .continuous
        card.layer!.backgroundColor = NSColor(white: 0.06, alpha: 0.94).cgColor
        number.font = sans(26, .medium)
        number.textColor = ink(0.95)
        name.font = sans(13, .medium)
        name.textColor = ink(0.9)
        count.font = mono(11)
        count.textColor = ink(0.45)
        for digit in strip { digit.font = mono(12) }

        for view in [number, name, count] + strip { card.addSubview(view) }
        contentView = card
    }

    func render(_ w: World) {
        guard w.readout != nil else {
            if isVisible { orderOut(nil) }
            return
        }
        let notes = w.stacks[w.active].count
        number.stringValue = "\(w.active + 1)"
        name.stringValue = w.config.names[w.active]
        count.stringValue = notes == 0 ? "Empty" : notes == 1 ? "1 note" : "\(notes) notes"
        for (i, digit) in strip.enumerated() {
            digit.textColor = i == w.active ? accent : w.stacks[i].isEmpty ? ink(0.3) : ink(0.75)
        }

        // Number, name, count ........ 1 2 3 4
        let height: CGFloat = 52
        let mid = height / 2
        var x: CGFloat = 20
        place(number, &x, mid)
        x += 10
        place(name, &x, mid)
        x += 8
        place(count, &x, mid)
        x += 24
        for digit in strip {
            place(digit, &x, mid)
            x += 10
        }
        let size = NSSize(width: x + 10, height: height)
        card.frame = NSRect(origin: .zero, size: size)
        if let frame = bottomCentre(size) { setFrame(frame, display: true) }
        invalidateShadow()
        if !isVisible { orderFrontRegardless() }
    }
}

import AppKit

// Lays out all floating PhoneBridge cards in the top-right corner of the
// screen: call panels first (priority 0), then notification cards, newest
// on top. Main thread only.
final class ScreenStack {
    static let shared = ScreenStack()

    private struct Entry {
        let panel: NSPanel
        let priority: Int
        let sequence: Int
    }

    private var entries: [Entry] = []
    private var nextSequence = 0

    func add(_ panel: NSPanel, priority: Int) {
        nextSequence += 1
        entries.append(Entry(panel: panel, priority: priority, sequence: nextSequence))
        relayout()
    }

    func remove(_ panel: NSPanel) {
        entries.removeAll { $0.panel === panel }
        relayout()
    }

    // A card whose content changed size (the call panel swapping to its
    // in-call layout) needs the stack re-flowed around it.
    func relayout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        var top = area.maxY - 16
        let ordered = entries.sorted {
            $0.priority != $1.priority ? $0.priority < $1.priority : $0.sequence > $1.sequence
        }
        for entry in ordered {
            let size = entry.panel.frame.size
            let frame = NSRect(
                x: area.maxX - size.width - 16,
                y: top - size.height,
                width: size.width,
                height: size.height)
            // NSWindow's animator proxy silently ignores setFrameOrigin, which
            // left every card at the bottom-left default; setFrame applies
            // reliably and animates repositions of already-visible cards.
            entry.panel.setFrame(frame, display: true, animate: entry.panel.isVisible)
            top -= size.height + 12
        }
    }
}

// Shared config for the borderless floating cards.
func makeCardPanel(hosting: NSView) -> NSPanel {
    let panel = NSPanel(
        contentRect: hosting.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .transient]
    panel.contentView = hosting
    return panel
}

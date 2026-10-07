import AppKit
import Carbon
import CoreGraphics

/// Puts text into the focused field via the clipboard + synthetic ⌘V, then restores the clipboard.
@MainActor
enum Paster {
    static let restoreDelay: TimeInterval = 0.4

    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Leaves `text` on the clipboard without pasting (fallback path).
    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Returns false when the ⌘V events could not be created; the text is then left on the clipboard.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let snapshot = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            pb.clearContents()
            if !snapshot.isEmpty { pb.writeObjects(snapshot) }
        }
        return true
    }
}

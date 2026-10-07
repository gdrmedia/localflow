import AppKit
import Carbon
import CoreGraphics
import LocalFlowCore

/// CGEventTap on flagsChanged + keyDown. Reports hotkey press/release and Esc to the controller.
/// Modifier events are never swallowed; Esc is swallowed only when the controller says so.
final class HotkeyMonitor {
    var key: HotkeyChoice = .rightOption
    /// Called with `true` on press, `false` on release.
    var onHotkey: ((Bool) -> Void)?
    /// Return true to swallow the Esc key.
    var onEscape: (() -> Bool)?

    private(set) var isActive = false
    private(set) var isListenOnly = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hotkeyIsDown = false

    private static let rightOptionDeviceMask: UInt64 = 0x40          // NX_DEVICERALTKEYMASK
    private static let rightOptionKeyCode: Int64 = 61                // kVK_RightOption
    private static let fnKeyCode: Int64 = 63                         // kVK_Function
    private static let escapeKeyCode: Int64 = 53                     // kVK_Escape

    @discardableResult
    func start() -> Bool {
        if isActive { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        var listenOnly = false
        var port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                     eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: info)
        if port == nil {
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: hotkeyTapCallback, userInfo: info)
            listenOnly = true
        }
        guard let port else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        isActive = true
        isListenOnly = listenOnly
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
        hotkeyIsDown = false
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let down: Bool
            switch key {
            case .rightOption:
                guard code == Self.rightOptionKeyCode else { return Unmanaged.passUnretained(event) }
                down = (event.flags.rawValue & Self.rightOptionDeviceMask) != 0
            case .fn:
                guard code == Self.fnKeyCode else { return Unmanaged.passUnretained(event) }
                down = event.flags.contains(.maskSecondaryFn)
            }
            if down != hotkeyIsDown {
                hotkeyIsDown = down
                onHotkey?(down)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == Self.escapeKeyCode, let onEscape, onEscape() {
                return nil   // swallowed (only possible with an active tap)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

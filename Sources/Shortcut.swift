import AppKit
import Carbon

/// Consume only Control–Escape. All other keyboard events pass through unchanged.
final class Shortcut {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var swallowingEscape = false
    let session = TypingSession()
    let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func start() -> Bool {
        if let tap {
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                return CGEvent.tapIsEnabled(tap: tap)
            }
            stop()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let shortcut = Unmanaged<Shortcut>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    shortcut.session.reset()
                    if let tap = shortcut.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) {
                    shortcut.session.reset()
                } else if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
                    if type == .keyUp && shortcut.swallowingEscape {
                        shortcut.swallowingEscape = false
                        return nil
                    }
                    let flags = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
                    if type == .keyDown && flags == .maskControl {
                        if !shortcut.swallowingEscape || event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                            DispatchQueue.main.async { shortcut.action() }
                        }
                        shortcut.swallowingEscape = true
                        return nil
                    }
                    if type == .keyDown { shortcut.session.reset() }
                } else if type == .keyDown {
                    if IsSecureEventInputEnabled() {
                        shortcut.session.reset()
                    } else {
                        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                        shortcut.session.record(key: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                            flags: event.flags, process: pid, time: ProcessInfo.processInfo.systemUptime)
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        runLoopSource = nil
        swallowingEscape = false
        session.reset()
    }
}

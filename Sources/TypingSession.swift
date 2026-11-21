import AppKit
import Carbon

// Count physical typing only. No characters or clipboard contents are recorded.
final class TypingSession {
    private(set) var length = 0
    private var pid: pid_t = 0
    private var lastTime: TimeInterval = 0
    private var observer: AXObserver?
    private var observedPID: pid_t = 0

    func watchFocus(of process: pid_t) {
        guard process != observedPID else { return }
        reset()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observedPID = process
        observer = nil
        guard process > 0, AXObserverCreate(process, { _, _, _, pointer in
            if let pointer { Unmanaged<TypingSession>.fromOpaque(pointer).takeUnretainedValue().reset() }
        }, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(process)
        for event in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, app, event as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func reset() { length = 0 }

    func record(key: Int, flags: CGEventFlags, process: pid_t, time: TimeInterval) {
        if process != pid || time - lastTime > 20 { reset() }
        pid = process
        lastTime = time
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty else { reset(); return }
        switch key {
        case kVK_Delete: length = max(0, length - 1)
        case 0...35, 37...47, kVK_Space, kVK_ANSI_Grave: length += 1
        default: reset()
        }
    }

    func take(process: pid_t, time: TimeInterval) -> Int {
        defer { reset() }
        return process == pid && time - lastTime <= 20 ? length : 0
    }
}

func recentRange(in prefix: NSString, length: Int) -> NSRange? {
    guard length > 0 else { return lastToken(prefix) }
    let text = prefix as String
    let typed = text.suffix(length)
    let suffix = typed.lastIndex(where: { $0.isNewline }).map { typed[typed.index(after: $0)...] } ?? typed
    guard !suffix.isEmpty else { return nil }
    let units = suffix.utf16.count
    let candidate = prefix.length - units
    // A focus notification or input-method change can reset the keystroke count
    // in the middle of a word. Extend that partial prefix to its word boundary.
    let before = prefix.substring(to: candidate) as NSString
    var start = candidate
    if candidate > 0, let last = (before as String).last, !last.isWhitespace {
        if let word = lastToken(before) { start = word.location }
    }
    return NSRange(location: start, length: prefix.length - start)
}

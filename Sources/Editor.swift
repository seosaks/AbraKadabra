import Carbon
import AppKit
import ApplicationServices

struct Issue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Editor {
    let element: AXUIElement
    func get(_ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    func rangeValue(_ range: CFRange) -> AXValue {
        var r = range
        return AXValueCreate(.cfRange, &r)!
    }
    func setRange(_ r: CFRange) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue(r)) == .success
    }
    static func focused() throws -> Editor {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw Issue("Активное приложение не найдено.") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium-based editors expose their editable tree on accessibility activation.
        if let url = app.bundleURL,
           FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        let system = Editor(element: AXUIElementCreateSystemWide())
        guard let obj = system.get(kAXFocusedUIElementAttribute),
              CFGetTypeID(obj) == AXUIElementGetTypeID() else { throw Issue("Поместите курсор в редактируемое поле.") }
        let editor = Editor(element: obj as! AXUIElement)
        if editor.get(kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole || IsSecureEventInputEnabled() {
            throw Issue("Защищённое поле ввода.")
        }
        return editor
    }

    func selection(recentLength: Int) throws -> (text: String, range: CFRange, original: CFRange) {
        var r = CFRange()
        guard let obj = get(kAXSelectedTextRangeAttribute), CFGetTypeID(obj) == AXValueGetTypeID(),
              AXValueGetValue(obj as! AXValue, .cfRange, &r), r.location >= 0 else {
            throw Issue("Приложение не предоставляет доступ к позиции курсора.")
        }
        func read(_ range: CFRange) -> String? {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                    rangeValue(range), &result) == .success, let text = result as? String { return text }
            guard let value = get(kAXValueAttribute) as? NSString, range.location <= value.length,
                  range.length <= value.length - range.location else { return nil }
            return value.substring(with: NSRange(location: range.location, length: range.length))
        }
        if r.length > 0, let text = get(kAXSelectedTextAttribute) as? String ?? read(r), !text.isEmpty {
            return (text, r, r)
        }
        guard r.length == 0, let prefix = read(CFRange(location: 0, length: r.location)) as NSString?,
              let word = recentRange(in: prefix, length: recentLength) else { throw Issue("Выделите текст или поставьте курсор после слова.") }
        return (prefix.substring(with: word), CFRange(location: word.location, length: word.length), r)
    }

    func replace(_ selection: (text: String, range: CFRange, original: CFRange), with text: String) throws {
        let needsSelection = selection.original.length == 0
        if needsSelection && !setRange(selection.range) { throw Issue("Приложение не разрешило выделить слово.") }
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            let tail = selection.original.location - selection.range.location - selection.range.length
            let offset = selection.range.location + (text as NSString).length + (needsSelection ? max(0, tail) : 0)
            _ = setRange(CFRange(location: offset, length: 0))
            return
        }
        // Some web editors expose the range but only accept edits via ordinary paste.
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
           let actual = get(kAXSelectedTextAttribute) as? String, actual == selection.text,
           [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(get(kAXRoleAttribute) as? String ?? ""),
           paste(text, to: pid) { return }
        if needsSelection { _ = setRange(selection.original) }
        throw Issue("Приложение не разрешило заменить текст в этом поле.")
    }
}

private func paste(_ text: String, to pid: pid_t) -> Bool {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_ANSI_V), keyDown: false) else { return false }
    let board = NSPasteboard.general
    let prior = board.pasteboardItems ?? []
    var saved: [NSPasteboardItem] = []
    for item in prior {
        let copy = NSPasteboardItem()
        for type in item.types {
            guard let data = item.data(forType: type), copy.setData(data, forType: type) else { return false }
        }
        saved.append(copy)
    }
    board.clearContents()
    guard board.setString(text, forType: .string) else {
        board.writeObjects(saved)
        return false
    }
    let version = board.changeCount
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.postToPid(pid)
    up.postToPid(pid)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        if board.changeCount == version {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }
    return true
}

import AppKit
import Carbon

// Chat composers can keep their selection in the web engine instead of AX.
@MainActor
func correctChat(pid: pid_t, recentLength: Int, convert: (String) -> (String, Layout)) async throws -> Layout {
    let board = NSPasteboard.general
    func checkFocus() throws {
        guard (Editor.focusedProcess() ?? NSWorkspace.shared.frontmostApplication?.processIdentifier) == pid,
              !IsSecureEventInputEnabled() else { throw Issue("Фокус ввода изменился.") }
    }
    func send(_ key: Int, _ flags: CGEventFlags) throws {
        try checkFocus()
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
                else { throw Issue("Не удалось отправить сочетание клавиш.") }
            event.flags = flags
            event.postToPid(pid)
        }
    }
    try checkFocus()
    let system = Editor(element: AXUIElementCreateSystemWide())
    if let focus = system.get(kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID(),
       Editor(element: focus as! AXUIElement).get(kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {
        throw Issue("Защищённое поле ввода.")
    }
    let initial = board.changeCount
    let saved = try (board.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
            guard let data = item.data(forType: type), copy.setData(data, forType: type)
                else { throw Issue("Не удалось сохранить содержимое буфера обмена.") }
        }
        return copy
    }
    var owned: Int?
    defer {
        if owned == board.changeCount {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }
    func readSelection() async throws -> String? {
        let before = board.changeCount
        try send(kVK_ANSI_C, .maskCommand)
        for _ in 0..<18 {
            try await Task.sleep(nanoseconds: 15_000_000)
            try checkFocus()
            if board.changeCount != before {
                owned = board.changeCount
                return board.string(forType: .string)
            }
        }
        return nil
    }
    guard board.changeCount == initial else { throw Issue("Буфер обмена изменился.") }
    var text = try await readSelection()
    if text?.isEmpty != false {
        if recentLength > 0 {
            for index in 0..<recentLength {
                try send(kVK_LeftArrow, .maskShift)
                if index % 24 == 23 { try await Task.sleep(nanoseconds: 10_000_000) }
            }
        } else {
            try send(kVK_LeftArrow, [.maskAlternate, .maskShift])
        }
        try await Task.sleep(nanoseconds: 45_000_000)
        text = try await readSelection()
        if recentLength > 0, let text, text.count != recentLength || text.contains(where: { $0.isNewline }) {
            throw Issue("Границы набранного текста изменились. Выделите нужный фрагмент.")
        }
    }
    guard let text, !text.isEmpty else { throw Issue("Поставьте курсор в поле сообщения после слова.") }
    let (replacement, layout) = convert(text)
    try checkFocus()
    guard owned == board.changeCount else { throw Issue("Буфер обмена изменился.") }
    board.clearContents()
    owned = board.changeCount
    guard board.setString(replacement, forType: .string) else { throw Issue("Не удалось подготовить вставку.") }
    owned = board.changeCount
    try send(kVK_ANSI_V, .maskCommand)
    try await Task.sleep(nanoseconds: 350_000_000)
    return layout
}

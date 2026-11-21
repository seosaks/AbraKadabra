import AppKit
import Carbon

// Chat composers can keep their selection in the web engine instead of AX.
@MainActor
func correctChat(pid: pid_t, recentLength: Int, convert: (String) -> (String, Layout)) async throws -> Layout {
    let board = NSPasteboard.general
    let appID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
    let isCodeEditor = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains(appID)
    func checkFocus() throws {
        guard (Editor.inputProcess()) == pid,
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
    // VS Code copies the whole line when the selection is empty.
    // Consult the exposed selection before issuing Copy in this editor.
    let selectedText = (try? Editor.focused())?.get(kAXSelectedTextAttribute) as? String
    var text: String?
    if !isCodeEditor || selectedText?.isEmpty == false {
        text = try await readSelection()
    }
    if text?.isEmpty != false {
        if !isCodeEditor, let editor = try? Editor.focused(),
           let selection = try? editor.selection(recentLength: recentLength),
           editor.setRange(selection.range) {
            try await Task.sleep(nanoseconds: 80_000_000)
            guard let selected = try await readSelection(), selected == selection.text else {
                _ = editor.setRange(selection.original)
                throw Issue("Не удалось точно выделить текст. Повторите Ctrl+Esc.")
            }
            text = selected
        } else if recentLength > 0 {
            for index in 0..<recentLength {
                try send(kVK_LeftArrow, .maskShift)
                if index % 24 == 23 { try await Task.sleep(nanoseconds: 10_000_000) }
            }
        } else {
            try send(kVK_LeftArrow, [.maskAlternate, .maskShift])
        }
        if text?.isEmpty != false {
            try await Task.sleep(nanoseconds: 80_000_000)
            text = try await readSelection()
            if recentLength > 0, let text, text.count != recentLength || text.contains(where: { $0.isNewline }) {
                throw Issue("Границы набранного текста изменились. Выделите нужный фрагмент.")
            }
        }
    }
    guard let text, !text.isEmpty else { throw Issue("Поставьте курсор в поле сообщения после слова.") }
    let (replacement, layout) = convert(text)
    try checkFocus()
    // Verify the actual selection immediately before paste. Some editors collapse
    // an AX selection when their input-method or spelling UI updates.
    guard let confirmed = try await readSelection(), confirmed == text else {
        throw Issue("Выделение изменилось перед заменой. Выделите слово и повторите Ctrl+Esc.")
    }
    // Monaco's chat input can expose an empty/stale AXSelectedText even after
    // two successful copies of the keyboard selection. In VS Code the copied
    // selection above is authoritative; do not veto it with that AX value.
    if !isCodeEditor, let editor = try? Editor.focused(),
       let selected = editor.get(kAXSelectedTextAttribute) as? String,
       selected != text {
        throw Issue("Редактор снял выделение. Выделите слово и повторите Ctrl+Esc.")
    }
    guard owned == board.changeCount else { throw Issue("Буфер обмена изменился.") }
    board.clearContents()
    owned = board.changeCount
    guard board.setString(replacement, forType: .string) else { throw Issue("Не удалось подготовить вставку.") }
    owned = board.changeCount
    try send(kVK_ANSI_V, .maskCommand)
    try await Task.sleep(nanoseconds: 350_000_000)
    return layout
}

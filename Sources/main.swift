import AppKit
import Carbon
import ServiceManagement

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let sound = NSMenuItem(title: "Звук после замены", action: #selector(toggleSound), keyEquivalent: "")
    let tones = NSMenu(title: "Звук")
    var toneName: String { UserDefaults.standard.string(forKey: "toneName") ?? "Pop" }

    func configureIcon() {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let badge = NSImage(contentsOf: url) else { return }
        let height: CGFloat = 20
        badge.size = NSSize(width: height * badge.size.width / badge.size.height, height: height)
        badge.isTemplate = false
        item.button?.image = badge
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("АбраКадабра")
    }

    @objc func chooseTone(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.title, forKey: "toneName")
        UserDefaults.standard.set(true, forKey: "sound")
        NSSound(named: sender.title)?.play()
    }

    @objc func layoutChanged() { shortcut.session.reset() }
    @objc func applicationChanged(_ event: Notification) {
        let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        shortcut.session.watchFocus(of: app?.processIdentifier ?? 0)
    }

    let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
    let access = NSMenuItem(title: "Разрешить управление текстом…", action: #selector(requestAccess), keyEquivalent: "")
    lazy var shortcut = Shortcut { [weak self] in self?.correct() }
    var permissionTimer: Timer?
    var shortcutConnected = false

    @objc func reconnectAfterWake() {
        shortcut.stop()
        shortcutConnected = false
        connectShortcut()
    }
    func connectShortcut() {
        if IsSecureEventInputEnabled() {
            shortcutConnected = false
            shortcut.session.reset()
            let issue = "macOS защищает ввод клавиатуры. Ctrl+Esc временно недоступно."
            if lastIssue != issue { report(issue) }
            return
        }
        guard AXIsProcessTrusted(), shortcut.start() else {
            shortcutConnected = false
            report("Ctrl+Esc недоступно. Проверьте разрешение на управление устройством.")
            return
        }
        shortcut.session.watchFocus(of: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
        if !shortcutConnected {
            shortcutConnected = true
            report("")
        }
    }
    var lastIssue = ""
    let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureIcon()
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(reconnectAfterWake),
                name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(layoutChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        item.button?.toolTip = "АбраКадабра · Ctrl+Esc"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "АбраКадабра · Ctrl+Esc", action: nil, keyEquivalent: "")
        menu.addItem(status)
        menu.addItem(.separator())
        let choose = NSMenuItem(title: "Выбрать звук", action: nil, keyEquivalent: "")
        for name in ["Pop", "Glass", "Ping", "Purr", "Tink"] {
            let entry = tones.addItem(withTitle: name, action: #selector(chooseTone(_:)), keyEquivalent: "")
            entry.target = self
        }
        choose.submenu = tones
        for option in [sound, choose, login, access] { option.target = self; menu.addItem(option) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.connectShortcut()
        }
        connectShortcut()
        if !UserDefaults.standard.bool(forKey: "configuredLogin") {
            do {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(true, forKey: "configuredLogin")
            } catch { report("Автозапуск: " + error.localizedDescription) }
        }
        if !AXIsProcessTrusted() { requestAccess() }
    }
    func menuWillOpen(_ menu: NSMenu) {
        for entry in tones.items { entry.state = entry.title == toneName ? .on : .off }
        sound.state = UserDefaults.standard.bool(forKey: "sound") ? .on : .off
        let state = SMAppService.mainApp.status
        login.state = state == .enabled ? .on : state == .requiresApproval ? .mixed : .off
        login.title = state == .requiresApproval ? "Подтвердить автозапуск…" : "Запускать при входе"
        access.isHidden = AXIsProcessTrusted()
        status.title = lastIssue
        status.isHidden = lastIssue.isEmpty
    }
    @objc func requestAccess() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    @objc func toggleSound() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "sound"), forKey: "sound") }
    @objc func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "configuredLogin")
            report("")
        } catch { report("Автозапуск: " + error.localizedDescription) }
    }
    func report(_ message: String) {
        UserDefaults.standard.set(message.isEmpty ? "Готово" : message, forKey: "shortcutStatus")
        lastIssue = message
        item.button?.toolTip = message.isEmpty ? "АбраКадабра · Ctrl+Esc" : message
    }
    var working = false
    func correct() {
        guard !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            UserDefaults.standard.set(Date(), forKey: "lastShortcut")
            do {
                guard AXIsProcessTrusted() else { requestAccess(); throw Issue("Разрешите управление в разделе «Универсальный доступ».") }
                guard let (en, ru) = Layout.pair() else { throw Issue("Добавьте английскую и русскую раскладки в настройках клавиатуры.") }
                func conversion(_ text: String) -> (String, Layout) {
                    let latin = text.filter { $0.isASCII && $0.isLetter }.count
                    let cyrillic = text.unicodeScalars.filter { (0x0400...0x04ff).contains($0.value) }.count
                    let active = Layout(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
                    let toRussian = latin == cyrillic ? active?.id != ru.id : latin > cyrillic
                    let target = toRussian ? ru : en
                    return (convert(text, from: toRussian ? en : ru, to: target), target)
                }
                let target: Layout
                guard let process = Editor.inputProcess(),
                      let app = NSRunningApplication(processIdentifier: process) else {
                    throw Issue("Активное поле ввода не найдено.")
                }
                let length = shortcut.session.take(process: app.processIdentifier, time: ProcessInfo.processInfo.systemUptime)
                let id = app.bundleIdentifier ?? ""
                let isYandex = id == "ru.yandex.desktop.yandex-browser"
                let isChat = ["com.openai.codex", "com.openai.chat", "com.google.GeminiMacOS"].contains(id)
                if IsSecureEventInputEnabled() {
                    throw Issue("Защищённое поле ввода.")
                }
                let usesWebEditor = ["com.figma.Desktop", "com.google.Chrome", "com.microsoft.edgemac",
                                     "org.mozilla.firefox", "com.apple.Safari", "com.apple.Spotlight", "com.seosaks.pulse",
                                     "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].contains(id)
                if isChat || isYandex || usesWebEditor {
                    target = try await correctChat(pid: app.processIdentifier, recentLength: length, convert: conversion)
                } else {
                    let editor = try Editor.focused()
                    if let selection = try? editor.selection(recentLength: length) {
                        let (converted, layout) = conversion(selection.text)
                        if converted != selection.text { try editor.replace(selection, with: converted) }
                        target = layout
                    } else {
                        target = try await correctChat(pid: app.processIdentifier, recentLength: length, convert: conversion)
                    }
                }
                guard TISSelectInputSource(target.source) == noErr else { throw Issue("Не удалось включить целевую раскладку.") }
                report("")
                if UserDefaults.standard.bool(forKey: "sound") { NSSound(named: toneName)?.play() }
            } catch { report(error.localizedDescription) }
        }
    }
}

if CommandLine.arguments.contains("--check") {
    guard let (en, ru) = Layout.pair() else { print("Нет пары раскладок"); exit(2) }
    precondition(convert("Ghbdtn", from: en, to: ru) == "Привет")
    precondition(convert("Руддщ 🌍", from: ru, to: en) == "Hello 🌍")
    precondition(lastToken("🌍 Ghbdtn  ") == NSRange(location: 3, length: 6))
    precondition(recentRange(in: "old ghbdtn", length: 3) == NSRange(location: 4, length: 6))
    precondition(recentRange(in: "old ghbdtn", length: 6) == NSRange(location: 4, length: 6))
    let sample = "Ghbdtn rfr ltkf"
    let prefix = "Ранее написано. " + sample
    let range = recentRange(in: prefix as NSString, length: sample.count)!
    precondition(convert((prefix as NSString).substring(with: range), from: en, to: ru) == "Привет как дела")
    let session = TypingSession()
    for i in 0..<sample.count { session.record(key: 0, flags: [], process: 1, time: Double(i)) }
    precondition(session.take(process: 1, time: 16) == sample.count)
    session.record(key: 0, flags: [], process: 1, time: 20)
    session.record(key: kVK_LeftArrow, flags: [], process: 1, time: 21)
    precondition(session.take(process: 1, time: 22) == 0)
    session.record(key: 0, flags: [], process: 1, time: 30)
    precondition(session.take(process: 1, time: 51) == 0)
    print("Проверено: \(en.id), \(ru.id)")
    exit(0)
}
let application = NSApplication.shared
let controller = Controller()
application.setActivationPolicy(.accessory)
application.delegate = controller
application.run()

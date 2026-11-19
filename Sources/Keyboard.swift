import Carbon
import Foundation

struct Layout {
    let source: TISInputSource
    let id: String
    let languages: [String]
    let keys: [Int: Character]

    init?(_ source: TISInputSource) {
        func property<T>(_ name: CFString) -> T? {
            guard let p = TISGetInputSourceProperty(source, name) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
        }
        guard let id: String = property(kTISPropertyInputSourceID),
              let languages: [String] = property(kTISPropertyInputSourceLanguages),
              let data: Data = property(kTISPropertyUnicodeKeyLayoutData) else { return nil }
        self.source = source
        self.id = id
        self.languages = languages
        let keyboard = UInt32(LMGetKbdType())
        self.keys = data.withUnsafeBytes { raw in
            var result = [Int: Character]()
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return result }
            // Printable positions on ANSI and ISO keyboards, excluding Return and Tab.
            for code in (0...50) where ![36,48,49].contains(code) {
                for shift in [0, 1] {
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay),
                        UInt32(shift << 1), keyboard, UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &dead, chars.count, &length, &chars)
                    let s = String(decoding: chars.prefix(length), as: UTF16.self)
                    if status == noErr, s.count == 1, let ch = s.first, !ch.isWhitespace {
                        result[code + shift * 128] = ch
                    }
                }
            }
            return result
        }
    }

    static func pair() -> (Layout, Layout)? {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let enabled = TISCreateInputSourceList(filter, false).takeRetainedValue() as NSArray
        let preferred = ["en", "ru"].compactMap { TISCopyInputSourceForLanguage($0 as CFString)?.takeRetainedValue() }
        let enabledLayouts = (enabled as! [TISInputSource]).compactMap(Layout.init)
        let enabledIDs = Set(enabledLayouts.map(\.id))
        let layouts = ([current] + preferred).compactMap(Layout.init).filter { enabledIDs.contains($0.id) } + enabledLayouts
        guard let ru = layouts.first(where: { $0.languages.contains("ru") }),
              let en = layouts.first(where: { $0.languages.contains("en") }) else { return nil }
        return (en, ru)
    }
}

func convert(_ text: String, from source: Layout, to target: Layout) -> String {
    var map = [Character: Character]()
    for key in source.keys.keys.sorted() {
        if let a = source.keys[key], let b = target.keys[key], map[a] == nil { map[a] = b }
    }
    return String(text.map { map[$0] ?? $0 })
}

func lastToken(_ prefix: NSString) -> NSRange? {
    let whitespace = CharacterSet.whitespacesAndNewlines
    let end = prefix.rangeOfCharacter(from: whitespace.inverted, options: .backwards)
    guard end.location != NSNotFound else { return nil }
    let limit = NSMaxRange(end)
    let separator = prefix.rangeOfCharacter(from: whitespace, options: .backwards,
        range: NSRange(location: 0, length: limit))
    let start = separator.location == NSNotFound ? 0 : NSMaxRange(separator)
    return NSRange(location: start, length: limit - start)
}

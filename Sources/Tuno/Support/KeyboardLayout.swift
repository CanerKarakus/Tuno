import Carbon.HIToolbox
import Foundation

/// Geçerli klavye düzeniyle karakter ↔ fiziksel tuş dönüşümü.
/// TIS işlevleri yalnızca ana iş parçacığında güvenle çağrılabilir.
@MainActor
enum KeyboardLayout {
    /// Fiziksel tuşun (ör. kVK_ANSI_LeftBracket) bu düzende ürettiği karakter.
    static func character(forKeyCode keyCode: Int) -> String? {
        withLayout { layout in
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        } ?? nil
    }

    /// Bu düzende verilen karakteri (değiştirici olmadan) üreten tuş; yoksa ABD düzeni varsayılır.
    static func keyCode(for character: String, fallback: Int) -> Int {
        let target = character.lowercased()
        for code in 0..<128 where self.character(forKeyCode: code)?.lowercased() == target {
            return code
        }
        return fallback
    }

    private static func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T) -> T? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer in
            buffer.baseAddress.map { body($0.assumingMemoryBound(to: UCKeyboardLayout.self)) }
        }
    }
}

/// Tuno'nun kendi ürettiği olayları işaretlemek için (kendi yakalayıcımız bunları geçirir).
enum SyntheticEvent {
    static let marker: Int64 = 0x54554E4F // 'TUNO'

    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// ⌘V gibi bir kısayolu öndeki uygulamaya gönderir.
    static func postKey(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            else { continue }
            event.flags = flags
            mark(event)
            event.post(tap: .cghidEventTap)
        }
    }

    static func postMouseButton(_ button: Int64, at location: CGPoint? = nil) {
        let point = location ?? CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: .center) else { continue }
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            mark(event)
            event.post(tap: .cghidEventTap)
        }
    }
}

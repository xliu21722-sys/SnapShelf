import AppKit
import Carbon

@MainActor
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onKey: ((UInt32) -> Void)?
    static let keyCodes: [String: UInt32] = [
        "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5,
        "H": 4, "I": 34, "J": 38, "K": 40, "L": 37, "M": 46,
        "N": 45, "O": 31, "P": 35, "Q": 12, "R": 15, "S": 1,
        "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6
    ]

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let object = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let value = id.id
            Task { @MainActor in object.onKey?(value) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func set(id: UInt32, letter: String) throws {
        guard let key = Self.keyCodes[letter] else { return }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(key, UInt32(optionKey), EventHotKeyID(signature: 0x53534C46, id: id),
                                         GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr, let replacement else {
            throw NSError(domain: "SnapShelf", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "⌥ \(letter) 无法注册，可能已被其他功能占用，请换一个字母。"])
        }
        if let old = refs[id] { UnregisterEventHotKey(old) }
        refs[id] = replacement
    }

    func enableEscape(_ enabled: Bool) {
        if let old = refs.removeValue(forKey: 99) { UnregisterEventHotKey(old) }
        if enabled {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(53, 0, EventHotKeyID(signature: 0x53534C46, id: 99), GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { refs[99] = ref }
        }
    }
}

import CoreAudio
import AudioToolbox

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String { "\(context) (OSStatus \(status))" }

    /// 'what' / '!hog' gibi izin hatalarını ayırt etmek için.
    var isPermissionDenied: Bool {
        status == kAudioHardwareIllegalOperationError || status == kAudioDevicePermissionsError
    }
}

extension AudioObjectPropertyAddress {
    init(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(self, &address) else { return false }
        return AudioObjectIsPropertySettable(self, &address, &settable) == noErr && settable.boolValue
    }

    /// Sabit boyutlu bir özelliği okur; başarısız olursa `nil` döner.
    func read<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        guard AudioObjectHasProperty(self, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    func readString(_ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        guard AudioObjectHasProperty(self, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Değişken uzunluklu POD dizisi okur (ör. AudioObjectID listesi).
    func readArray<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, of _: T.Type = T.self) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    @discardableResult
    func write<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(self, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    /// Akış yapılandırmasındaki toplam kanal sayısı.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Core Audio özellik dinleyicisi; nesne serbest kalınca kaydı siler.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &self.address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

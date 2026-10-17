import Foundation

/// Hangi dokunmatik yüzeyde (dahili/harici trackpad ya da Magic Mouse) o an parmak olduğunu
/// izler. Kaydırma olayları kaynak aygıtı taşımadığından, trackpad ile Magic Mouse'u
/// ayırt etmenin güvenilir yolu budur. macOS'un MultitouchSupport çerçevesi (özel API)
/// çalışma anında yüklenir; bulunamazsa izleme sessizce devre dışı kalır.
final class MultitouchMonitor: @unchecked Sendable {
    static let shared = MultitouchMonitor()

    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>
    private typealias DeviceBool = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias GetFamily = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
    private typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    typealias FrameCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, FrameCallback) -> Void

    private let createList: CreateList?
    private let isBuiltIn: DeviceBool?
    private let getFamily: GetFamily?
    private let getID: GetID?
    private let start: Start?
    private let register: Register?

    private let lock = NSLock()
    /// Aygıt işaretçisi → trackpad mı (true) yoksa Magic Mouse mu (false).
    private var kinds: [UnsafeMutableRawPointer: Bool] = [:]
    private var knownIDs: Set<UInt64> = []
    private var lists: [CFArray] = []   // aygıtları canlı tutar

    // Dokunma çerçevesi iş parçacığı yazar, olay yakalama iş parçacığı okur.
    private(set) var trackpadFingers: Int32 = 0
    private(set) var trackpadTime: TimeInterval = 0
    private(set) var mouseFingers: Int32 = 0
    private(set) var mouseTime: TimeInterval = 0

    var isAvailable: Bool { createList != nil && register != nil && start != nil }

    /// Trackpad'de üç parmakla dokunma → orta tık.
    var middleClickEnabled = false
    var onMiddleClick: (@Sendable () -> Void)?

    // Üç parmak dokunuşu algılama (dokunma iş parçacığında)
    private var tapStart: TimeInterval = 0
    private var tapMaxFingers: Int32 = 0
    private var tapOrigin: (x: Float, y: Float)?
    private var tapMoved = false

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
        }
        createList = symbol("MTDeviceCreateList", CreateList.self)
        isBuiltIn = symbol("MTDeviceIsBuiltIn", DeviceBool.self)
        getFamily = symbol("MTDeviceGetFamilyID", GetFamily.self)
        getID = symbol("MTDeviceGetDeviceID", GetID.self)
        start = symbol("MTDeviceStart", Start.self)
        register = symbol("MTRegisterContactFrameCallback", Register.self)
    }

    /// Yeni bağlanan aygıtları da yakalamak için tekrar tekrar çağrılabilir.
    func scan() {
        guard let createList, let register, let start else { return }
        let list = createList().takeRetainedValue()
        var added = false
        for device in list as [AnyObject] {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            var id: UInt64 = 0
            _ = getID?(pointer, &id)
            lock.lock()
            let isNew = !knownIDs.contains(id)
            if isNew {
                knownIDs.insert(id)
                kinds[pointer] = Self.isTrackpad(pointer, builtIn: isBuiltIn, family: getFamily)
            }
            lock.unlock()
            if isNew {
                register(pointer, multitouchFrameCallback)
                start(pointer, 0)
                added = true
            }
        }
        if added { lists.append(list) }
    }

    /// Dahili yüzeyler ve Magic Trackpad'ler trackpad; Magic Mouse aileleri (112–114) fare.
    private static func isTrackpad(_ device: UnsafeMutableRawPointer, builtIn: DeviceBool?, family: GetFamily?) -> Bool {
        if builtIn?(device) == true { return true }
        var familyID: Int32 = 0
        _ = family?(device, &familyID)
        return !(112...114).contains(familyID)
    }

    fileprivate func frame(device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, fingers: Int32) {
        guard let device else { return }
        lock.lock()
        let trackpad = kinds[device] ?? true
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        if trackpad {
            if middleClickEnabled { detectThreeFingerTap(touches: touches, fingers: fingers, now: now) }
            trackpadFingers = fingers
            trackpadTime = now
        } else {
            mouseFingers = fingers
            mouseTime = now
        }
    }

    /// Üç parmakla kısa, hareketsiz bir dokunuşu orta tık olarak algılar.
    private func detectThreeFingerTap(touches: UnsafeMutableRawPointer?, fingers: Int32, now: TimeInterval) {
        if trackpadFingers == 0 && fingers > 0 {          // dokunuş başladı
            tapStart = now
            tapMaxFingers = 0
            tapOrigin = nil
            tapMoved = false
        }
        if fingers > 0 {
            tapMaxFingers = max(tapMaxFingers, fingers)
            if fingers == 3, let centroid = Self.centroid(touches, count: fingers) {
                if let origin = tapOrigin {
                    if hypot(centroid.x - origin.x, centroid.y - origin.y) > 0.04 { tapMoved = true }
                } else {
                    tapOrigin = centroid
                }
            }
        } else if trackpadFingers > 0 {                   // tüm parmaklar kalktı
            if tapMaxFingers == 3, !tapMoved, now - tapStart < 0.3 { onMiddleClick?() }
        }
    }

    /// Dokunuşların normalleştirilmiş (0…1) ortalama konumu. MTTouch yapısında konum
    /// 32. bayttan başlar, yapı 96 bayttır; değerler anlamsızsa `nil` döner.
    private static func centroid(_ touches: UnsafeMutableRawPointer?, count: Int32) -> (x: Float, y: Float)? {
        guard let touches, count > 0 else { return nil }
        var sx: Float = 0, sy: Float = 0
        for i in 0..<Int(count) {
            let base = touches + i * 96 + 32
            let x = base.loadUnaligned(as: Float.self), y = (base + 4).loadUnaligned(as: Float.self)
            guard x.isFinite, y.isFinite, (-0.1...1.1).contains(x), (-0.1...1.1).contains(y) else { return nil }
            sx += x; sy += y
        }
        return (sx / Float(count), sy / Float(count))
    }

    /// Kaydırma başladığında trackpad'de parmak var mıydı?
    func trackpadIsTouched(at time: TimeInterval) -> Bool {
        trackpadFingers > 0 && time - trackpadTime < 0.25
    }
}

private func multitouchFrameCallback(
    device: UnsafeMutableRawPointer?, touches: UnsafeMutableRawPointer?, count: Int32, timestamp: Double, frame: Int32
) -> Int32 {
    MultitouchMonitor.shared.frame(device: device, touches: touches, fingers: count)
    return 0
}

import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Yüz tanıma özelliklerinin paylaştığı tek kamera. Kamera yalnızca en az bir kullanıcı (kurulum, kilit açma,
/// uzaklaşma kontrolü, "başkası bakarsa") abone olduğunda açılır; son abone çıkınca kapanır.
/// Kareler kendi kuyruğunda gelir; geç kalan kareler atılır (iş yetişmezse kamera beklemez).
final class FaceCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let shared = FaceCamera()

    typealias Handler = (CVPixelBuffer) -> Void

    private struct Consumer {
        let interval: CFTimeInterval
        var last: CFTimeInterval = 0
        let handler: Handler
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.tuno.faceid.camera", qos: .userInitiated)
    private var consumers: [UUID: Consumer] = [:]
    private var configured = false
    private var input: AVCaptureDeviceInput?

    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var isAuthorized: Bool { authorization == .authorized }

    static func requestAccess() async -> Bool {
        switch authorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Dahili kamera (kapak kapalıyken yoktur). Yoksa harici bir kamera.
    static var device: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first ?? AVCaptureDevice.default(for: .video)
    }

    static var isAvailable: Bool { isAuthorized && device != nil }

    /// `fps`: bu abonenin saniyede en çok kaç kare istediği.
    @discardableResult
    func subscribe(fps: Double, _ handler: @escaping Handler) -> UUID {
        let id = UUID()
        queue.async {
            self.consumers[id] = Consumer(interval: 1 / max(fps, 0.5), handler: handler)
            self.startIfNeeded()
        }
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        queue.async {
            self.consumers[id] = nil
            if self.consumers.isEmpty, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func startIfNeeded() {
        guard !consumers.isEmpty, FaceCamera.isAuthorized else { return }
        if !configured { configure() }
        // Kapak kapalıyken açılıp sonra açılırsa aygıt değişmiş olabilir.
        if input == nil || input?.device.isConnected == false { attachDevice() }
        if input != nil, !session.isRunning { session.startRunning() }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        attachDevice()
    }

    private func attachDevice() {
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        input = nil
        if let device = FaceCamera.device, let new = try? AVCaptureDeviceInput(device: device), session.canAddInput(new) {
            session.addInput(new)
            input = new
        }
        // Analiz edilen kareler hep aynasız (kameranın gördüğü gibi); önizleme ayrıca aynalanır.
        for output in session.outputs {
            guard let connection = output.connection(with: .video), connection.isVideoMirroringSupported else { continue }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        for (id, consumer) in consumers where now - consumer.last >= consumer.interval * 0.9 {
            consumers[id]?.last = now
            consumer.handler(pixels)
        }
    }
}

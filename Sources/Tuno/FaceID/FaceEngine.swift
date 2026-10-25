import Accelerate
import CoreImage
import CoreML
import Vision

/// Bir karede bulunan yüz. Koordinatlar piksel cinsinden ve Core Image düzenindedir (başlangıç sol alt köşe).
struct DetectedFace {
    let rect: CGRect
    /// 5 nokta: görüntüde soldaki göz, sağdaki göz, burun ucu, soldaki ağız köşesi, sağdaki ağız köşesi.
    let points: [CGPoint]
    /// Baş yönü (göz arası mesafeye oranla). x: aynalı önizlemede sağa dönünce artar; y: yukarı bakınca artar.
    /// Düz bakarken y sıfır değildir; kurulum kendi başlangıç değerini çıkarır.
    let pose: CGPoint
    let eyesOpen: Bool
    /// Vision'ın yüz çekim kalitesi (0…1).
    let quality: Float
    /// Yüz bölgesinin ortalama parlaklığı (0…1).
    let brightness: Double
    /// Yüz genişliğinin kare genişliğine oranı.
    let widthFraction: CGFloat
}

/// Yüz tanıma hattı: Vision ile yüz ve yüz noktaları → ArcFace şablonuna hizalama → AuraFace ile 512 boyutlu
/// yüz özeti; MiniFASNet ile canlılık. Tüm çağrılar kamera kuyruğunda yapılır (eşzamanlı çağrılmaz).
final class FaceEngine: @unchecked Sendable {
    private let embedder: MLModel
    private let liveness: [(model: MLModel, scale: CGFloat)]
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    /// ArcFace'in 112×112 hizalama şablonu (y aşağı); Core Image için y yukarı çevrilir.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ].map { CGPoint(x: $0.x, y: 112 - $0.y) }

    private init(embedder: MLModel, fas27: MLModel, fas40: MLModel) {
        self.embedder = embedder
        liveness = [(fas27, 2.7), (fas40, 4.0)]
    }

    /// Modelleri yükler (ilk seferde birkaç saniye sürebilir; arka planda çağrılmalı).
    static func load() throws -> FaceEngine {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let folder = FaceModels.modelFolder
        func model(_ name: String) throws -> MLModel {
            try MLModel(contentsOf: folder.appending(path: "\(name).mlmodelc"), configuration: config)
        }
        let engine = FaceEngine(embedder: try model("AuraFace"), fas27: try model("FAS27"), fas40: try model("FAS40"))
        engine.warmUp()
        return engine
    }

    /// İlk tahmin yapay zeka çipinde modeli hazırlar (yavaştır): açılışta boş görüntüyle bir kez çalıştırılır.
    private func warmUp() {
        let blank = CIImage(color: .gray)
        if let face = render(blank, width: 112, height: 112) { _ = predict(embedder, face, output: "embedding") }
        if let crop = render(blank, width: 80, height: 80) {
            for (model, _) in liveness { _ = predict(model, crop, output: "logits") }
        }
    }

    // MARK: - Yüz bulma

    /// Karedeki yüzler, büyükten küçüğe. `quality`: Vision kalite ölçümü de yapılsın mı (biraz daha yavaş).
    func detect(_ pixels: CVPixelBuffer, quality: Bool = true) -> [DetectedFace] {
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        guard (try? handler.perform([landmarks])) != nil, let observations = landmarks.results, !observations.isEmpty
        else { return [] }
        var qualities: [UUID: Float] = [:]
        if quality {
            let request = VNDetectFaceCaptureQualityRequest()
            request.inputFaceObservations = observations
            if (try? handler.perform([request])) != nil {
                for result in request.results ?? [] { qualities[result.uuid] = result.faceCaptureQuality ?? 0 }
            }
        }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        return observations.compactMap { face(from: $0, size: size, pixels: pixels, quality: qualities[$0.uuid] ?? 0.5) }
            .sorted { $0.rect.width > $1.rect.width }
    }

    private func face(from observation: VNFaceObservation, size: CGSize, pixels: CVPixelBuffer, quality: Float) -> DetectedFace? {
        guard let marks = observation.landmarks,
              let leftEye = marks.leftEye, let rightEye = marks.rightEye,
              let lips = marks.outerLips, let nose = marks.nose else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
        func center(_ list: [CGPoint]) -> CGPoint {
            CGPoint(x: list.map(\.x).reduce(0, +) / CGFloat(max(list.count, 1)),
                    y: list.map(\.y).reduce(0, +) / CGFloat(max(list.count, 1)))
        }
        let leftEyePoints = points(leftEye), rightEyePoints = points(rightEye)
        let pupilA = points(marks.leftPupil).first, pupilB = points(marks.rightPupil).first
        var eyes = [pupilA ?? center(leftEyePoints), pupilB ?? center(rightEyePoints)].sorted { $0.x < $1.x }
        let lipPoints = points(lips)
        guard let mouthLeft = lipPoints.min(by: { $0.x < $1.x }), let mouthRight = lipPoints.max(by: { $0.x < $1.x })
        else { return nil }
        // Burun ucu: burun sırtının alt ucu ile burun bölgesinin ortası arası.
        let noseCenter = center(points(nose))
        let tip = points(marks.noseCrest).min(by: { $0.y < $1.y }) ?? noseCenter
        let noseTip = CGPoint(x: (noseCenter.x + tip.x) / 2, y: (noseCenter.y + tip.y) / 2)
        if eyes[0] == eyes[1] { eyes[1].x += 1 }

        let eyeMid = CGPoint(x: (eyes[0].x + eyes[1].x) / 2, y: (eyes[0].y + eyes[1].y) / 2)
        let interocular = max(hypot(eyes[1].x - eyes[0].x, eyes[1].y - eyes[0].y), 1)
        // Kamera görüntüsü aynalı değildir; önizleme aynalıdır: x işareti çevrilir.
        let pose = CGPoint(x: -(noseTip.x - eyeMid.x) / interocular, y: (noseTip.y - eyeMid.y) / interocular)

        func openness(_ list: [CGPoint]) -> CGFloat {
            guard let minX = list.map(\.x).min(), let maxX = list.map(\.x).max(),
                  let minY = list.map(\.y).min(), let maxY = list.map(\.y).max(), maxX > minX else { return 0 }
            return (maxY - minY) / (maxX - minX)
        }
        let eyesOpen = openness(leftEyePoints) > 0.11 && openness(rightEyePoints) > 0.11

        let rect = VNImageRectForNormalizedRect(observation.boundingBox, Int(size.width), Int(size.height))
        return DetectedFace(rect: rect, points: [eyes[0], eyes[1], noseTip, mouthLeft, mouthRight], pose: pose,
                            eyesOpen: eyesOpen, quality: quality, brightness: Self.brightness(pixels, in: rect),
                            widthFraction: rect.width / size.width)
    }

    /// Yüz bölgesinden 12×12 örnekle ortalama parlaklık.
    private static func brightness(_ pixels: CVPixelBuffer, in rect: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return 0.5 }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var total = 0.0, count = 0.0
        for i in 0..<12 {
            for j in 0..<12 {
                let x = Int(rect.minX + rect.width * (CGFloat(i) + 0.5) / 12)
                let y = height - 1 - Int(rect.minY + rect.height * (CGFloat(j) + 0.5) / 12)
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let p = base + y * stride + x * 4   // BGRA
                total += (0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : 0.5
    }

    // MARK: - Yüz özeti

    /// 512 boyutlu, birim uzunlukta yüz özeti. Görüntü ve aynası ayrı ayrı hesaplanıp ortalanır (daha kararlı).
    func embedding(_ pixels: CVPixelBuffer, _ face: DetectedFace) -> [Float]? {
        let image = CIImage(cvPixelBuffer: pixels)
        let align = Self.similarity(from: face.points, to: Self.template)
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 112, ty: 0)
        guard let a = render(image.transformed(by: align), width: 112, height: 112),
              let b = render(image.transformed(by: align.concatenating(mirror)), width: 112, height: 112),
              debugSave(a),
              let first = predict(embedder, a, output: "embedding"),
              let second = predict(embedder, b, output: "embedding"), first.count == second.count
        else { return nil }
        var sum = zip(first, second).map { $0 + $1 }
        Self.normalize(&sum)
        return sum
    }

    /// Canlılık olasılığı (0…1): iki MiniFASNet modelinin "gerçek yüz" olasılıklarının ortalaması.
    func liveness(_ pixels: CVPixelBuffer, _ face: DetectedFace) -> Float {
        let image = CIImage(cvPixelBuffer: pixels)
        let width = CGFloat(CVPixelBufferGetWidth(pixels)), height = CGFloat(CVPixelBufferGetHeight(pixels))
        // Vision'ın yüz kutusu eğitimdeki dedektörünkinden dar: biraz büyütülür.
        let box = face.rect.insetBy(dx: -face.rect.width * 0.08, dy: -face.rect.height * 0.12)
        var scores: [Float] = []
        for (model, wanted) in liveness {
            let scale = min((height - 1) / box.height, (width - 1) / box.width, wanted)
            let w = box.width * scale, h = box.height * scale
            var x = box.midX - w / 2, y = box.midY - h / 2
            x = min(max(x, 0), width - 1 - w)
            y = min(max(y, 0), height - 1 - h)
            let transform = CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(scaleX: 80 / w, y: 80 / h))
            guard let crop = render(image.transformed(by: transform), width: 80, height: 80),
                  let logits = predict(model, crop, output: "logits"), logits.count == 3 else { continue }
            let maxLogit = logits.max() ?? 0
            let exps = logits.map { exp($0 - maxLogit) }
            scores.append(exps[1] / exps.reduce(0, +))
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count)
    }

    #if DEBUG
    /// Yalnızca test sürümü: `defaults write app.tuno.mac faceDebugCrops -bool true` ile hizalanmış yüzler
    /// Masaüstü'ndeki TunoFaceDebug klasörüne kaydedilir (en çok 80 kare). Yayın sürümünde bu kod yoktur.
    private var debugCount = 0
    private func debugSave(_ pixels: CVPixelBuffer) -> Bool {
        guard UserDefaults.standard.bool(forKey: "faceDebugCrops"), debugCount < 80 else { return true }
        debugCount += 1
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/TunoFaceDebug")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: String(format: "yuz-%03d.png", debugCount))
        try? context.writePNGRepresentation(of: CIImage(cvPixelBuffer: pixels), to: url, format: .RGBA8,
                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return true
    }
    #else
    private func debugSave(_ pixels: CVPixelBuffer) -> Bool { true }
    #endif

    private func predict(_ model: MLModel, _ pixels: CVPixelBuffer, output: String) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: pixels)]),
              let result = try? model.prediction(from: input),
              let array = result.featureValue(for: output)?.multiArrayValue else { return nil }
        return (0..<array.count).map { array[$0].floatValue }
    }

    private func render(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return buffer
    }

    // MARK: - Matematik

    /// Noktaları şablona taşıyan benzerlik dönüşümü (döndürme + eşit ölçek + kaydırma; en küçük kareler).
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(source.count)
        let ms = CGPoint(x: source.map(\.x).reduce(0, +) / n, y: source.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: target.map(\.x).reduce(0, +) / n, y: target.map(\.y).reduce(0, +) / n)
        var a: CGFloat = 0, b: CGFloat = 0, denominator: CGFloat = 0
        for (s, d) in zip(source, target) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            denominator += sx * sx + sy * sy
        }
        guard denominator > 0 else { return .identity }
        let c = a / denominator, s = b / denominator
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: md.x - (c * ms.x - s * ms.y), ty: md.y - (s * ms.x + c * ms.y))
    }

    static func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return }
        vDSP_vsdiv(vector, 1, &norm, &vector, 1, vDSP_Length(vector.count))
    }

    /// İki birim vektörün benzerliği (-1…1).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}

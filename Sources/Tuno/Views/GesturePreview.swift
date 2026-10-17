import AVFoundation
import SwiftUI

/// Sistem Ayarları'nın kendi hareket önizleme videoları (Trackpad.mov / Mouse.mov).
/// Her video bölümlere ayrılmıştır (ör. "Scroll-Natural"); ilgili bölüm döngüde oynatılır.
enum GestureVideo {
    case trackpad, mouse

    func url(dark: Bool) -> URL {
        let (bundle, name) = switch self {
        case .trackpad: ("TrackpadExtension", "Trackpad")
        case .mouse: ("MouseExtension", "Mouse")
        }
        let file = "/System/Library/ExtensionKit/Extensions/\(bundle).appex/Contents/Resources/\(name)\(dark ? "-dark" : "").mov"
        return URL(fileURLWithPath: file)
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: url(dark: false).path) }
}

struct GesturePreview: View {
    let video: GestureVideo
    let chapter: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if video.isAvailable {
                LoopingChapterPlayer(url: video.url(dark: colorScheme == .dark), chapter: chapter)
                    .id("\(chapter)-\(colorScheme == .dark)")
                    .transition(.opacity)
            } else {
                Image(systemName: "play.slash").foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(920.0 / 282.0, contentMode: .fit)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: chapter)
        .accessibilityHidden(true)
    }
}

private struct LoopingChapterPlayer: NSViewRepresentable {
    let url: URL
    let chapter: String

    func makeNSView(context: Context) -> LoopingPlayerView {
        LoopingPlayerView(url: url, chapter: chapter)
    }

    func updateNSView(_ view: LoopingPlayerView, context: Context) {}

    static func dismantleNSView(_ view: LoopingPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class LoopingPlayerView: NSView {
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?

    @MainActor private static var chapterCache: [URL: [String: CMTimeRange]] = [:]

    init(url: URL, chapter: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        layer?.addSublayer(playerLayer)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false

        Task { @MainActor [weak self] in
            guard let range = await Self.range(of: chapter, in: url), let self else { return }
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            self.looper = AVPlayerLooper(player: self.player, templateItem: item, timeRange: range)
            self.player.play()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }


    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
    }

    @MainActor
    private static func range(of chapter: String, in url: URL) async -> CMTimeRange? {
        if let cached = chapterCache[url] { return cached[chapter] }
        let asset = AVURLAsset(url: url)
        var ranges: [String: CMTimeRange] = [:]
        if let locale = try? await asset.load(.availableChapterLocales).first,
           let groups = try? await asset.loadChapterMetadataGroups(
               withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle]) {
            for group in groups {
                if let title = try? await group.items.first?.load(.stringValue) {
                    ranges[title] = group.timeRange
                }
            }
        }
        chapterCache[url] = ranges
        return ranges[chapter]
    }
}

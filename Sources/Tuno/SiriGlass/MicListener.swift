//
//  MicListener.swift
//  SiriGlass
//  Tuno'ya uyarlandı (macOS, Mac çentiği): Haplo LLC'nin SiriGlass'ı, MIT lisansı (LICENSE-SiriGlass.txt).
//
//  Taps the microphone and hands the frame loop a smooth stream of levels.
//  Asks for permission the first time (the host app's Info.plist needs
//  NSMicrophoneUsageDescription), listens through the phone's microphone
//  while leaving any Bluetooth playback where it is, and puts the audio
//  session back the way it found it when it stops.
//

import AVFoundation
import os

@MainActor
final class MicListener {
    let stream = VoiceStream()
    private var running: Running?
    /// Bumped by stop(), so a start() still waiting on permission or the
    /// audio session knows it has been called off.
    private var generation = 0
    nonisolated private static let log = Logger(subsystem: "SiriGlass", category: "microphone")
    private static var warnedAboutUsageDescription = false

    /// A running engine. Handed between the main actor and the set-up thread, never used on both.
    private final class Running: @unchecked Sendable {
        let engine: AVAudioEngine
        init(engine: AVAudioEngine) { self.engine = engine }
    }

    /// Without this key iOS ends the app the moment it asks for the
    /// microphone, so the drop never asks without it.
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    /// False when there is no microphone to listen to, permission was
    /// refused, or stop() was called meanwhile.
    func start() async -> Bool {
        if running != nil { return true }
        guard Self.hasUsageDescription else {
            if !Self.warnedAboutUsageDescription {
                Self.warnedAboutUsageDescription = true
                Self.log.error("SiriGlass can't listen: add NSMicrophoneUsageDescription to your app's Info.plist. The drop will hear silence.")
            }
            return false
        }
        let ticket = generation
        guard await AVAudioApplication.requestRecordPermission(), ticket == generation else { return false }
        // Session and engine set-up block for a moment: keep them off the
        // main thread so the drop's animation doesn't stall.
        let stream = self.stream
        let started = await Task.detached(priority: .userInitiated) {
            Self.makeEngine(feeding: stream)
        }.value
        guard let started else { return false }
        guard ticket == generation, running == nil else {
            Task.detached(priority: .userInitiated) { Self.tearDown(started) }
            return ticket == generation
        }
        running = started
        return true
    }

    func stop() {
        generation += 1
        stream.reset()
        guard let running else { return }
        self.running = nil
        Task.detached(priority: .userInitiated) { Self.tearDown(running) }
    }

    func levels() -> SiriGlassLevels { stream.levels() }

    /// macOS: ses oturumu yok; giriş doğrudan AVAudioEngine ile dinlenir.
    nonisolated private static func makeEngine(feeding stream: VoiceStream) -> Running? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return nil }
        // Off the main actor: the tap runs on the audio engine's own thread.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { buffer, _ in
            stream.analyze(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            log.error("SiriGlass couldn't start the microphone: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return Running(engine: engine)
    }

    nonisolated private static func tearDown(_ running: Running) {
        running.engine.inputNode.removeTap(onBus: 0)
        running.engine.stop()
    }
}

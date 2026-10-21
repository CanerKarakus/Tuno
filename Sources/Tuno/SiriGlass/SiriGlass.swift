//
//  SiriGlass.swift
//  SiriGlass
//  Tuno'ya uyarlandı (macOS, Mac çentiği): Haplo LLC'nin SiriGlass'ı, MIT lisansı (LICENSE-SiriGlass.txt).
//
//  iOS 27's Siri, for your app: a drop of Liquid Glass that pours out of
//  the Dynamic Island, listens, and lights up with the voice it hears.
//

import SwiftUI

/// What the drop is doing.
public enum SiriGlassState: String, Sendable, Hashable, CaseIterable {
    /// Home: tucked back into the Dynamic Island. Set it to send the drop
    /// away; it pulls back in with a small swell.
    case idle
    /// Out and listening: the light inside dances with the audio.
    case listening
    /// Out and thinking: the light gathers into one lens and swirls slowly
    /// until you change the state.
    case thinking
}

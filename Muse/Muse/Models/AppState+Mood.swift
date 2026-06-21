//
//  AppState+Mood.swift
//  Muse
//
//  Background-mood palette + the Auto day/night timer. Extracted from
//  AppState.swift in the 2026-06-20 code-health refactor (methods only; the
//  @Published mood state and the `autoMoodTimer` handle stay in the core file).
//

import Foundation
import SwiftUI

@MainActor
extension AppState {
    var moodPalette: MoodPalette {
        switch mood {
        case .ink:    return Mood.fallbackPalette
        case .paper:  return Mood.paperPalette
        case .auto:   return autoMoodIsDay ? Mood.paperPalette : Mood.fallbackPalette
        case .custom: return Mood.customPalette(hue: customHue,
                                                saturation: customSaturation,
                                                brightness: customBrightness)
        }
    }

    func setMood(_ m: Mood) {
        withAnimation(.easeInOut(duration: 0.35)) { mood = m }
        m.save()
        updateAutoMoodTimer()
    }

    /// Runs only while the mood is Auto; flips the palette at the
    /// day/night boundary with a slow fade.
    func updateAutoMoodTimer() {
        autoMoodTimer?.invalidate()
        autoMoodTimer = nil
        guard mood == .auto else { return }
        autoMoodIsDay = Mood.isDaytime()
        autoMoodTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mood == .auto else { return }
                let day = Mood.isDaytime()
                if day != self.autoMoodIsDay {
                    withAnimation(.easeInOut(duration: 0.6)) { self.autoMoodIsDay = day }
                }
            }
        }
    }
}

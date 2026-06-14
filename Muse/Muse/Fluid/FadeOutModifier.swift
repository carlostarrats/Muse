//
//  FadeOutModifier.swift
//  Muse
//
//  Simple staggered fade for the delete sequence (no shaders): driven by the
//  delete `progress` (0→1), holds until `fadeStart`, then fades to 0 across
//  `fadeLength`. Must be Animatable so the curve is sampled every frame — a
//  plain `.opacity(curve(progress))` reading an animated @State only tweens the
//  END value linearly, which fades from the very start instead of holding.
//

import SwiftUI

struct FadeOutModifier: ViewModifier, Animatable {
    var progress: Double
    var fadeStart: Double
    var fadeLength: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let fade = progress <= fadeStart ? 1.0
            : max(0.0, 1.0 - (progress - fadeStart) / fadeLength)
        return content.opacity(fade)
    }
}

//
//  BurnUpModifier.swift
//  Muse
//
//  Animatable wrapper for the burnUp layerEffect. Shader uniforms don't
//  animate on their own — Animatable re-evaluates body every frame with
//  the interpolated progress. Apply AFTER fluidDistort so the char
//  follows the water-distorted pixels.
//

import SwiftUI

struct BurnUpModifier: ViewModifier, Animatable {
    var progress: Double
    var seed: Double
    var size: CGSize

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.burnUp(
                .float2(Float(size.width), Float(size.height)),
                .float(Float(progress)),
                .float(Float(seed))
            ),
            maxSampleOffset: .zero,
            isEnabled: progress > 0.001
        )
    }
}

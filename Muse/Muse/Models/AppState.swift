//
//  AppState.swift
//  Muse
//
//  Phase 0 placeholder. The new filesystem-native AppState will be
//  built up in Phase 0.5 with roots, folder tree, and indexer wiring.
//  For now: just enough to keep the app compiling and the water shader
//  reachable.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    /// Whether the water-ripple fluid distortion shader is enabled.
    @Published var fluidEnabled: Bool = false

    /// Fluid distortion simulation — shared across views that opt in.
    let fluidSim = FluidSim()

    /// Mirrors fluidSim.dispImage so SwiftUI observes changes.
    @Published var fluidDispImage: Image = FluidSim.neutralImage
    private var fluidCancellable: AnyCancellable?

    init() {
        fluidCancellable = fluidSim.$dispImage
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .assign(to: \.fluidDispImage, on: self)
    }
}

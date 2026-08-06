//
//  WelcomeOnboardingModal.swift
//  Muse
//
//  The shell presenter is isolated from ContentView's already-large modifier
//  chain so the Swift type checker does not have to solve it inline.
//

import SwiftUI

extension View {
    func welcomeOnboardingModal(store: WelcomeOnboardingStore,
                                palette: MoodPalette,
                                onPresentationChange: @escaping (Bool) -> Void) -> some View {
        modifier(WelcomeOnboardingModalModifier(
            store: store,
            palette: palette,
            onPresentationChange: onPresentationChange))
    }
}

private struct WelcomeOnboardingModalModifier: ViewModifier {
    @ObservedObject var store: WelcomeOnboardingStore
    let palette: MoodPalette
    let onPresentationChange: (Bool) -> Void

    func body(content: Content) -> some View {
        // The welcome is deliberately outside the announcement presenter. If
        // a launch invariant regresses, it still cannot appear underneath it.
        content
            .museModal(isPresented: Binding(
                get: { store.isPresented },
                set: { if !$0 { store.dismiss() } }),
                       width: 760,
                       palette: palette) {
                WelcomeOnboardingView { store.dismiss() }
            }
            .onAppear {
                onPresentationChange(store.isPresented)
            }
            .onChange(of: store.isPresented) { _, presented in
                onPresentationChange(presented)
            }
            .onDisappear {
                onPresentationChange(false)
            }
    }
}

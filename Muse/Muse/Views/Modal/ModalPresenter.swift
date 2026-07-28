//
//  ModalPresenter.swift
//  Muse
//
//  `.museModal(isPresented:width:palette:onDismiss:content:)` — the replacement
//  for `.sheet` on every card modal. See ModalChrome.swift for why the app
//  stopped using sheets.
//
//  Attach it at the SHELL level (ContentView), never inside a sidebar row or a
//  toolbar button: the card is sized from the geometry of whatever it's
//  attached to, so a modal presented from a 240pt sidebar would be laid out
//  against 240pt. Views deeper in the tree raise a flag on AppState and let the
//  shell present.
//

import SwiftUI

extension View {
    /// Present `content` as a centred card over a dimming scrim, inside this
    /// view's own geometry.
    ///
    /// - Parameters:
    ///   - width: the card's ideal width; it shrinks with a narrow window.
    ///   - palette: the active mood, which drives the scrim and card colours.
    ///   - onDismiss: run for EVERY dismissal path — scrim click, Escape, and
    ///     the card's own close button — so a caller can't miss one.
    func museModal<ModalContent: View>(
        isPresented: Binding<Bool>,
        width: CGFloat,
        palette: MoodPalette,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> ModalContent
    ) -> some View {
        modifier(MuseModalPresenter(isPresented: isPresented,
                                    width: width,
                                    palette: palette,
                                    onDismiss: onDismiss,
                                    modal: content))
    }
}

private struct MuseModalPresenter<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let palette: MoodPalette
    let onDismiss: () -> Void
    @ViewBuilder let modal: () -> ModalContent

    func body(content: Content) -> some View {
        content.overlay {
            // The card is built ONLY while presented, so dismissing genuinely
            // removes it from the hierarchy and its `.onDisappear` fires. The
            // Drive share form relies on that to cancel an in-flight publish —
            // hiding the card with opacity instead would leave the upload
            // running headless and the share would go public unseen.
            if isPresented {
                GeometryReader { geo in
                    ZStack {
                        ModalScrim(palette: palette) { dismiss() }
                        card(in: geo.size)
                    }
                    // The layout is driven by the geometry we already have, so
                    // the card is correctly sized on its FIRST frame.
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: ModalChrome.animationDuration), value: isPresented)
    }

    private func card(in available: CGSize) -> some View {
        modal()
            .frame(width: ModalChrome.cardWidth(ideal: width,
                                                available: available.width))
            // A CAP, not a height: the card is content-sized up to this and
            // then its own ScrollView takes over.
            .frame(maxHeight: ModalChrome.cardMaxHeight(available: available.height))
            .background(ModalChrome.cardFill(for: palette))
            .clipShape(RoundedRectangle(cornerRadius: ModalChrome.cornerRadius,
                                        style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ModalChrome.cornerRadius,
                                 style: .continuous)
                    .strokeBorder(ModalChrome.cardStroke(for: palette), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
            // Clicks on the card must not fall through to the scrim's dismiss.
            .contentShape(Rectangle())
            .onTapGesture {}
            .transition(.asymmetric(
                insertion: .opacity.combined(
                    with: .offset(y: ModalChrome.entranceYOffset)),
                removal: .opacity))
            .accessibilityAddTraits(.isModal)
    }

    private func dismiss() {
        isPresented = false
        onDismiss()
    }
}

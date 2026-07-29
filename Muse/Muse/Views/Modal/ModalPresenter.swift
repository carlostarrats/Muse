//
//  ModalPresenter.swift
//  Muse
//
//  `.museModal(isPresented:width:palette:onDismiss:content:)` — the replacement
//  for `.sheet` on every card modal. See ModalChrome.swift for why the app
//  stopped using sheets.
//
//  Attach it to the shell's DETAIL pane (ContentView's `detail:` closure), never
//  inside a sidebar row or a toolbar button: the card is sized and centred
//  against the geometry of whatever it's attached to, so a modal presented from
//  a 240pt sidebar row would be laid out against 240pt. Views deeper in the tree
//  raise a flag on AppState and let the shell present.
//
//  The detail pane and not the whole window, deliberately: the card centres in
//  the CONTENT column, so it stays centred under the user's eye as the sidebar
//  opens and closes instead of drifting off the page's midline. The sidebar is
//  left uncovered and interactive — same as Lineform, which anchors its modal
//  layer inside the page column for exactly this reason.
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

/// The card content's natural height, reported from inside the scroller where
/// it is laid out unclamped.
private struct ModalCardHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MuseModalPresenter<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let palette: MoodPalette
    let onDismiss: () -> Void
    @ViewBuilder let modal: () -> ModalContent
    /// Natural height of the card's content, measured inside the scroller.
    @State private var contentHeight: CGFloat?

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
        let cardWidth = ModalChrome.cardWidth(ideal: width,
                                              available: available.width)
        let cap = ModalChrome.cardMaxHeight(available: available.height)
        // The modal is built EXACTLY ONCE. `ViewThatFits` was used here first
        // and is wrong for this job: it builds every candidate to measure them,
        // and these cards have side effects on appear — Metadata Import kicks
        // off a folder import, Manage Drive Shares loads from Drive, the share
        // form creates an upload service. Doubling those is not something to
        // risk for a layout decision.
        //
        // Instead: the content inside a ScrollView is laid out at its NATURAL
        // height, so a GeometryReader in its background reports exactly how tall
        // the card wants to be. The scroller is given that height, clamped to
        // the window, and scrolling is switched off entirely while it fits — so
        // a three-row modal is three rows tall and nothing bounces.
        return chrome(
            ScrollView {
                // Full card width, no reserved scrollbar strip — the overlay
                // scroller floats above the content. See ModalChrome.
                //
                // maxWidth, not a fixed width: with "Show scroll bars: Always"
                // (or a mouse attached under Automatic) macOS uses a LEGACY
                // scroller, which takes its ~15pt out of the scroll view's
                // content area. A hard width would then overhang and clip on the
                // right; capping lets the content shrink into whatever it's
                // actually given. In the overlay case — the usual one — the
                // proposal is the full card width and this is a no-op.
                modal()
                    .frame(maxWidth: cardWidth)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: ModalCardHeight.self,
                                                   value: proxy.size.height)
                        }
                    )
            }
            .frame(width: cardWidth, height: min(contentHeight ?? cap, cap))
            .scrollDisabled((contentHeight ?? .greatestFiniteMagnitude) <= cap)
            .onPreferenceChange(ModalCardHeight.self) { measured in
                guard measured > 0, contentHeight != measured else { return }
                contentHeight = measured
            }
        )
    }

    /// The card's surface: fill, corner, hairline, shadow and the click-eating
    /// shape that stops a tap on the card reaching the scrim's dismiss.
    private func chrome(_ body: some View) -> some View {
        body
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

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
        let cardWidth = ModalChrome.cardWidth(ideal: width,
                                              available: available.width)
        let cap = ModalChrome.cardMaxHeight(available: available.height)
        // The scrolling decision lives HERE because this is the only place that
        // knows the window's height: the enclosing ZStack proposes it, so
        // ViewThatFits can actually judge "does this fit?". Candidate 1 is the
        // card at its natural height — a three-row modal is three rows tall.
        // Candidate 2 only wins once the content genuinely outgrows the window.
        //
        // Attempts inside the card all failed against the running app: a
        // ScrollView there is greedy, ViewThatFits there is asked for an ideal
        // height and resolves greedy, and a GeometryReader measurement never
        // settled. See ModalScroll.
        return ViewThatFits(in: .vertical) {
            chrome(modal().frame(width: cardWidth))
            chrome(
                ScrollView {
                    modal()
                        .frame(width: cardWidth)
                        // Keeps text clear of the overlay scrollbar macOS draws
                        // at the ScrollView's trailing edge.
                        .padding(.trailing, ModalChrome.scrollBarChannel)
                }
                .frame(width: cardWidth + ModalChrome.scrollBarChannel)
            )
        }
        .frame(maxHeight: cap)
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

//
//  ToneZoneStrip.swift
//  Muse
//
//  The tone-zone control: nine cells shaded black→white, each showing how much
//  of the photo lives in that zone, each draggable vertically to lift or pull
//  it. Hovering a cell hatches the matching pixels on the canvas.
//
//  The disclosure of nine ordinary `EditSlider`s below is not a fallback bolted
//  on for compliance — it IS the VoiceOver path, which is why the strip's drag
//  needs no parallel accessibility action.
//

import SwiftUI

struct ToneZoneStrip: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme

    @State private var slidersExpanded = false

    private static let gainPerPoint = 0.008
    private static let cellHeight: CGFloat = 56
    /// Mass rarely exceeds a quarter of the frame in one zone, so the bars are
    /// amplified to stay readable — they compare zones to each other, they are
    /// not a measurement anyone reads a number off.
    private static let massAmplification = 4.0

    private static let zoneLabels = ["−8", "−7", "−6", "−5", "−4", "−3", "−2", "−1", "0"]

    /// Long enough that opening the card under the cursor doesn't hatch, short
    /// enough that a deliberate hover feels immediate.
    private static let hoverDwellMilliseconds = 220

    @State private var hoverDwell: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingS) {
            // Reset now lives in the CARD HEADING, in the `accessory` slot
            // every other card's Reset uses — it is an ordinary per-card action
            // and had no reason to be the one exception sitting in the body.
            //
            // "On Photo" stays here: it is a MODE, not a per-card action, and
            // it belongs beside the strip it switches the behaviour of.
            HStack(spacing: theme.spacingS) {
                EditorSmallButton(label: String(localized: "On Photo"),
                                  systemName: "dot.viewfinder") {
                    session.toneZoneTargeting.toggle()
                    if !session.toneZoneTargeting { session.hoveredZone = nil }
                }
                .help(Text("Adjust zones on the photo"))
                .foregroundStyle(session.toneZoneTargeting
                                 ? theme.controlAccent : theme.textPrimary)
                Spacer()
            }

            HStack(spacing: 2) {
                ForEach(0..<ToneZoneParams.zoneCount, id: \.self) { index in
                    zoneCell(index: index)
                }
            }

            readout

            // A real button, not a `DisclosureGroup` — that one's hit target is
            // the chevron alone, so the row read as inert text.
            EditorDisclosureRow(label: String(localized: "Zone Sliders"),
                                isExpanded: $slidersExpanded)
            // The reveal is CLIPPED to its own box. Without this the sliders
            // slide in from above their own frame and are drawn over the zone
            // strip, which reads as the strip being pushed around.
            VStack(spacing: 0) {
                if slidersExpanded {
                    VStack(spacing: 2) {
                        ForEach(0..<ToneZoneParams.zoneCount, id: \.self) { index in
                            EditSlider(label: "\(Self.zoneLabels[index]) EV",
                                       value: Binding(get: { gain(index) },
                                                      set: { setGain(index, to: $0) }),
                                       onCommit: session.commitGesture)
                        }
                    }
                    .padding(.top, theme.spacingS)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered = session.hoveredZone, hovered < ToneZoneParams.zoneCount {
            let mass = (session.stats?.zoneMass.count ?? 0) > hovered
                ? session.stats!.zoneMass[hovered] * 100 : 0
            Text("Zone \(hovered + 1) · \(Self.zoneLabels[hovered]) EV · \(String(format: "%.0f", mass))% of pixels")
                .font(theme.valueFont)
                .foregroundStyle(theme.textSecondary)
        } else {
            // Reserved so the panel doesn't jump as the cursor crosses cells.
            Text(" ").font(theme.valueFont)
        }
    }

    private func zoneCell(index: Int) -> some View {
        let shade = Double(index) / Double(ToneZoneParams.zoneCount - 1)
        let mass = (session.stats?.zoneMass.count ?? 0) > index
            ? session.stats!.zoneMass[index] : 0
        let gainValue = gain(index)
        return GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color(white: shade))
                Rectangle().fill(theme.controlAccent.opacity(0.55))
                    .frame(height: geo.size.height * CGFloat(min(mass * Self.massAmplification, 1)))
                // The gain is drawn as an offset from the cell's middle, so a
                // glance reads which zones were lifted and which were pulled.
                Rectangle().fill(theme.textPrimary)
                    .frame(height: 2)
                    .offset(y: -geo.size.height * (0.5 + CGFloat(gainValue) * 0.5) + 1)
            }
            .overlay {
                if session.hoveredZone == index {
                    Rectangle().stroke(theme.controlAccent, lineWidth: 1.5)
                }
            }
        }
        .frame(height: Self.cellHeight)
        .contentShape(Rectangle())
        .gesture(
            // 3pt, not 1: a cell that appears under an already-pressed cursor
            // could otherwise write a gain from a single point of twitch.
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    setGain(index, to: min(max(gain(index)
                        + Double(-value.translation.height) * Self.gainPerPoint, -1), 1))
                }
                .onEnded { _ in session.commitGesture() }
        )
        .onHover { inside in
            hoverDwell?.cancel()
            guard inside else {
                if session.hoveredZone == index { session.hoveredZone = nil }
                return
            }
            // DWELL before hatching the canvas.
            //
            // `.onHover` fires when a view appears UNDER a stationary cursor,
            // not only when the pointer moves onto it — so expanding this card
            // used to hatch the photo instantly and unbidden, which reads as an
            // edit having been applied. Requiring the pointer to rest here
            // first keeps the deliberate hover-a-zone-to-see-it feature while
            // making the card safe to merely open.
            hoverDwell = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Self.hoverDwellMilliseconds))
                guard !Task.isCancelled else { return }
                session.hoveredZone = index
            }
        }
        .onTapGesture(count: 2) {
            setGain(index, to: 0)
            session.commitGesture()
        }
        .accessibilityHidden(true)   // the disclosed sliders are the VoiceOver path
    }

    private func gain(_ index: Int) -> Double {
        let gains = (session.draft.toneZoneParams ?? .neutral).clamped().gains
        return gains[index]
    }

    private func setGain(_ index: Int, to value: Double) {
        session.draft.setToneZone { params in
            var gains = params.clamped().gains
            gains[index] = min(max(value, -1), 1)
            params = ToneZoneParams(gains: gains)
        }
    }
}

//
//  MoodPickerView.swift
//  Muse
//
//  One-surface background picker (toolbar popover): four swatches —
//  White, Dark, Auto (day/night), Custom — with the custom color's
//  hue/saturation/brightness gradient sliders living inline below.
//  Dragging any slider switches straight onto Custom; no second modal.
//  Slider design after kieranb662's SwiftUI-Color-Kit (credited in the
//  README); implemented natively to keep the app dependency-free.
//

import SwiftUI

struct MoodPickerView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MoodSwatch(title: "Light",
                           isSelected: appState.mood == .paper,
                           action: { appState.setMood(.paper) }) {
                    Circle().fill(Mood.paperPalette.background)
                }
                MoodSwatch(title: "Dark",
                           isSelected: appState.mood == .ink,
                           action: { appState.setMood(.ink) }) {
                    Circle().fill(Mood.fallbackPalette.background)
                }
                MoodSwatch(title: "Auto",
                           isSelected: appState.mood == .auto,
                           action: { appState.setMood(.auto) }) {
                    // Diagonal day/night split.
                    Circle().fill(LinearGradient(
                        stops: [
                            .init(color: Mood.paperPalette.background, location: 0.5),
                            .init(color: Mood.fallbackPalette.background, location: 0.5),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                MoodSwatch(title: "Custom",
                           isSelected: appState.mood == .custom,
                           action: { appState.setMood(.custom) }) {
                    ZStack {
                        Circle().fill(customColor)
                        Circle().strokeBorder(
                            AngularGradient(colors: Self.rainbow, center: .center),
                            lineWidth: 3)
                    }
                }
            }

            // Dimmed while a preset is active so the selection reads at a
            // glance — still touchable: the first drag lights them up and
            // switches onto Custom.
            VStack(spacing: 10) {
                GradientSlider(colors: Self.rainbow,
                               value: binding(\.customHue))
                GradientSlider(colors: [
                    Color(hue: appState.customHue, saturation: 0, brightness: sliderBrightness),
                    Color(hue: appState.customHue, saturation: 1, brightness: sliderBrightness),
                ], value: binding(\.customSaturation))
                GradientSlider(colors: [
                    .black,
                    Color(hue: appState.customHue, saturation: appState.customSaturation,
                          brightness: 1),
                ], value: binding(\.customBrightness))
            }
            .opacity(appState.mood == .custom ? 1 : 0.3)
            .saturation(appState.mood == .custom ? 1 : 0.4)
            .animation(.easeOut(duration: 0.2), value: appState.mood)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("TILE BACKGROUND")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 14) {
                    tileGroup("Automatic", options: [.none, .auto])
                    Divider().frame(height: 52)
                    tileGroup("Static", options: [.light, .darkGrey, .black])
                }
                .opacity(appState.imageLayout == .masonry ? 0.4 : 1)
                .disabled(appState.imageLayout == .masonry)

                if appState.imageLayout == .masonry {
                    Text("Masonry always uses Auto. Pick a fixed ratio to choose a backdrop.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    @ViewBuilder
    private func tileGroup(_ caption: String, options: [TileBackground]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                ForEach(options) { option in
                    TileSwatch(option: option,
                               isSelected: appState.effectiveTileBackground == option,
                               moodFill: appState.moodPalette.tileFill,
                               action: { appState.tileBackground = option })
                }
            }
        }
    }

    private static let rainbow: [Color] =
        stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
            Color(hue: $0, saturation: 0.9, brightness: 0.95)
        }

    private var customColor: Color {
        Color(hue: appState.customHue, saturation: appState.customSaturation,
              brightness: appState.customBrightness)
    }

    /// Keep the saturation track visible even when brightness is near black.
    private var sliderBrightness: Double { max(appState.customBrightness, 0.55) }

    /// Writing through a slider selects Custom immediately.
    private func binding(_ keyPath: ReferenceWritableKeyPath<AppState, Double>) -> Binding<Double> {
        Binding(
            get: { appState[keyPath: keyPath] },
            set: { newValue in
                appState[keyPath: keyPath] = newValue
                if appState.mood != .custom { appState.setMood(.custom) }
            })
    }
}

// MARK: - Swatch

private struct MoodSwatch<Fill: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let fill: () -> Fill
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                fill()
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(hovering ? 0.35 : 0.15),
                        lineWidth: isSelected ? 2 : 1))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tile background swatch

private struct TileSwatch: View {
    let option: TileBackground
    let isSelected: Bool
    let moodFill: Color           // live mood tile color, shown for .auto
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                swatchFill
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(hovering ? 0.35 : 0.15),
                        lineWidth: isSelected ? 2 : 1))
                Text(option.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var swatchFill: some View {
        switch option {
        case .none:
            // "No color" glyph: empty circle with a diagonal slash.
            ZStack {
                Circle().fill(.clear)
                Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 5, y: 23))
                    p.addLine(to: CGPoint(x: 23, y: 5))
                }
                .stroke(.primary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 28, height: 28)
            }
        case .auto:
            // Live mood tile color — visibly changes when the mood changes.
            Circle().fill(moodFill)
        default:
            Circle().fill(option.backdropRGB(for: Mood.paperPalette)?.color ?? .clear)
        }
    }
}

// MARK: - Gradient slider (Color-Kit style)

private struct GradientSlider: View {
    let colors: [Color]
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inset: CGFloat = 12
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: colors,
                                         startPoint: .leading, endPoint: .trailing))
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: CGFloat(value) * (width - 2 * inset) + inset - 10)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let raw = (g.location.x - inset) / (width - 2 * inset)
                        value = min(max(Double(raw), 0), 1)
                    })
        }
        .frame(height: 24)
    }
}

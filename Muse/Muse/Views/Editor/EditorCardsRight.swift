//
//  EditorCardsRight.swift
//  Muse
//
//  The right column's card bodies — STYLES, LIGHT, COLOR, COLOR MIX, SPLIT
//  TONE and EFFECTS, plus the parameter bindings they write through and the
//  shared Auto/Reset heading accessories. Moved verbatim out of
//  EditorView.swift; see EditorCardsLeft.swift for why.
//
//  TONE ZONES is not here — it was already its own view (ToneZoneStrip).
//

import SwiftUI

extension EditorView {
    /// The preset and/or LUT currently on the photo, for the collapsed STYLES
    /// heading — otherwise a closed card looks identical whether you're on
    /// Original or three looks deep.
    var stylesSummary: String? {
        // Only while the card is CLOSED — that's the only time it's drawn, and
        // computing it otherwise costs a stack comparison per preset per frame.
        guard !expanded.contains(Section.looks) else { return nil }
        let preset = presetStore.presets.first { row in
            guard let stack = presetStore.stacks[row.id] else { return false }
            return EditTransfer.isApplied(stack, onto: session.draft)
        }
        let lut = session.draft.lutParams.flatMap { applied -> String? in
            guard !applied.isNeutral else { return nil }
            return lutStore.luts.first { $0.id == applied.lutHash }?.name ?? applied.name
        }
        let names = [preset?.name, lut].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    /// Auto beside Reset, in the card's heading. Auto is scoped exactly like
    /// the Reset it sits next to (see `AutoToneApply`): the button in LIGHT
    /// never moves a COLOR slider, because a card's controls promising one
    /// group and touching another is the thing per-card Reset exists to avoid.
    func autoAndReset(autoHelp: String, auto: @escaping () -> Void,
                              resetHelp: String, reset: @escaping () -> Void) -> AnyView {
        AnyView(
            HStack(spacing: 4) {
                EditorSmallButton(label: String(localized: "Auto"),
                                  systemName: "wand.and.stars",
                                  action: auto)
                    .environment(\.theme, panelTheme)
                    .help(Text(autoHelp))
                EditorSmallButton(label: String(localized: "Reset"),
                                  systemName: "arrow.counterclockwise",
                                  action: reset)
                    .environment(\.theme, panelTheme)
                    .help(Text(resetHelp))
            }
        )
    }

    /// Vignette and grain. Vignette shipped with a full model and renderer in
    /// Spec 04 and NOTHING that could write it — the only reference in the app
    /// was a reset. This card is that missing half.
    /// Two named groups of three, not six loose sliders. Without the headings
    /// the card advertised six independent effects when it has two, and
    /// "Midpoint" and "Feather" gave no clue which one they belonged to.
    var effectsSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            effectsGroupLabel(String(localized: "Vignette"))
            EditSlider(label: String(localized: "Amount"),
                       value: vignetteBinding(\.amount), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Midpoint"),
                       value: vignetteBinding(\.midpoint), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Feather"),
                       value: vignetteBinding(\.feather), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)

            Divider().padding(.vertical, 2)

            effectsGroupLabel(String(localized: "Grain"))
            EditSlider(label: String(localized: "Amount"),
                       value: grainBinding(\.amount), range: 0...1, neutral: 0,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Size"),
                       value: grainBinding(\.size), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Roughness"),
                       value: grainBinding(\.roughness), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
        }
    }

    /// The group heading inside a card — same treatment Split Tone already uses
    /// for Shadows/Highlights, so the two cards read the same way.
    func effectsGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(panelTheme.labelFont.weight(.semibold))
            .foregroundStyle(panelTheme.textSecondary)
    }

    func grainBinding(_ key: WritableKeyPath<GrainParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.grainParams?[keyPath: key]
                        ?? GrainParams.neutral[keyPath: key] },
                set: { v in session.draft.setGrain { $0[keyPath: key] = v } })
    }

    // MARK: - Colour mix (HSL) + split toning

    /// Which of the three HSL channels the eight sliders are editing. Lives in
    /// the card HEADING, not the body — the same reason the Styles card's
    /// Grid/List pair does: inside the card it pushed every row down.
    enum HSLTab: String, CaseIterable { case hue, saturation, luminance }

    /// Band order is fixed and matches the kernel's 45° centres starting at red.
    static let hslBandNames = [
        String(localized: "Red"), String(localized: "Orange"),
        String(localized: "Yellow"), String(localized: "Green"),
        String(localized: "Aqua"), String(localized: "Blue"),
        String(localized: "Purple"), String(localized: "Magenta"),
    ]

    var hslSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            hslTabs
            ForEach(Array(Self.hslBandNames.enumerated()), id: \.offset) { i, name in
                EditSlider(label: name, value: hslBinding(i), onCommit: session.commitGesture)
            }
        }
    }

    func hslBinding(_ band: Int) -> Binding<Double> {
        Binding(get: {
            let p = session.draft.hslParams ?? .neutral
            let channel: [Double] = switch hslTab {
            case .hue: p.hue
            case .saturation: p.saturation
            case .luminance: p.luminance
            }
            return band < channel.count ? channel[band] : 0
        }, set: { v in
            session.draft.setHSL { p in
                switch hslTab {
                case .hue: if band < p.hue.count { p.hue[band] = v }
                case .saturation: if band < p.saturation.count { p.saturation[band] = v }
                case .luminance: if band < p.luminance.count { p.luminance[band] = v }
                }
            }
        })
    }

    /// Three TEXT tabs at the top of the card body, not icons in the heading.
    /// The icons were unreadable — a palette, a drop and a sun say nothing
    /// about hue, saturation and luminance, and a tooltip you have to hover to
    /// find is not a label.
    var hslTabs: some View {
        HStack(spacing: 2) {
            hslTabButton(String(localized: "Hue"), .hue)
            hslTabButton(String(localized: "Saturation"), .saturation)
            hslTabButton(String(localized: "Luminance"), .luminance)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(panelTheme.panelRaised))
    }

    func hslTabButton(_ label: String, _ tab: HSLTab) -> some View {
        let isOn = hslTab == tab
        return Button { hslTab = tab } label: {
            Text(label)
                .font(.system(size: 10, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? panelTheme.selectionInk : panelTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? panelTheme.selectionFill : .clear))
                // Without this the tab is only clickable ON the glyphs, which
                // makes a full-width control feel broken.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    var splitToneSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            Text("Shadows")
                .font(panelTheme.labelFont).foregroundStyle(panelTheme.textSecondary)
            EditSlider(label: String(localized: "Hue"), value: splitBinding(\.shadowHue),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: splitBinding(\.shadowSaturation),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)

            Divider()

            Text("Highlights")
                .font(panelTheme.labelFont).foregroundStyle(panelTheme.textSecondary)
            EditSlider(label: String(localized: "Hue"), value: splitBinding(\.highlightHue),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: splitBinding(\.highlightSaturation),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)

            Divider()

            EditSlider(label: String(localized: "Balance"), value: splitBinding(\.balance),
                       onCommit: session.commitGesture)
        }
    }

    func splitBinding(_ key: WritableKeyPath<SplitToneParams, Double>)
        -> Binding<Double> {
        Binding(get: { session.draft.splitToneParams?[keyPath: key]
                        ?? SplitToneParams.neutral[keyPath: key] },
                set: { v in session.draft.setSplitTone { $0[keyPath: key] = v } })
    }

    /// `neutral:` matters on midpoint/feather: double-clicking their labels has
    /// to return to 0.5, not to 0, or the reset gesture lands somewhere the
    /// user never chose.
    func vignetteBinding(_ key: WritableKeyPath<VignetteParams, Double>)
        -> Binding<Double> {
        Binding(get: { session.draft.vignetteParams?[keyPath: key]
                        ?? VignetteParams.neutral[keyPath: key] },
                set: { v in session.draft.setVignette { $0[keyPath: key] = v } })
    }

    /// A card's own Reset — undoes that group and nothing else, so fixing the
    /// colour doesn't cost you the tone work.
    func resetButton(_ help: String, action: @escaping () -> Void) -> AnyView {
        AnyView(
            EditorSmallButton(label: String(localized: "Reset"),
                              systemName: "arrow.counterclockwise",
                              action: action)
                .environment(\.theme, panelTheme)
                .help(Text(help))
        )
    }

    var lightTab: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            EditSlider(label: String(localized: "Exposure"),
                       value: toneBinding(\.exposureEV),
                       range: ToneParams.exposureRange, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Contrast"),
                       value: toneBinding(\.contrast), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Highlights"),
                       value: toneBinding(\.highlights), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Shadows"),
                       value: toneBinding(\.shadows), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Whites"),
                       value: toneBinding(\.whites), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Blacks"),
                       value: toneBinding(\.blacks), onCommit: session.commitGesture)

            Divider()

            EditSlider(label: String(localized: "Clarity"),
                       value: presenceBinding(\.clarity), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Texture"),
                       value: presenceBinding(\.texture), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Sharpen"),
                       value: presenceBinding(\.sharpen), range: 0...1,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Noise Reduction"),
                       value: presenceBinding(\.noiseReduction), range: 0...1,
                       onCommit: session.commitGesture)

            Divider()

            Text("Curve").font(panelTheme.labelFont).foregroundStyle(panelTheme.textSecondary)
            CurveEditorView(points: curveBinding,
                            // The seam Spec 04 left: the curve's backdrop is
                            // the luma channel of the SAME shared statistics
                            // pass the Scopes tab draws.
                            histogram: session.stats?.curveHistogram,
                            onCommit: session.commitGesture)
        }
    }

    var colorTab: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            HStack(spacing: panelTheme.spacingS) {
                EditSlider(label: String(localized: "Temperature"),
                           value: colorBinding(\.temperature), onCommit: session.commitGesture)
                WBEyedropperButton(session: session)
            }
            EditSlider(label: String(localized: "Tint"),
                       value: colorBinding(\.tint), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Vibrance"),
                       value: colorBinding(\.vibrance), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: colorBinding(\.saturation), onCommit: session.commitGesture)

            if session.isRaw {
                Divider()
                EditToggleRow(label: String(localized: "Auto Lens Correction"),
                              isOn: Binding(
                                get: { session.draft.rawParams?.lensCorrection ?? true },
                                set: { on in session.draft.setRaw { $0.lensCorrection = on } }),
                              onCommit: session.commitGesture)
            }
        }
    }

    var looksTab: some View {
        LooksBrowserView(session: session, listMode: $stylesListMode)
    }

    /// Grid vs list for the Styles browser, as a pair of buttons in the card's
    /// HEADING — inside the card they pushed every look down by a row.
    var stylesModeButtons: AnyView {
        AnyView(
            HStack(spacing: 4) {
                stylesModeButton(systemName: "square.grid.2x2", isOn: !stylesListMode,
                                 label: String(localized: "Grid")) { stylesListMode = false }
                stylesModeButton(systemName: "list.bullet", isOn: stylesListMode,
                                 label: String(localized: "List")) { stylesListMode = true }
            }
        )
    }

    func stylesModeButton(systemName: String, isOn: Bool, label: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? panelTheme.selectionInk : panelTheme.textPrimary)
                .frame(width: 22, height: 18)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? panelTheme.selectionFill : panelTheme.panelRaised))
        }
        .buttonStyle(.plain)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Bindings

    /// Each binding reads through the typed accessor and writes through the
    /// find-or-insert mutator, so touching a slider creates its adjustment
    /// case and nothing else has to know the stack's shape.
    func toneBinding(_ keyPath: WritableKeyPath<ToneParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.toneParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setTone { $0[keyPath: keyPath] = v } })
    }

    func colorBinding(_ keyPath: WritableKeyPath<ColorParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.colorParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setColor { $0[keyPath: keyPath] = v } })
    }

    func presenceBinding(_ keyPath: WritableKeyPath<PresenceParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.presenceParams?[keyPath: keyPath] ?? 0 },
                set: { v in session.draft.setPresence { $0[keyPath: keyPath] = v } })
    }

    var curveBinding: Binding<[CurveParams.Point]> {
        Binding(get: { session.draft.curveParams?.rgb ?? [] },
                set: { pts in session.draft.setCurve { $0.rgb = pts } })
    }
}

//
//  EditorCardsLeft.swift
//  Muse
//
//  The left column's card bodies — TOOLS (with the backdrop picker) and
//  INSIGHTS. Moved verbatim out of EditorView.swift in the workspace pass:
//  that file was 1,682 lines and the workspace rewrites every card
//  declaration in it, so the bodies came out first rather than a thirteenth
//  concern going in. Behaviour unchanged; `private` became internal only
//  because an extension in another file cannot see the primary declaration's
//  private members. Same move, same reason, as the 2026-06-20
//  SidebarReorderSupport extraction.
//
//  HISTOGRAM and SNAPSHOTS are not here — they were already their own views
//  (ScopesPanel, EditVersionsList).
//

import SwiftUI
import AppKit

extension EditorView {
    var hasInsights: Bool {
        !feedbackNotes.isEmpty
            || session.draft.origin == .lightroom
            || session.draft.rawParams?.decoderVersion != nil
    }

    /// Compare, zebras and reset — the TOOLS card in the left panel.
    ///
    /// This was a capsule of eight unlabelled glyphs floating under the canvas.
    /// It was too small to hit comfortably and gave no clue what any of it did,
    /// so every control now states its name and lives with the rest of the
    /// controls instead of on top of the photo.
    var toolsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            EditorToolRow(systemName: "arrow.uturn.backward",
                          label: String(localized: "Undo"),
                          isEnabled: session.canUndo, action: { session.undo() })
            EditorToolRow(systemName: "arrow.uturn.forward",
                          label: String(localized: "Redo"),
                          isEnabled: session.canRedo, action: { session.redo() })

            Divider().padding(.vertical, 4)

            // One Auto for "just make this look right". The per-card buttons
            // stay for when you want only the tone or only the colour — but
            // the common case is not two separate decisions, and making the
            // user find both was the wrong default.
            EditorToolRow(systemName: "wand.and.stars",
                          label: String(localized: "Auto Enhance"),
                          action: {
                Task {
                    guard let r = await session.autoToneResult() else { return }
                    AutoToneApply.all(r, onto: &session.draft)
                    session.commitGesture()
                }
            })

            Divider().padding(.vertical, 4)

            // Press-and-hold, not a toggle: peek is a momentary comparison, and
            // a toggle leaves the user unsure which one they're looking at.
            // MOMENTARY: down shows the original, up puts it back. It used to
            // be a Button whose action toggled AND a press gesture that set —
            // so a click ended with the peek stuck on and no way to click it
            // off. A peek you can leave on is just a confusing second mode.
            EditorToolRow(systemName: "eye",
                          label: String(localized: "Hold to See Original"),
                          isActive: session.beforePeek,
                          onPressChanged: { pressing in session.beforePeek = pressing })

            EditorToolRow(systemName: "rectangle.split.2x1",
                          label: String(localized: "Side by Side"),
                          isActive: session.compareMode == .sideBySide,
                          action: {
                session.compareMode = session.compareMode == .sideBySide ? .off : .sideBySide
            })

            EditorToolRow(systemName: "rectangle.lefthalf.inset.filled",
                          label: String(localized: "Split Compare"),
                          isActive: isWiping,
                          action: {
                if case .wipe = session.compareMode {
                    session.compareMode = .off
                } else {
                    session.compareMode = .wipe(0.5)
                }
            })

            if case .wipe(let fraction) = session.compareMode {
                Slider(value: Binding(get: { fraction },
                                      set: { session.compareMode = .wipe($0) }), in: 0...1)
                    .tint(panelTheme.controlAccent)
                    .padding(.horizontal, 8)
                    .accessibilityLabel(Text("Split position"))
            }

            Divider().padding(.vertical, 4)

            // Zebras: session-scoped, J to toggle. Right-click opens the
            // thresholds, which DO persist — the stripes are a check, the
            // thresholds are a preference.
            EditorToolRow(systemName: "circle.lefthalf.striped.horizontal",
                          label: String(localized: "Clipping Zebras (J)"),
                          isActive: session.zebrasOn,
                          action: { session.zebrasOn.toggle() })
                .contextMenu {
                    Button { showZebraThresholds = true } label: { Text("Zebra Thresholds…") }
                }
                .popover(isPresented: $showZebraThresholds) { ZebraThresholdsPopover() }

            Divider().padding(.vertical, 4)

            EditorToolRow(systemName: "arrow.counterclockwise",
                          label: String(localized: "Reset All Adjustments"),
                          action: { session.resetAll() })

            Divider().padding(.vertical, 4)

            backdropPicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The editor backdrop, as five visible swatches.
    ///
    /// It was reachable only by right-clicking the backdrop itself, which is a
    /// gesture nobody discovers — the setting looked like it didn't exist. The
    /// context menu still works; this is the way you can SEE.
    var backdropPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Background")
                .font(panelTheme.labelFont)
                .foregroundStyle(panelTheme.textSecondary)
                .padding(.horizontal, 8)
            HStack(spacing: 6) {
                ForEach(EditorBackdropLevel.allCases) { level in
                    backdropSwatch(level)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 2)
    }

    func backdropSwatch(_ level: EditorBackdropLevel) -> some View {
        let selected = EditorBackdropLevel.resolve(backdropRaw) == level
        return Button {
            backdropRaw = level.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(white: level.brightness))
                .frame(width: 22, height: 22)
                // A hairline in the panel's own ink, so a white swatch on a
                // white backdrop still has an edge.
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(panelTheme.textPrimary.opacity(0.35), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? panelTheme.controlAccent : .clear, lineWidth: 2)
                    .padding(-3))
        }
        .buttonStyle(.plain)
        .help(Text(level.label))
        .accessibilityLabel(Text(level.label))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    var isWiping: Bool {
        if case .wipe = session.compareMode { return true }
        return false
    }

    /// What this card says about the photo. The INFO card that used to sit
    /// beside it was the filename (already above the panel), a count of
    /// adjustment groups (the sliders say that), and these same notes — so it
    /// went, and the two lines that were only ever there moved here.
    var insightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Provenance: these values came from someone else's software and
            // are approximations, not a transfer.
            if session.draft.origin == .lightroom {
                Label("Approximated from Lightroom", systemImage: "info.circle")
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(feedbackNotes.enumerated()), id: \.offset) { _, note in
                Text(note.displayText)
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The RAW decoder version is PINNED at first edit so a later OS
            // can't silently re-render the same stack differently. When the
            // pinned one is gone we say what we substituted rather than hide it.
            if let decoderVersion = session.draft.rawParams?.decoderVersion {
                let live = RawSource.currentDecoderVersion(for: session.url)
                Text(live == nil || live == decoderVersion
                     ? String(localized: "Process: RAW decoder \(decoderVersion)")
                     : String(localized: "Process: RAW decoder \(decoderVersion) (this Mac renders with \(live ?? ""))"))
                    .font(panelTheme.labelFont)
                    .foregroundStyle(panelTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

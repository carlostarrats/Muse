//
//  EditSlider.swift
//  Muse
//
//  The editor's one scalar control. Every adjustment is one of these, so the
//  behaviours live here rather than being re-implemented per panel:
//
//  - double-click the label OR the readout to return to neutral (both, because
//    people reach for whichever is closer)
//  - history pushes on gesture END, never per tick
//  - the readout is monospaced, so digits don't jitter under a drag
//

import SwiftUI

struct EditSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var neutral: Double = 0
    /// Called when the gesture ENDS — the single history-push trigger.
    let onCommit: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(theme.labelFont)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(readout)
                    .font(theme.valueFont)
                    .foregroundStyle(theme.textSecondary)
            }
            // The reset gesture is on the ROW, not on each text — a
            // double-click that lands in the gap between them should still
            // work.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value = neutral
                onCommit()
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .tint(theme.controlAccent)
            .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(readout))
        .accessibilityAdjustableAction { direction in
            // VoiceOver can't reproduce a drag, so the value needs a keyboard
            // path — and it must push history like a gesture end does.
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            default: return
            }
            onCommit()
        }
        .accessibilityAction(named: Text("Reset")) {
            value = neutral
            onCommit()
        }
    }

    private var readout: String {
        String(format: "%.2f", value)
    }
}

/// A labelled on/off row in the same visual family as `EditSlider`, for the
/// handful of boolean adjustments (RAW lens correction).
struct EditToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    let onCommit: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Toggle(isOn: Binding(get: { isOn },
                             set: { isOn = $0; onCommit() })) {
            Text(label)
                .font(theme.labelFont)
                .foregroundStyle(theme.textPrimary)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(theme.controlAccent)
    }
}

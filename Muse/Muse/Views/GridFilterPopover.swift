//
//  GridFilterPopover.swift
//  Muse
//
//  The funnel-button popover. A single KIND section: an over-arching "Images"
//  checkbox (native tri-state — check / dash / empty) over its format checkboxes
//  (JPEG/PNG/…/Other), then the top-level non-image kinds, then Clear All. The
//  formats are always visible (no expand/collapse — the dropdown was what broke
//  the popover's resize, and with a fixed size the native AppKit checkbox works).
//  Every row is a native checkbox, so they all match. Writes AppState.gridFilter.
//  (feat/next-48)
//

import SwiftUI
import AppKit

struct GridFilterPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("KIND")

                // Over-arching Images checkbox (tri-state) + its format rows.
                TriStateCheckbox(title: String(localized: "Images"),
                                 state: appState.gridFilter.imageParentState) {
                    appState.gridFilter = appState.gridFilter.togglingImageGroup()
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(KindFacet.imageLeaves) { facet in
                        Toggle(facet.displayName, isOn: leafBinding(facet))
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(facet == .imageOther
                                                ? "Other image formats"
                                                : facet.displayName)
                    }
                }
                .padding(.leading, 16)

                ForEach(KindFacet.topLevelKinds) { facet in
                    Toggle(facet.displayName, isOn: leafBinding(facet))
                        .toggleStyle(.checkbox)
                }
            }

            Divider()

            Button("Clear All") { appState.gridFilter = .none }
                .disabled(!appState.gridFilter.isActive)
        }
        .padding(16)
        .frame(width: 180)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            // Navigable via VoiceOver's heading rotor (matches the next-34
            // sidebar SectionHeader convention).
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Bindings

    /// A leaf reads as checked when the set is empty (the "all = off" sentinel)
    /// or explicitly contains it; toggling routes through the pure model helper.
    private func leafBinding(_ facet: KindFacet) -> Binding<Bool> {
        Binding(
            get: { appState.gridFilter.kinds.isEmpty
                   || appState.gridFilter.kinds.contains(facet) },
            set: { _ in appState.gridFilter = appState.gridFilter.toggling(facet) })
    }
}

/// A native (AppKit) checkbox that can show the mixed/dash state — SwiftUI's
/// `Toggle(.checkbox)` is on/off only. Visual state is driven entirely by the
/// model (`ParentCheckState`); a click just fires `onToggle`, and the next
/// render re-syncs `state`, so the button never drives its own state. Safe here
/// because the popover is a fixed size (no dynamic resize to disrupt).
private struct TriStateCheckbox: NSViewRepresentable {
    let title: String
    let state: ParentCheckState
    let onToggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title,
                              target: context.coordinator,
                              action: #selector(Coordinator.fire))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        context.coordinator.onToggle = onToggle
        switch state {
        case .on:    button.state = .on
        case .off:   button.state = .off
        case .mixed: button.state = .mixed
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    final class Coordinator: NSObject {
        var onToggle: () -> Void
        init(onToggle: @escaping () -> Void) { self.onToggle = onToggle }
        @objc func fire() { onToggle() }
    }
}

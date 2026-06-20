//
//  GridFilterPopover.swift
//  Muse
//
//  The funnel-button popover: three stacked sections (Kind checkboxes, Date
//  radio, Size radio) + Clear All, writing AppState.gridFilter. Styled like the
//  mood picker (270 wide, 16pt padding/spacing, dividers between sections).
//

import SwiftUI

struct GridFilterPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // KIND (multi-select checkboxes)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("KIND")
                ForEach(KindFacet.allCases) { facet in
                    Toggle(facet.displayName, isOn: kindBinding(facet))
                        .toggleStyle(.checkbox)
                }
            }

            Divider()

            // DATE (single-select radio, modified date)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DATE")
                Picker("", selection: dateBinding) {
                    ForEach(DateFacet.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            // SIZE (single-select radio)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("SIZE")
                Picker("", selection: sizeBinding) {
                    ForEach(SizeFacet.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            Button("Clear All") { appState.gridFilter = .none }
                .disabled(!appState.gridFilter.isActive)
        }
        .padding(16)
        .frame(width: 270)
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

    /// A kind reads as checked when the set is empty (the "all = off" sentinel)
    /// or explicitly contains it.
    private func kindBinding(_ facet: KindFacet) -> Binding<Bool> {
        Binding(
            get: { appState.gridFilter.kinds.isEmpty
                   || appState.gridFilter.kinds.contains(facet) },
            set: { _ in toggleKind(facet) })
    }

    private func toggleKind(_ facet: KindFacet) {
        var filter = appState.gridFilter
        // Expand the "empty == all" sentinel to a concrete full set before edit.
        var set = filter.kinds.isEmpty ? Set(KindFacet.allCases) : filter.kinds
        if set.contains(facet) { set.remove(facet) } else { set.insert(facet) }
        // Collapse "all selected" (or "none selected") back to the empty/off
        // sentinel: per the model, empty == no kind constraint == all shown.
        filter.kinds = (set == Set(KindFacet.allCases) || set.isEmpty) ? [] : set
        appState.gridFilter = filter
    }

    private var dateBinding: Binding<DateFacet> {
        Binding(get: { appState.gridFilter.date },
                set: { appState.gridFilter.date = $0 })
    }

    private var sizeBinding: Binding<SizeFacet> {
        Binding(get: { appState.gridFilter.size },
                set: { appState.gridFilter.size = $0 })
    }
}

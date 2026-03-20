//
//  TagFilter.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/20/26.
//

import SwiftUI

/// Toolbar button that opens a popover with all available tags for multi-select filtering.
struct TagFilter: View {
    @EnvironmentObject var appState: AppState
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 12))
                Text(filterLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(!appState.filterTags.isEmpty ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            TagFilterPopover()
                .environmentObject(appState)
        }
    }

    private var filterLabel: String {
        if appState.filterTags.isEmpty {
            return "Tags"
        } else if appState.filterTags.count == 1 {
            return appState.filterTags.first!
        } else {
            return "\(appState.filterTags.count) tags"
        }
    }
}

// MARK: - Tag Filter Popover

struct TagFilterPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    private var filteredLabels: [String] {
        if searchText.isEmpty {
            return appState.allTagLabels
        }
        let lower = searchText.lowercased()
        return appState.allTagLabels.filter { $0.lowercased().contains(lower) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Filter by Tags")
                    .font(.headline)
                Spacer()
                if !appState.filterTags.isEmpty {
                    Button("Clear All") {
                        appState.filterTags.removeAll()
                        Task { await appState.applyTagFilter() }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Search tags…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            Divider()

            // Tag list
            if filteredLabels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tag.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(appState.allTagLabels.isEmpty ? "No tags yet" : "No matching tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredLabels, id: \.self) { label in
                            let isSelected = appState.filterTags.contains(label)
                            Button {
                                if isSelected {
                                    appState.filterTags.remove(label)
                                } else {
                                    appState.filterTags.insert(label)
                                }
                                Task { await appState.applyTagFilter() }
                            } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                        .font(.system(size: 14))
                                    Text(label)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 250)
            }
        }
        .frame(width: 240)
    }
}

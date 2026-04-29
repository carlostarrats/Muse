//
//  DetailPanelView.swift
//  Muse
//
//  Right-side panel: file metadata + tags (manual + vision) + Analyze
//  button. Visible when a file is selected and the panel is opened.
//

import SwiftUI
import AppKit

struct DetailPanelView: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    @State private var tags: [TagRow] = []
    @State private var newTag: String = ""
    @State private var isAnalyzing: Bool = false

    private static let panelWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(file.basename)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    appState.detailPanelVisible = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help("Hide details")
            }

            metadataSection

            Divider()

            tagsSection

            Divider()

            analyzeSection

            Spacer()
        }
        .padding(16)
        .frame(width: Self.panelWidth)
        .background(.regularMaterial)
        .task(id: file.url) {
            tags = await TagStore.shared.tags(for: file.url)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "Kind", value: file.kind.rawValue.capitalized)
            if let size = file.sizeBytes {
                row(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let modified = file.modifiedAt {
                row(label: "Modified", value: dateString(modified))
            }
            row(label: "Path", value: file.url.path)
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.subheadline.weight(.medium))
            FlowingTags(tags: tags) { tag in
                Task {
                    tags = await TagStore.shared.removeTag(tag, for: file.url)
                }
            }
            HStack(spacing: 6) {
                TextField("Add tag…", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitTag() }
                Button("Add") { submitTag() }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    @ViewBuilder
    private var analyzeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI")
                .font(.subheadline.weight(.medium))
            if file.kind == .image || file.kind == .raw || file.kind == .psd {
                Button {
                    Task {
                        isAnalyzing = true
                        await appState.analyzeSelected()
                        tags = await TagStore.shared.tags(for: file.url)
                        isAnalyzing = false
                    }
                } label: {
                    HStack {
                        if isAnalyzing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Analyze (auto-tag, OCR, dominant color)")
                    }
                }
                .disabled(isAnalyzing)
            } else {
                Text("Vision pipeline only handles images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value).font(.caption).lineLimit(3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func submitTag() {
        let label = newTag
        newTag = ""
        Task {
            tags = await TagStore.shared.addManualTag(label: label, for: file.url)
        }
    }
}

private struct FlowingTags: View {
    let tags: [TagRow]
    let onRemove: (TagRow) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("No tags yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            // Simple wrap via VStack of HStacks; rough flow layout to avoid heavy custom layout
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    TagPill(tag: tag, onRemove: { onRemove(tag) })
                }
            }
        }
    }
}

private struct TagPill: View {
    let tag: TagRow
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tag.label)
                .font(.caption)
            if tag.source == "vision" {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tag.source == "manual"
                           ? Color.accentColor.opacity(0.18)
                           : Color.secondary.opacity(0.12))
        )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

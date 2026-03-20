//
//  TagPill.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

/// A small rounded pill that displays a tag label.
/// - If the tag's `source` is `"ai"`, a sparkle icon is shown before the label.
/// - If `onDelete` is provided, a delete (×) button appears at the trailing edge.
struct TagPill: View {

    let tag: Tag
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if tag.source == "ai" {
                Image(systemName: "sparkles")
                    .font(.caption2)
            }

            Text(tag.label)
                .font(.caption)
                .lineLimit(1)

            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.08))
        )
        .foregroundStyle(.primary)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        let dummyID = UUID()

        TagPill(tag: Tag(imageID: dummyID, label: "Architecture", source: "manual"))
        TagPill(tag: Tag(imageID: dummyID, label: "AI Generated", source: "ai"))
        TagPill(tag: Tag(imageID: dummyID, label: "Deletable", source: "manual")) {
            print("Delete tapped")
        }
        TagPill(tag: Tag(imageID: dummyID, label: "AI + Delete", source: "ai")) {
            print("Delete tapped")
        }
    }
    .padding()
}
#endif

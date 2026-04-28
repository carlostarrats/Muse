//
//  GridView.swift
//  Muse
//
//  Phase 0.5 grid driven by FileNode. Lazy-loads thumbnails via
//  ThumbnailCache. Shows a kind-specific icon for non-image kinds when
//  the thumbnail is missing or still generating.
//

import SwiftUI
import AppKit

struct GridView: View {
    @EnvironmentObject var appState: AppState

    private let tileSize: CGFloat = 160
    private let spacing: CGFloat = 16

    var body: some View {
        ScrollView {
            if appState.currentFiles.isEmpty {
                emptyState
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: tileSize), spacing: spacing)],
                    spacing: spacing
                ) {
                    ForEach(appState.currentFiles) { file in
                        TileView(file: file, size: tileSize)
                            .onTapGesture(count: 2) {
                                NSWorkspace.shared.open(file.url)
                            }
                            .onTapGesture {
                                appState.selectedFile = file
                            }
                            .background(
                                appState.selectedFile?.id == file.id
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                            )
                            .cornerRadius(8)
                            .contextMenu {
                                OpenWithMenu(url: file.url)
                            }
                    }
                }
                .padding(20)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(appState.selectedFolder == nil ? "Select a folder" : "Empty folder")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct TileView: View {
    let file: FileNode
    let size: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(width: size, height: size)
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size - 16, height: size - 16)
                } else {
                    Image(systemName: iconName(for: file.kind))
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            Text(file.basename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size)
        }
        .frame(width: size + 12)
        .padding(.vertical, 4)
        .task(id: file.url) {
            thumbnail = await ThumbnailCache.shared.thumbnail(
                for: file.url,
                size: CGSize(width: size, height: size)
            )
        }
    }

    private func iconName(for kind: AssetKind) -> String {
        switch kind {
        case .image, .raw, .psd, .svg: return "photo"
        case .pdf: return "doc.richtext"
        case .text, .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .office: return "doc.text"
        case .video: return "film"
        case .audio: return "waveform"
        case .model3d: return "cube"
        case .font: return "textformat"
        case .archive: return "archivebox"
        case .folder: return "folder"
        case .unknown: return "doc"
        }
    }
}

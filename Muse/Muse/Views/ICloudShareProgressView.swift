//
//  ICloudShareProgressView.swift
//  Muse
//
//  Modal shown while a collection copies + uploads to iCloud. On completion it
//  hands the folder to the native share sheet (Copy Link / AirDrop / Mail).
//

import SwiftUI
import AppKit

struct ICloudShareProgressView: View {
    @ObservedObject var service: ICloudShareService
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch service.phase {
            case .idle, .copying:
                ProgressView().controlSize(.large)
                Text("Copying images…")
            case .uploading(let t):
                ProgressView(value: t.fraction)
                    .frame(width: 220)
                Text("Uploading to iCloud… \(t.uploaded) of \(t.total)")
            case .ready:
                ProgressView().controlSize(.large)
                Text("Opening share…")
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center)
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }

            if case .uploading = service.phase {
                Button("Cancel") { service.cancel(); onClose() }
            }
        }
        .frame(width: 320)
        .padding(28)
        .onChange(of: phaseKey) { presentIfReady() }
        .onAppear { presentIfReady() }
    }

    // A cheap value that changes when .ready arrives, so onChange fires for it.
    private var phaseKey: String {
        if case .ready(let url) = service.phase { return "ready:\(url.path)" }
        return "\(service.phase)"
    }

    private func presentIfReady() {
        guard case .ready(let folder) = service.phase else { return }
        guard let contentView = NSApp.keyWindow?.contentView else { onClose(); return }
        let picker = NSSharingServicePicker(items: [folder])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        onClose()
    }
}

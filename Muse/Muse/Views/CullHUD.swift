//
//  CullHUD.swift
//  Muse
//
//  Floating bottom-center capsule shown while a cull session is active. It's
//  the only exit: Finish opens the resolve card, Cancel discards. Escape is
//  deliberately NOT wired here — see CullStore's header.
//

import SwiftUI

struct CullHUD: View {
    @ObservedObject var store: CullStore
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if store.active {
            let summary = store.summary
            HStack(spacing: 12) {
                Text("Culling — \(summary.keepPaths.count) kept · \(summary.rejectPaths.count) rejected")
                    .font(.callout)
                Text("K keep · X reject · U clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModalButton(title: String(localized: "Cancel"), kind: .normal, action: onCancel)
                ModalButton(title: String(localized: "Finish"), kind: .prominent, action: onFinish)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Culling session"))
        }
    }
}

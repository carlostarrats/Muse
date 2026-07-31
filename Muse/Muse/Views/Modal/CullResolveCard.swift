//
//  CullResolveCard.swift
//  Muse
//
//  Presented via `.museModal` at the shell on "Finish". Cancel here returns
//  to the LIVE session with nothing applied; the HUD's own Cancel (a separate
//  confirm) is what discards the marks entirely.
//

import SwiftUI

struct CullResolveCard: View {
    let summary: CullSummary
    /// (chosen rating or nil, moveRejectedToTrash)
    let onApply: (Int?, Bool) -> Void
    let onCancel: () -> Void

    @State private var chosenRating: Int?
    @State private var moveToTrash = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(summary.keepPaths.count) kept · \(summary.rejectPaths.count) rejected")
                .font(.headline)

            if !summary.keepPaths.isEmpty {
                Picker(String(localized: "Rate kept photos"), selection: $chosenRating) {
                    Text("None").tag(Int?.none)
                    ForEach(1...StarRating.maxStars, id: \.self) { n in
                        Text(String(repeating: "★", count: n)).tag(Int?.some(n))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if !summary.rejectPaths.isEmpty {
                Toggle(isOn: $moveToTrash) {
                    Text("Move \(summary.rejectPaths.count) rejected photos to the Trash")
                }
            }

            HStack {
                ModalButton(title: String(localized: "Cancel"), kind: .normal,
                            isCancel: true, action: onCancel)
                Spacer()
                ModalButton(title: String(localized: "Apply"),
                            kind: moveToTrash && !summary.rejectPaths.isEmpty ? .destructive : .prominent,
                            isDefault: true) {
                    onApply(chosenRating, moveToTrash)
                }
            }
        }
        .padding(20)
    }
}

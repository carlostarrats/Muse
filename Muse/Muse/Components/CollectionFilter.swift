//
//  CollectionFilter.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/20/26.
//

import SwiftUI

/// Toolbar dropdown to filter images by collection.
struct CollectionFilter: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Menu {
            Button {
                appState.filterCollectionID = nil
            } label: {
                HStack {
                    Text("All Collections")
                    if appState.filterCollectionID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(appState.collections) { collection in
                Button {
                    appState.filterCollectionID = collection.id
                } label: {
                    HStack {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: collection.colorHex)))
                            .frame(width: 8, height: 8)
                        Text(collection.name)
                        if appState.filterCollectionID == collection.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                if let id = appState.filterCollectionID,
                   let name = appState.collections.first(where: { $0.id == id })?.name {
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                } else {
                    Text("Collections")
                        .font(.system(size: 11))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(appState.filterCollectionID != nil ? Color.accentColor : Color.secondary)
        }
    }
}

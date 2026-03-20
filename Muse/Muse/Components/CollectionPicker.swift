//
//  CollectionPicker.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

/// A Menu-based picker that lets the user assign an image to a `Collection`.
///
/// - `selectedCollectionID`: binding to the currently selected collection's UUID,
///   or `nil` for "Uncategorized".
/// - `collections`: the list of available collections to choose from.
/// - `onCreate`: called with the name string when the user creates a new collection.
struct CollectionPicker: View {

    @Binding var selectedCollectionID: UUID?
    let collections: [MuseCollection]
    let onCreate: (String) -> Void

    @State private var isCreating: Bool = false
    @State private var newCollectionName: String = ""

    // MARK: - Body

    var body: some View {
        if isCreating {
            newCollectionField
        } else {
            menu
        }
    }

    // MARK: - Subviews

    private var menu: some View {
        Menu {
            // Uncategorized option
            Button {
                selectedCollectionID = nil
            } label: {
                HStack {
                    Text("Uncategorized")
                    if selectedCollectionID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            // Existing collections
            ForEach(collections) { collection in
                Button {
                    selectedCollectionID = collection.id
                } label: {
                    HStack {
                        Text(collection.name)
                        if selectedCollectionID == collection.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            // Create new collection
            Button {
                newCollectionName = ""
                isCreating = true
            } label: {
                Label("New Collection…", systemImage: "plus")
            }
        } label: {
            menuLabel
        }
    }

    private var menuLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
            Text(selectedCollectionName)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
        }
        .font(.subheadline)
    }

    private var newCollectionField: some View {
        HStack(spacing: 6) {
            TextField("Collection name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitNewCollection()
                }

            Button("Add") {
                submitNewCollection()
            }
            .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                isCreating = false
                newCollectionName = ""
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var selectedCollectionName: String {
        guard let id = selectedCollectionID else { return "Uncategorized" }
        return collections.first(where: { $0.id == id })?.name ?? "Uncategorized"
    }

    private func submitNewCollection() {
        let trimmed = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        isCreating = false
        newCollectionName = ""
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    @Previewable @State var selectedID: UUID? = nil

    let sampleCollections = [
        MuseCollection(name: "Moodboard", colorHex: "#FF6B6B"),
        MuseCollection(name: "Architecture", colorHex: "#5E8BFF"),
        MuseCollection(name: "Typography", colorHex: "#A8E6CF"),
    ]

    CollectionPicker(
        selectedCollectionID: $selectedID,
        collections: sampleCollections
    ) { name in
        print("Create collection: \(name)")
    }
    .padding()
}
#endif

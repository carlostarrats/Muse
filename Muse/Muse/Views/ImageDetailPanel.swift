//
//  ImageDetailPanel.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

struct ImageDetailPanel: View {

    @EnvironmentObject var appState: AppState

    // MARK: - Local State

    @State private var tags: [Tag] = []
    @State private var newTagText: String = ""
    @State private var notes: String = ""
    @State private var collectionID: UUID?
    @State private var showDeleteConfirmation: Bool = false
    @FocusState private var notesFocused: Bool

    // MARK: - Body

    var body: some View {
        Group {
            if let image = appState.selectedImage {
                content(for: image)
            } else if !appState.selectedImages.isEmpty {
                batchContent
            } else {
                Color.clear
            }
        }
        .frame(width: 280)
        .background(.regularMaterial)
        .onChange(of: appState.selectedImage) { _, newImage in
            if let image = newImage {
                loadState(for: image)
            }
        }
        .onAppear {
            if let image = appState.selectedImage {
                loadState(for: image)
            }
        }
    }

    // MARK: - Single Image Content

    @ViewBuilder
    private func content(for image: MuseImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()

                fileInfoSection(for: image)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider()
                    .padding(.top, 12)

                collectionSection(for: image)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider()
                    .padding(.top, 12)

                tagsSection(for: image)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider()
                    .padding(.top, 12)

                notesSection(for: image)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Divider()
                    .padding(.top, 12)

                deleteSection(for: image)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
            }
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Batch Content (multi-select)

    @ViewBuilder
    private var batchContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("\(appState.selectedImages.count) images selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()
                .padding(.top, 12)

            // Batch tagging
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Batch Tag")

                Text("Add a tag to all selected images")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 6) {
                    TextField("Tag all selected…", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { batchTag() }

                    Button("Add") { batchTag() }
                        .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            // Clear selection
            Button {
                appState.selectedImages.removeAll()
                appState.detailPanelVisible = false
            } label: {
                Label("Clear Selection", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(appState.selectedImages.isEmpty ? "Details" : "Batch Edit")
                .font(.headline)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appState.detailPanelVisible = false
                    appState.selectedImage = nil
                    appState.selectedImages.removeAll()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - File Info

    @ViewBuilder
    private func fileInfoSection(for image: MuseImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("File Info")

            infoRow(label: "Name", value: image.fileName)
            infoRow(label: "Added", value: formatDate(image.dateAdded))

            if let width = image.width, let height = image.height {
                infoRow(label: "Size", value: "\(width) × \(height)")
            }

            if let fileSize = image.fileSize {
                infoRow(label: "File", value: formatFileSize(fileSize))
            }

            if let sourceURL = image.sourceURL, !sourceURL.isEmpty {
                infoRow(label: "Source", value: sourceURL, truncated: true)
            }
        }
    }

    // MARK: - Collection

    @ViewBuilder
    private func collectionSection(for image: MuseImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Collection")

            CollectionPicker(
                selectedCollectionID: $collectionID,
                collections: appState.collections
            ) { name in
                Task {
                    await appState.insertCollection(name: name)
                }
            }
            .onChange(of: collectionID) { _, newID in
                var updated = image
                updated.collectionID = newID
                Task {
                    await appState.updateImage(updated)
                }
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagsSection(for image: MuseImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Tags")

            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags) { tag in
                        TagPill(tag: tag) {
                            Task {
                                tags = await appState.deleteTag(tag)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add tag…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addTag(for: image)
                    }

                Button("Add") {
                    addTag(for: image)
                }
                .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Notes

    @ViewBuilder
    private func notesSection(for image: MuseImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Notes")

            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focused($notesFocused)
                .onChange(of: notesFocused) { _, isFocused in
                    if !isFocused {
                        saveNotes(for: image)
                    }
                }
        }
    }

    // MARK: - Delete

    @ViewBuilder
    private func deleteSection(for image: MuseImage) -> some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Label("Delete Image", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .confirmationDialog(
            "Delete \"\(image.fileName)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteImage(image)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the image and its files. This action cannot be undone.")
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func infoRow(label: String, value: String, truncated: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(truncated ? 1 : 3)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadState(for image: MuseImage) {
        notes = image.notes
        collectionID = image.collectionID
        Task {
            tags = await appState.fetchTags(for: image.id)
        }
    }

    private func addTag(for image: MuseImage) {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let isDuplicate = tags.contains {
            $0.label.lowercased() == trimmed.lowercased()
        }
        guard !isDuplicate else {
            newTagText = ""
            return
        }

        let tag = Tag(imageID: image.id, label: trimmed, source: "manual")
        newTagText = ""
        Task {
            tags = await appState.addTag(tag)
        }
    }

    private func batchTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        newTagText = ""
        Task {
            await appState.batchAddTag(label: trimmed)
        }
    }

    private func saveNotes(for image: MuseImage) {
        guard notes != image.notes else { return }
        var updated = image
        updated.notes = notes
        Task {
            await appState.updateImage(updated)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) bytes"
        } else if bytes < 1_048_576 {
            let kb = bytes / 1024
            return "\(kb) KB"
        } else {
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.1f MB", mb)
        }
    }
}

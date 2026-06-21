//
//  MarkdownViewerView.swift
//  Muse
//
//  Renders Markdown via Apple's AttributedString markdown parser.
//  Read-only with selectable text (Q6). For MD specifically: uses
//  AttributedString(markdown:) and disables remote image fetching to
//  honor the zero-network invariant.
//

import SwiftUI

struct MarkdownViewerView: View {
    let url: URL

    @State private var content: AttributedString = AttributedString("")
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let error = loadError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            // Don't fetch remote images. AttributedString(markdown:) parses inline
            // formatting + headings + lists; image URLs become text references.
            var options = AttributedString.MarkdownParsingOptions()
            options.allowsExtendedAttributes = true
            options.interpretedSyntax = .full
            let parsed = try AttributedString(markdown: raw, options: options)
            await MainActor.run {
                self.content = parsed
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                self.loadError = String(localized: "Could not load: \(error.localizedDescription)")
            }
        }
    }
}

//
//  FontViewerView.swift
//  Muse
//
//  Font preview: registers the font from URL (in-process) and shows
//  sample text at multiple sizes plus an alphabet glyph table.
//

import SwiftUI
import CoreText
import AppKit

struct FontViewerView: View {
    let url: URL

    @State private var fontName: String?
    @State private var error: String?

    private static let sampleSizes: [CGFloat] = [10, 14, 18, 24, 32, 48]
    private static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 .,!?;:'\"-—()[]/\\"
    private static let sampleText = "The quick brown fox jumps over the lazy dog."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                } else if let fontName {
                    Text(fontName)
                        .font(.title2.weight(.semibold))

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Self.sampleSizes, id: \.self) { size in
                            Text(Self.sampleText)
                                .font(.custom(fontName, size: size))
                        }
                    }

                    Divider()

                    Text(Self.alphabet)
                        .font(.custom(fontName, size: 28))
                        .lineSpacing(8)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.textBackgroundColor))
        .task(id: url) {
            // Register on appear; suspend until the task is cancelled (the URL
            // changes or the view goes away), then unregister so the process
            // font table doesn't accumulate a registration per font previewed.
            let didRegister = registerFont()
            defer {
                if didRegister {
                    CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
                }
            }
            // Hold the registration until SwiftUI cancels this task (the view
            // disappears or `url` changes). Cancellation interrupts the sleep
            // immediately, firing the defer. Polling a bounded interval avoids
            // Task.sleep(.max) deadline-overflow returning early on some runtimes.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Returns whether THIS call registered the font (so teardown only
    /// unregisters what it added — not a font another open viewer still uses).
    private func registerFont() -> Bool {
        var err: Unmanaged<CFError>?
        // Process scope keeps the font registered only for this app instance.
        let didRegister = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        // Read the postscript name regardless of register-success (may already be registered).
        if let dataProvider = CGDataProvider(url: url as CFURL),
           let cgFont = CGFont(dataProvider),
           let name = cgFont.postScriptName as String? {
            fontName = name
        } else {
            fontName = url.deletingPathExtension().lastPathComponent
        }
        return didRegister
    }
}

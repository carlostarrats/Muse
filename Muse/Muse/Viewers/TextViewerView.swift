//
//  TextViewerView.swift
//  Muse
//
//  Read-only text viewer with selectable text (Q6). NSTextView wrapped
//  for SwiftUI. Handles plain text, code, RTF.
//

import SwiftUI
import AppKit

struct TextViewerView: NSViewRepresentable {
    let url: URL
    let isCode: Bool
    let isRTF: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = isRTF
        textView.usesFindBar = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)

        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        if isCode {
            textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        } else {
            textView.font = NSFont.systemFont(ofSize: 14)
        }

        scrollView.documentView = textView
        load(into: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        load(into: textView)
    }

    private func load(into textView: NSTextView) {
        if isRTF, let data = try? Data(contentsOf: url),
           let attrStr = NSAttributedString(rtf: data, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrStr)
            return
        }
        // Plain text / code
        if let str = try? String(contentsOf: url, encoding: .utf8) {
            textView.string = str
        } else if let data = try? Data(contentsOf: url),
                  let str = String(data: data, encoding: .ascii) {
            textView.string = str
        } else {
            textView.string = "(unable to read file as text)"
        }
    }
}

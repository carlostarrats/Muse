//
//  ViewerRouter.swift
//  Muse
//
//  Routes a FileNode to the right viewer for its AssetKind. Each
//  case wraps the viewer body in ViewerChrome for consistent shell
//  (dimmed background, close button, escape-to-dismiss) — except
//  ImageViewer, which has its own dim/dismiss layer.
//

import SwiftUI

struct ViewerRouter: View {
    let file: FileNode

    var body: some View {
        switch file.kind {
        case .image, .raw, .psd:
            // NSImage handles RAW + PSD flat composite via ImageIO.
            ImageViewer(file: file)

        case .pdf:
            ViewerChrome(title: file.basename) {
                PDFViewerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .svg:
            ViewerChrome(title: file.basename) {
                SVGViewerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .markdown:
            ViewerChrome(title: file.basename) {
                MarkdownViewerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .text:
            ViewerChrome(title: file.basename) {
                TextViewerView(url: file.url, isCode: false, isRTF: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .code:
            ViewerChrome(title: file.basename) {
                TextViewerView(url: file.url, isCode: true, isRTF: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .office:
            // .rtf gets the rich text viewer; .docx/.doc/.pages → Quick Look
            if file.url.pathExtension.lowercased() == "rtf" {
                ViewerChrome(title: file.basename) {
                    TextViewerView(url: file.url, isCode: false, isRTF: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ViewerChrome(title: file.basename) {
                    QuickLookFallback(url: file.url)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

        case .video:
            ViewerChrome(title: file.basename) {
                VideoPlayerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .audio:
            ViewerChrome(title: file.basename) {
                AudioPlayerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .model3d:
            ViewerChrome(title: file.basename) {
                ModelViewerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        case .font:
            ViewerChrome(title: file.basename) {
                FontViewerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        default:
            ViewerChrome(title: file.basename) {
                QuickLookFallback(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

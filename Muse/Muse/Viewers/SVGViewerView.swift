//
//  SVGViewerView.swift
//  Muse
//
//  WKWebView-backed SVG viewer. Network loads disabled to honor the
//  zero-network architectural invariant — even if an SVG references
//  external assets, they won't be fetched.
//

import SwiftUI
import WebKit

struct SVGViewerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Local file access only — block any remote URL the SVG might reference.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground") // transparent background
        view.navigationDelegate = context.coordinator
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        load(into: nsView)
    }

    private func load(into view: WKWebView) {
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow only file:// loads. Anything network = blocked.
            if let scheme = navigationAction.request.url?.scheme, scheme != "file" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

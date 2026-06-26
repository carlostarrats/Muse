//
//  SVGViewerView.swift
//  Muse
//
//  WKWebView-backed SVG viewer. Network loads disabled to honor the
//  zero-network architectural invariant — even if an SVG references
//  external assets, they won't be fetched.
//
//  Two layers enforce that: (1) a WKContentRuleList that blocks every
//  http(s)/ws(s) load at the *resource* layer — this is what stops passive
//  subresources an SVG can pull without JS (<image href>, <use href>,
//  <feImage>, CSS url()/@import/@font-face); (2) a navigation delegate that
//  cancels any non-file frame navigation. The content rule is the load-bearing
//  one: decidePolicyFor only fires for frame navigations, never subresources,
//  so the delegate alone left an IP/tracking-pixel leak open. The file is
//  loaded only AFTER the block rule is installed, so no request can race ahead.
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
        context.coordinator.attach(view)
        context.coordinator.request(url)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.request(url)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var networkBlocked = false
        private var pendingURL: URL?

        /// Block every network subresource (http/https/ws/wss, plus file URLs
        /// carrying a host — the protocol-relative `//host` egress trick) at the
        /// resource layer — the only mechanism that covers subresource loads,
        /// which the navigation delegate never sees. The local SVG and its
        /// hostless `file:///` siblings are untouched, so rendering is
        /// unaffected. Fail CLOSED: if the rule can't be installed we never load
        /// the file, so no bytes can leave the machine (this app's whole brand is
        /// "no network"). Once installed, load any pending file.
        func attach(_ view: WKWebView) {
            webView = view
            guard let store = WKContentRuleListStore.default() else { return } // fail closed
            store.compileContentRuleList(forIdentifier: "muse-svg-block-network",
                                         encodedContentRuleList: Coordinator.blockNetworkRules) { [weak self] list, _ in
                guard let self, let list else { return } // compile failed → fail closed, don't render
                view.configuration.userContentController.add(list)
                self.networkBlocked = true
                if let u = self.pendingURL { self.load(u) }
            }
        }

        /// Request a file load, deferred until the network block is installed so
        /// no subresource request can fire before the rule is in place.
        func request(_ url: URL) {
            pendingURL = url
            if networkBlocked { load(url) }
        }

        private func load(_ url: URL) {
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Defense in depth: allow only hostless file:// frame navigations
            // (reject e.g. file://host/ from a protocol-relative reference).
            let u = navigationAction.request.url
            let host = u?.host ?? ""
            if u?.scheme != "file" || !(host.isEmpty || host == "localhost") {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private static let blockNetworkRules = """
        [{"trigger":{"url-filter":"https?://.*"},"action":{"type":"block"}},\
        {"trigger":{"url-filter":"wss?://.*"},"action":{"type":"block"}},\
        {"trigger":{"url-filter":"file://[^/].*"},"action":{"type":"block"}}]
        """
    }
}

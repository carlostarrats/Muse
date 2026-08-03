//
//  CompareView.swift
//  Muse
//
//  Full-screen compare workbench. No flight animation — this is a workbench,
//  not a stage. Mutually exclusive with the hero viewer.
//

import GRDB
import SwiftUI

struct CompareView: View {
    @ObservedObject var store: CompareStore
    @EnvironmentObject var appState: AppState

    /// sharpness / faceQuality / faceCount per shown URL, refreshed whenever
    /// the pane set changes. Read from `photo_traits` only — never computed
    /// live.
    @State private var traits: [String: (sharpness: Double?, faceQuality: Double?, faceCount: Int?)] = [:]
    @State private var panDragStart: CGPoint?

    var body: some View {
        if let urls = store.urls {
            let marks = SharpnessRank.rank(scores: urls.map { traits[$0.standardizedFileURL.path]?.sharpness ?? nil })
            let bestFaceIndex = bestFaceQualityIndex(urls)
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                VStack(spacing: 0) {
                    chromeRow(urls)
                    HStack(spacing: 2) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            ComparePane(url: url, isFocused: index == store.focusedIndex,
                                        mark: marks.indices.contains(index) ? marks[index] : .unmarked,
                                        bestFaceQuality: index == bestFaceIndex,
                                        store: store)
                                .onTapGesture { store.focus(index) }
                                .accessibilityAction(named: Text("Focus this pane")) {
                                    store.focus(index)
                                }
                                .compareVoiceOverActions(url: url, index: index,
                                                         store: store,
                                                         appState: appState)
                        }
                    }
                    .gesture(panGesture)
                }
                .background(keyCatcher)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Compare"))
            .task(id: urls.map(\.path).joined(separator: "|")) { await loadTraits(urls) }
        }
    }

    // MARK: - Chrome

    private func chromeRow(_ urls: [URL]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                Text(url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(index == store.focusedIndex
                                     ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.6)))
            }
            Spacer(minLength: 12)
            Button { store.peaking.toggle() } label: {
                Image(systemName: "scope")
                    .foregroundStyle(store.peaking ? Color.accentColor : .white)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Focus peaking"))
            .accessibilityLabel(String(localized: "Focus peaking"))

            Button {
                store.zoom = 1
                store.center = CGPoint(x: 0.5, y: 0.5)
            } label: {
                Text("Fit").foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Stepper(value: Binding(get: { store.zoom },
                                   set: { store.zoom = min(max($0, CompareGeometry.zoomRange.lowerBound),
                                                           CompareGeometry.zoomRange.upperBound) }),
                    in: CompareGeometry.zoomRange, step: 0.5) {
                Text(String(format: "%.1f×", store.zoom)).foregroundStyle(.white).font(.caption)
            }
            .fixedSize()

            Button { store.close() } label: {
                Image(systemName: "xmark").foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Close Compare"))
        }
        .padding(10)
    }

    private var keyCatcher: some View {
        CompareKeyCatcher(
            onArrow: { flipFocused($0) },
            onTab: { store.focus((store.focusedIndex + 1) % max(store.urls?.count ?? 1, 1)) },
            onRating: { stars in
                guard let urls = store.urls, urls.indices.contains(store.focusedIndex) else { return }
                let url = urls[store.focusedIndex]
                Task {
                    await TagStore.shared.setRating(stars, forURLs: [url])
                    appState.tagsVersion += 1
                }
            },
            onPeakingToggle: { store.peaking.toggle() })
    }

    // MARK: - Pan

    /// Panning moves the SHARED normalized center, which is what keeps every
    /// pane on the same subject regardless of its own aspect.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard store.zoom > 1 else { return }
                let start = panDragStart ?? store.center
                if panDragStart == nil { panDragStart = start }
                // 600pt of drag ≈ one full frame at zoom 1; dividing by zoom
                // keeps the on-screen travel constant as you zoom in.
                let delta = CGPoint(x: -value.translation.width / (600 * store.zoom),
                                    y: -value.translation.height / (600 * store.zoom))
                store.center = CompareGeometry.clampCenter(
                    CGPoint(x: start.x + delta.x, y: start.y + delta.y), zoom: store.zoom)
            }
            .onEnded { _ in panDragStart = nil }
    }

    // MARK: - Candidate flipping

    /// Replace the focused pane's photo with the previous/next photo-kind file
    /// in the current view, skipping any already shown in another pane.
    private func flipFocused(_ delta: Int) {
        guard let urls = store.urls, urls.indices.contains(store.focusedIndex) else { return }
        let images = appState.visibleFiles.filter { $0.kind.isPhotoKind }
        guard !images.isEmpty else { return }
        let shown = Set(urls.map(\.standardizedFileURL))
        let current = urls[store.focusedIndex].standardizedFileURL
        guard var idx = images.firstIndex(where: { $0.url.standardizedFileURL == current }) else { return }
        for _ in 0..<images.count {
            idx = (idx + delta + images.count) % images.count
            let candidate = images[idx].url
            if !shown.contains(candidate.standardizedFileURL) {
                store.replaceFocused(with: candidate)
                return
            }
        }
    }

    // MARK: - Traits

    private func bestFaceQualityIndex(_ urls: [URL]) -> Int? {
        // Only meaningful when EVERY pane actually has a face.
        let entries = urls.map { traits[$0.standardizedFileURL.path] }
        guard entries.allSatisfy({ ($0?.faceCount ?? 0) >= 1 }) else { return nil }
        let qualities = entries.map { $0?.faceQuality }
        guard let best = qualities.compactMap({ $0 }).max() else { return nil }
        return qualities.firstIndex { $0 == best }
    }

    private func loadTraits(_ urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map(\.standardizedFileURL.path)
        let fetched: [String: (Double?, Double?, Int?)] = (try? await queue.read { db in
            var out: [String: (Double?, Double?, Int?)] = [:]
            for path in paths {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT t.sharpness AS s, t.face_quality AS q, t.face_count AS c
                    FROM paths p JOIN photo_traits t ON t.file_id = p.file_id
                    WHERE p.absolute_path = ? AND p.is_alive = 1 LIMIT 1
                    """, arguments: [path]) else { continue }
                out[path] = (row["s"], row["q"], row["c"])
            }
            return out
        }) ?? [:]
        traits = fetched.mapValues { (sharpness: $0.0, faceQuality: $0.1, faceCount: $0.2) }
    }
}

/// VoiceOver equivalents for the compare workbench's KEY-ONLY actions.
///
/// Rating (0–5) is driven from `CompareKeyCatcher`, and VoiceOver swallows
/// plain character keys before an `NSView` ever sees them — so with the screen
/// reader on, the primary thing this workbench exists to do was unreachable.
/// Peaking, zoom, close and pane focus already had buttons or actions; rating
/// is the one that didn't. A keyboard shortcut is not an accessible
/// affordance on its own.
private struct CompareVoiceOverActions: ViewModifier {
    let url: URL
    let index: Int
    @ObservedObject var store: CompareStore
    let appState: AppState

    private func setRating(_ stars: Int?) {
        store.focus(index)
        Task {
            await TagStore.shared.setRating(stars, forURLs: [url])
            appState.tagsVersion += 1
        }
    }

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: Text("Rate 1 Star")) { setRating(1) }
            .accessibilityAction(named: Text("Rate 2 Stars")) { setRating(2) }
            .accessibilityAction(named: Text("Rate 3 Stars")) { setRating(3) }
            .accessibilityAction(named: Text("Rate 4 Stars")) { setRating(4) }
            .accessibilityAction(named: Text("Rate 5 Stars")) { setRating(5) }
            .accessibilityAction(named: Text("Clear Rating")) { setRating(nil) }
    }
}

extension View {
    func compareVoiceOverActions(url: URL, index: Int, store: CompareStore,
                                 appState: AppState) -> some View {
        modifier(CompareVoiceOverActions(url: url, index: index, store: store,
                                         appState: appState))
    }
}

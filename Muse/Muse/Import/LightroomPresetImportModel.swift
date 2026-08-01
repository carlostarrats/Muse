//
//  LightroomPresetImportModel.swift
//  Muse
//
//  Lightroom preset `.xmp` files → Muse looks.
//
//  Same parser and same mapper as the per-photo edit import, with one
//  difference that matters: a preset has NO as-shot reference, so an absolute
//  `crs:Temperature` in one is unmappable and is reported rather than guessed.
//  Incremental white balance maps normally.
//
//  Geometry is stripped (a stored crop ambushes every photo the look is
//  applied to — the shipped preset rule), but the Lightroom origin is KEPT:
//  this look genuinely is an approximation of someone else's, and the badge is
//  how the user knows.
//

import Foundation
import ImageIO
import SwiftUI

@MainActor
final class LightroomPresetImportModel: ObservableObject {

    enum Phase: Equatable {
        case running(done: Int, total: Int)
        case done(report: ImportReport)
    }

    @Published private(set) var phase: Phase = .running(done: 0, total: 0)

    private var task: Task<Void, Never>?

    func start(urls: [URL], appState: AppState) {
        guard task == nil else { return }
        task = Task { [weak self, weak appState] in
            guard let self else { return }
            await self.run(urls: urls, appState: appState)
        }
    }

    func cancel() { task?.cancel() }

    private func run(urls: [URL], appState: AppState?) async {
        var report = ImportReport(sourceName: String(localized: "Lightroom Presets"))
        await EditPresetStore.shared.load()

        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            phase = .running(done: index, total: urls.count)

            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parse(url)
            }.value
            guard let parsed else {
                report.filesSkipped += 1
                report.notices.append(String(localized: "\(url.lastPathComponent) couldn't be read."))
                continue
            }
            for name in parsed.edits.unsupported {
                report.unsupportedSliders[name, default: 0] += 1
            }
            // No as-shot context exists for a preset, so RAW-absolute WB has
            // nothing to be relative to.
            guard let stack = LightroomEditMapper.map(
                parsed.edits, context: .init(isRAW: false)) else {
                report.filesWithNone += 1
                continue
            }
            if parsed.edits.temperatureKelvin != nil {
                let notice = String(localized: "Presets that set an absolute white-balance temperature can't be translated — Muse's white balance is relative to each photo's own as-shot value.")
                if !report.notices.contains(notice) { report.notices.append(notice) }
            }
            let name = parsed.name
                ?? (url.deletingPathExtension().lastPathComponent)
            if await EditPresetStore.shared.createImported(name: name, stack: stack) != nil {
                report.presetsImported += 1
            } else {
                report.filesSkipped += 1
                report.notices.append(String(localized: "\(url.lastPathComponent) couldn't be saved."))
            }
        }

        phase = .done(report: report)
        appState?.importModal = .report(report)
    }

    nonisolated private static func parse(_ url: URL) -> (edits: LightroomEdits, name: String?)? {
        guard let data = try? Data(contentsOf: url),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        let edits = LightroomXMP.read(meta)
        return (edits, edits.presetName)
    }
}

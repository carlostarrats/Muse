//
//  ImportReportCard.swift
//  Muse
//
//  The one report card every import source ends on.
//
//  It computes NOTHING — the run model accumulated every number, so what the
//  user reads is literally what happened. That includes the parts that didn't:
//  the unsupported-slider disclosure and the stated-plainly notices are the
//  "never pretend a translation is lossless" rule made visible.
//

import SwiftUI

struct ImportReportCard: View {
    let report: ImportReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import complete")
                .font(.title3.weight(.semibold))
            Text(report.sourceName)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                row(String(localized: "Imported"), report.filesImported)
                row(String(localized: "Files updated"), report.filesTouched)
                row(String(localized: "Keywords"), report.keywords)
                row(String(localized: "Ratings"), report.ratings)
                row(String(localized: "Notes"), report.notes)
                row(String(localized: "Locations"), report.coordinates)
                row(String(localized: "Capture dates"), report.captureDates)
                row(String(localized: "Collections created"), report.collectionsCreated)
                row(String(localized: "Looks imported"), report.presetsImported)
                row(String(localized: "Adjustments approximated"), report.editsApproximated)
                row(String(localized: "Already edited in Muse — left alone"),
                    report.editsSkippedExisting)
                row(String(localized: "Nothing to import"), report.filesWithNone)
                row(String(localized: "Skipped"), report.filesSkipped)
            }

            if !report.labelCounts.isEmpty {
                Divider()
                ForEach(report.labelCounts, id: \.label) { outcome in
                    Text(labelLine(outcome))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !report.unsupportedSliders.isEmpty {
                Divider()
                Text("Not translated")
                    .font(.callout.weight(.semibold))
                ForEach(report.unsupportedSliders.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    Text("\(entry.key): \(entry.value) files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !report.notices.isEmpty {
                Divider()
                ForEach(report.notices, id: \.self) { notice in
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                ModalButton(title: String(localized: "Done"),
                            kind: .prominent, isDefault: true, action: onDone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    /// Zero rows are omitted rather than shown as "0" — a wall of zeros makes
    /// the numbers that DID happen harder to find.
    @ViewBuilder private func row(_ title: String, _ count: Int) -> some View {
        if count > 0 {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer(minLength: 16)
                Text("\(count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labelLine(_ outcome: LabelOutcome) -> String {
        switch outcome.choice {
        case .skip:
            return String(localized: "\(outcome.count) “\(outcome.label)” labels — skipped")
        case .namespaced:
            return String(localized: "\(outcome.count) “\(outcome.label)” labels → \(LabelTag.make(outcome.label))")
        case .tag(let target):
            return String(localized: "\(outcome.count) “\(outcome.label)” labels → \(target)")
        }
    }
}

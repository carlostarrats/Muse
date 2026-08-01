//
//  LabelMappingCard.swift
//  Muse
//
//  What should each incoming color label become? (DECIDED #12.)
//
//  Lightroom's red means "second pass"; Muse's red means the photo is red.
//  Merging them silently would poison color search, so the user decides once
//  per value and the choice is remembered — a second import of the same
//  catalog never asks again.
//

import SwiftUI

struct LabelMappingCard: View {
    let request: LabelMappingRequest
    let onFinished: () -> Void

    @State private var choices: [String: LabelMapping.Choice] = [:]
    @State private var tagDrafts: [String: String] = [:]
    /// The run model is suspended on this card's answer — resolve exactly once.
    @State private var resolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color Labels")
                .font(.title3.weight(.semibold))
            Text("These files carry color labels from another app. In Muse, colors describe what a photo LOOKS like, so labels are kept separate unless you say otherwise.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(request.values, id: \.self) { value in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(value) — \(request.counts[value] ?? 0) files")
                        .font(.callout.weight(.medium))
                    Picker("", selection: binding(for: value)) {
                        Text("Skip").tag(ChoiceKind.skip)
                        Text(LabelTag.make(value)).tag(ChoiceKind.namespaced)
                        Text("Map to a tag…").tag(ChoiceKind.tag)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    if kind(for: value) == .tag {
                        TextField(String(localized: "Tag name"),
                                  text: Binding(get: { tagDrafts[value] ?? "" },
                                                set: { tagDrafts[value] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                ModalButton(title: String(localized: "Skip All")) { finish(skippingAll: true) }
                Spacer()
                ModalButton(title: String(localized: "Apply"),
                            kind: .prominent, isDefault: true) { finish(skippingAll: false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .onAppear(perform: seed)
        // Escaping the card must not strand the run: the model is SUSPENDED on
        // this decision, so an unanswered dismissal resolves as Skip All rather
        // than leaking the task forever.
        .onDisappear { if !resolved { finish(skippingAll: true, dismiss: false) } }
    }

    // MARK: - Choice plumbing

    /// The picker needs a `Hashable` tag without an associated value; the tag
    /// TEXT lives in its own draft field so switching away and back doesn't
    /// lose what was typed.
    private enum ChoiceKind: Hashable { case skip, namespaced, tag }

    private func seed() {
        let remembered = LabelMapping.loadChoices()
        for value in request.values {
            let choice = remembered[value] ?? .namespaced
            choices[value] = choice
            if case .tag(let target) = choice { tagDrafts[value] = target }
        }
    }

    private func kind(for value: String) -> ChoiceKind {
        switch choices[value] ?? .namespaced {
        case .skip: return .skip
        case .namespaced: return .namespaced
        case .tag: return .tag
        }
    }

    private func binding(for value: String) -> Binding<ChoiceKind> {
        Binding(
            get: { kind(for: value) },
            set: { newValue in
                switch newValue {
                case .skip: choices[value] = .skip
                case .namespaced: choices[value] = .namespaced
                case .tag: choices[value] = .tag(tagDrafts[value] ?? "")
                }
            })
    }

    /// Apply persists the chosen mappings (so the next import is silent);
    /// Skip All deliberately does NOT — declining once is not a decision about
    /// every future catalog.
    private func finish(skippingAll: Bool, dismiss: Bool = true) {
        guard !resolved else { return }
        resolved = true
        var out: [String: LabelMapping.Choice] = [:]
        for value in request.values {
            if skippingAll {
                out[value] = .skip
            } else if case .tag = choices[value] ?? .namespaced {
                let draft = (tagDrafts[value] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                out[value] = draft.isEmpty ? .skip : .tag(draft)
            } else {
                out[value] = choices[value] ?? .namespaced
            }
        }
        if !skippingAll { LabelMapping.saveChoices(out) }
        request.onResolve(out)
        if dismiss { onFinished() }
    }
}

//
//  SmartCollectionRulesView.swift
//  Muse
//
//  The mail-style rule builder for a smart collection: a Name field, a
//  Match All/Any toggle, and a list of rule rows (type ▾ · operator ▾ · value).
//  Draft state is local @State — it commits to CollectionStore only on Save
//  (never per keystroke to AppState). Save is gated on a non-empty name and a
//  valid rule set. Presented via .windowFittedSheetHeight (its body scrolls).
//

import SwiftUI

struct SmartCollectionRulesView: View {
    /// nil id = creating a new smart collection; non-nil = editing / converting.
    let collectionID: String?
    /// When true (converting a manual collection with members), Save shows a
    /// data-loss confirm before writing.
    let confirmConversion: Bool
    let onClose: () -> Void

    @State private var name: String
    @State private var match: SmartRuleSet.Match
    @State private var rules: [SmartRule]
    @State private var showConvertConfirm = false

    init(collectionID: String?, initialName: String, initialSet: SmartRuleSet,
         confirmConversion: Bool = false, onClose: @escaping () -> Void) {
        self.collectionID = collectionID
        self.confirmConversion = confirmConversion
        self.onClose = onClose
        _name = State(initialValue: initialName)
        _match = State(initialValue: initialSet.match)
        _rules = State(initialValue: initialSet.rules.isEmpty ? [.tag(op: .has, label: "")] : initialSet.rules)
    }

    private var ruleSet: SmartRuleSet { SmartRuleSet(match: match, rules: rules) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && ruleSet.isValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Smart Collection")
                    .font(.system(size: 24, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                SheetCloseButton { onClose() }
            }
            .padding(.bottom, 20)

            TextField(String(localized: "Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Text("Match")
                Picker("", selection: $match) {
                    Text("All").tag(SmartRuleSet.Match.all)
                    Text("Any").tag(SmartRuleSet.Match.any)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Text("of the following rules")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rules.indices, id: \.self) { i in
                        SmartRuleRow(rule: $rules[i]) {
                            if rules.count > 1 { rules.remove(at: i) }
                        }
                    }
                }
            }
            .frame(minHeight: 120)

            Button {
                rules.append(.tag(op: .has, label: ""))
            } label: {
                Label("Add Rule", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if confirmConversion { showConvertConfirm = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.top, 20)
        }
        .padding(28)
        .windowFittedSheetHeight(width: 520, ideal: 560)
        .alert("Replace this collection’s items with rules?", isPresented: $showConvertConfirm) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The images you added by hand are removed from this collection and replaced by rule-based membership. Your files stay on disk.")
        }
    }

    private func save() {
        // Freeze relative "within N days" to an absolute .after bound at save
        // time, so the persisted rule is deterministic (the resolver's tested
        // path). Tradeoff: the bound is fixed at save, not re-evaluated daily.
        let now = Int64(Date().timeIntervalSince1970)
        let resolvedRules = rules.map { rule -> SmartRule in
            if case let .date(field, .withinDays(d)) = rule {
                return .date(field: field, op: .after(now - Int64(d) * 86_400))
            }
            return rule
        }
        let set = SmartRuleSet(match: match, rules: resolvedRules)
        let finalName = name.trimmingCharacters(in: .whitespaces)
        let id = collectionID
        let convert = confirmConversion
        onClose()
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            if let id {
                if convert {
                    try? await CollectionStore.makeSmart(queue: q, id: id, ruleSet: set)
                    try? await CollectionStore.rename(queue: q, id: id, name: finalName)
                } else {
                    try? await CollectionStore.setSmartRules(queue: q, id: id, name: finalName, ruleSet: set)
                }
            } else {
                _ = try? await CollectionStore.createSmart(queue: q, name: finalName, ruleSet: set)
            }
            await CollectionsEngine.shared.reload()
        }
    }
}

/// One editable rule: a type picker, a type-specific operator + value control,
/// and a remove button. All edits mutate the bound `SmartRule` in place.
private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let onRemove: () -> Void

    // A stable "kind" discriminator for the type picker.
    private enum Kind: String, CaseIterable, Identifiable {
        case rating, color, tag, kind, date, filename, size
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rating:   return String(localized: "Rating")
            case .color:    return String(localized: "Color")
            case .tag:      return String(localized: "Tag")
            case .kind:     return String(localized: "Kind")
            case .date:     return String(localized: "Date")
            case .filename: return String(localized: "Filename")
            case .size:     return String(localized: "Size")
            }
        }
    }

    private var currentKind: Kind {
        switch rule {
        case .rating:   return .rating
        case .color:    return .color
        case .tag:      return .tag
        case .kind:     return .kind
        case .date:     return .date
        case .filename: return .filename
        case .size:     return .size
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { currentKind },
                set: { rule = SmartRuleRow.defaultRule(for: $0) })) {
                ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
            }
            .labelsHidden()
            .frame(width: 120)

            valueControls

            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove rule"))
        }
    }

    /// A sensible default rule when the type changes.
    private static func defaultRule(for kind: Kind) -> SmartRule {
        switch kind {
        case .rating:   return .rating(op: .atLeast, stars: 4)
        case .color:    return .color(.hex(""))
        case .tag:      return .tag(op: .has, label: "")
        case .kind:     return .kind(.image)
        case .date:     return .date(field: .modified, op: .withinDays(30))
        case .filename: return .filename(contains: "")
        case .size:     return .size(op: .atMost, bytes: 5_000_000)
        }
    }

    @ViewBuilder private var valueControls: some View {
        switch rule {
        case let .rating(op, stars):
            comparisonPicker(op) { rule = .rating(op: $0, stars: stars) }
            Stepper(value: Binding(get: { stars },
                                   set: { rule = .rating(op: op, stars: min(5, max(1, $0))) }),
                    in: 1...5) {
                Text("\(stars) ★")
            }
            .fixedSize()

        case let .color(term):
            // v1 is hex-only: NamedColor.parse decodes hex, not color names, so a
            // bare name would silently match nothing. The COLORS card copies hex,
            // which is the intended input. (.name stays in the model for a future
            // named-color table.)
            TextField(String(localized: "#hex"),
                      text: Binding(get: { colorString(term) },
                                    set: { rule = .color(.hex($0)) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

        case let .tag(op, label):
            Picker("", selection: Binding(get: { op },
                                          set: { rule = .tag(op: $0, label: label) })) {
                Text("has").tag(HasOp.has)
                Text("has no").tag(HasOp.hasNot)
            }.labelsHidden().frame(width: 90)
            TextField(String(localized: "tag"),
                      text: Binding(get: { label }, set: { rule = .tag(op: op, label: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

        case let .kind(group):
            Picker("", selection: Binding(get: { group },
                                          set: { rule = .kind($0) })) {
                ForEach(SmartRule.KindGroup.allCases, id: \.self) { g in
                    Text(kindLabel(g)).tag(g)
                }
            }.labelsHidden().frame(width: 140)

        case let .date(field, op):
            Picker("", selection: Binding(get: { field },
                                          set: { rule = .date(field: $0, op: op) })) {
                Text("created").tag(DateField.created)
                Text("modified").tag(DateField.modified)
            }.labelsHidden().frame(width: 110)
            dateOpControls(field: field, op: op)

        case let .filename(contains):
            TextField(String(localized: "contains"),
                      text: Binding(get: { contains }, set: { rule = .filename(contains: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

        case let .size(op, bytes):
            comparisonPicker(op) { rule = .size(op: $0, bytes: bytes) }
            let mb = Binding(get: { Double(bytes) / 1_000_000 },
                             set: { rule = .size(op: op, bytes: Int64(max(0, $0) * 1_000_000)) })
            TextField("MB", value: mb, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("MB").foregroundStyle(.secondary)
        }
    }

    // MARK: - small helpers

    @ViewBuilder private func comparisonPicker(_ op: Comparison,
                                               _ set: @escaping (Comparison) -> Void) -> some View {
        Picker("", selection: Binding(get: { op }, set: set)) {
            Text("≥").tag(Comparison.atLeast)
            Text("=").tag(Comparison.equal)
            Text("≤").tag(Comparison.atMost)
        }.labelsHidden().frame(width: 70)
    }

    @ViewBuilder private func dateOpControls(field: DateField, op: DateOp) -> some View {
        // v1: "within N days" only (before/after are stored but the builder
        // exposes the common relative case; N is converted to an absolute
        // .after bound at Save time by the parent). Keep the UI to a stepper.
        let days = Binding<Int>(
            get: { if case let .withinDays(d) = op { return d } else { return 30 } },
            set: { rule = .date(field: field, op: .withinDays(max(1, $0))) })
        Stepper(value: days, in: 1...3650) {
            Text("within \(days.wrappedValue) days")
        }.fixedSize()
    }

    private func kindLabel(_ g: SmartRule.KindGroup) -> String {
        switch g {
        case .image:    return String(localized: "Images")
        case .raw:      return String(localized: "RAW")
        case .pdf:      return String(localized: "PDFs")
        case .video:    return String(localized: "Videos")
        case .audio:    return String(localized: "Audio")
        case .document: return String(localized: "Documents")
        }
    }

    private func colorString(_ term: ColorTerm) -> String {
        switch term { case let .name(n): return n; case let .hex(h): return h }
    }
}

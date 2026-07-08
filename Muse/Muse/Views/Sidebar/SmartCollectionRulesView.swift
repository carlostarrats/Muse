//
//  SmartCollectionRulesView.swift
//  Muse
//
//  The mail-style rule builder for a smart collection: a Name field, a
//  Match All/Any toggle, and a list of rule rows (type ▾ · operator ▾ · value).
//  Draft state is local @State — it commits to CollectionStore only on Save
//  (never per keystroke to AppState). Save is gated on a non-empty name and a
//  valid rule set. The header + footer are fixed; only the rule list scrolls.
//

import SwiftUI
import AppKit

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
    @State private var addHover = false

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
            // ── Fixed header ────────────────────────────────────────────────
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
                .controlSize(.large)
                .padding(.bottom, 16)

            HStack(spacing: 10) {
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

            Divider()

            // ── Scrolling rule list (the only scroll region) ────────────────
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(rules.indices, id: \.self) { i in
                        SmartRuleRow(rule: $rules[i], canRemove: rules.count > 1) {
                            rules.remove(at: i)
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 4)
                // Trailing gutter so the scroll indicator never overlaps the
                // per-row remove buttons.
                .padding(.trailing, 20)
            }
            .frame(minHeight: 150, maxHeight: 360)

            // ── Add rule (a real button, hover tint) ────────────────────────
            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    rules.append(.tag(op: .has, label: ""))
                }
            } label: {
                Label("Add Rule", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(addHover ? 0.12 : 0.06)))
            }
            .buttonStyle(.plain)
            .onHover { addHover = $0 }
            .padding(.top, 14)

            // ── Fixed footer ────────────────────────────────────────────────
            Divider()
                .padding(.top, 16)

            HStack {
                Spacer()
                FooterButton(title: "Cancel", prominent: false, disabled: false) { onClose() }
                    .keyboardShortcut(.cancelAction)
                FooterButton(title: "Save", prominent: true, disabled: !canSave) {
                    if confirmConversion { showConvertConfirm = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(28)
        .windowFittedSheetHeight(width: 560, ideal: 620)
        .alert("Replace this collection’s items with rules?", isPresented: $showConvertConfirm) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The images you added by hand are removed from this collection and replaced by rule-based membership. Your files stay on disk.")
        }
    }

    private func save() {
        let set = SmartRuleSet(match: match, rules: rules)
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

// MARK: - Rule row

/// One editable rule: a type picker, a type-specific operator + value control,
/// and a remove button (own hover state). All edits mutate the bound `SmartRule`.
private struct SmartRuleRow: View {
    @Binding var rule: SmartRule
    let canRemove: Bool
    let onRemove: () -> Void

    @State private var removeHover = false

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
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { currentKind },
                set: { rule = SmartRuleRow.defaultRule(for: $0) })) {
                ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
            }
            .labelsHidden()
            .frame(width: 112)

            valueControls

            Spacer(minLength: 8)

            Button(action: { if canRemove { onRemove() } }) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(removeHover && canRemove ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(removeHover && canRemove ? 0.10 : 0)))
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .opacity(canRemove ? 1 : 0.35)
            .onHover { removeHover = $0 }
            .help(String(localized: "Remove rule"))
            .accessibilityLabel(String(localized: "Remove rule"))
        }
    }

    private static func defaultRule(for kind: Kind) -> SmartRule {
        switch kind {
        case .rating:   return .rating(op: .atLeast, stars: 4)
        case .color:    return .color(.name("blue"))
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
            colorMenu(term)

        case let .tag(op, label):
            Picker("", selection: Binding(get: { op },
                                          set: { rule = .tag(op: $0, label: label) })) {
                Text("with").tag(HasOp.has)
                Text("without").tag(HasOp.hasNot)
            }.labelsHidden().fixedSize()
            TextField(String(localized: "tag"),
                      text: Binding(get: { label }, set: { rule = .tag(op: op, label: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

        case let .kind(group):
            Picker("", selection: Binding(get: { group },
                                          set: { rule = .kind($0) })) {
                ForEach(SmartRule.KindGroup.allCases, id: \.self) { g in
                    Text(kindLabel(g)).tag(g)
                }
            }.labelsHidden().fixedSize()

        case let .date(field, op):
            Picker("", selection: Binding(get: { field },
                                          set: { rule = .date(field: $0, op: op) })) {
                Text("created").tag(DateField.created)
                Text("modified").tag(DateField.modified)
            }.labelsHidden().fixedSize()
            datePresetMenu(field: field, op: op)

        case let .filename(contains):
            TextField(String(localized: "contains"),
                      text: Binding(get: { contains }, set: { rule = .filename(contains: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)

        case let .size(op, bytes):
            comparisonPicker(op) { rule = .size(op: $0, bytes: bytes) }
            let mb = Binding(get: { Double(bytes) / 1_000_000 },
                             set: { rule = .size(op: op, bytes: Int64(max(0, $0) * 1_000_000)) })
            TextField("MB", value: mb, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
            Text("MB").foregroundStyle(.secondary)
        }
    }

    // MARK: - control helpers

    @ViewBuilder private func comparisonPicker(_ op: Comparison,
                                               _ set: @escaping (Comparison) -> Void) -> some View {
        Picker("", selection: Binding(get: { op }, set: set)) {
            Text("≥").tag(Comparison.atLeast)
            Text("=").tag(Comparison.equal)
            Text("≤").tag(Comparison.atMost)
        }.labelsHidden().fixedSize()
    }

    /// A named-color chooser: a swatch + name that opens the spectrum menu.
    @ViewBuilder private func colorMenu(_ term: ColorTerm) -> some View {
        let currentToken: String = { if case let .name(t) = term { return t } else { return "blue" } }()
        Menu {
            ForEach(SmartColor.tokens, id: \.self) { token in
                Button {
                    rule = .color(.name(token))
                } label: {
                    // A menu templates SF Symbols to the text color, so a
                    // "circle.fill" would render black — use a rendered, non-
                    // template swatch image to show the actual color.
                    Label {
                        Text(SmartRuleRow.colorName(token))
                    } icon: {
                        SmartRuleRow.swatchImage(token)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(SmartRuleRow.swatch(currentToken))
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                Text(SmartRuleRow.colorName(currentToken))
            }
        }
        .fixedSize()
    }

    private static let datePresets: [(days: Int, label: String)] = [
        (1,   String(localized: "Last 24 hours")),
        (3,   String(localized: "Last 3 days")),
        (7,   String(localized: "Last week")),
        (14,  String(localized: "Last 2 weeks")),
        (30,  String(localized: "Last month")),
        (90,  String(localized: "Last 3 months")),
        (180, String(localized: "Last 6 months")),
        (365, String(localized: "Last year")),
    ]

    /// A preset picker for "within N days" — no day math, no click-spamming a
    /// stepper. Absolute .before/.after bounds aren't offered here (v1).
    @ViewBuilder private func datePresetMenu(field: DateField, op: DateOp) -> some View {
        let currentDays: Int = { if case let .withinDays(d) = op { return d } else { return 30 } }()
        let currentLabel = SmartRuleRow.datePresets.first { $0.days == currentDays }?.label
            ?? String(localized: "Last \(currentDays) days")
        Menu {
            ForEach(SmartRuleRow.datePresets, id: \.days) { preset in
                Button(preset.label) { rule = .date(field: field, op: .withinDays(preset.days)) }
            }
        } label: {
            Text(currentLabel)
        }
        .fixedSize()
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

    // MARK: - named-color display

    static func swatch(_ token: String) -> Color {
        guard let rgb = SmartColor.rgb(for: token) else { return .gray }
        return Color(red: rgb.r, green: rgb.g, blue: rgb.b)
    }

    /// A rendered (non-template) filled-circle image so menu items show the
    /// ACTUAL color — SwiftUI menus tint SF Symbols to the label color.
    static func swatchImage(_ token: String) -> Image {
        let rgb = SmartColor.rgb(for: token) ?? RGB(r: 0.5, g: 0.5, b: 0.5)
        let d: CGFloat = 12
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1))
        ring.lineWidth = 0.5
        ring.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return Image(nsImage: img).renderingMode(.original)
    }

    static func colorName(_ token: String) -> String {
        switch token {
        case "red":    return String(localized: "Red")
        case "orange": return String(localized: "Orange")
        case "yellow": return String(localized: "Yellow")
        case "green":  return String(localized: "Green")
        case "teal":   return String(localized: "Teal")
        case "cyan":   return String(localized: "Cyan")
        case "blue":   return String(localized: "Blue")
        case "navy":   return String(localized: "Navy")
        case "purple": return String(localized: "Purple")
        case "pink":   return String(localized: "Pink")
        case "brown":  return String(localized: "Brown")
        case "black":  return String(localized: "Black")
        case "gray":   return String(localized: "Gray")
        case "white":  return String(localized: "White")
        default:       return token.capitalized
        }
    }
}

// MARK: - Footer button (hover state)

/// Cancel / Save with an explicit hover tint, matching the rest of the sheet's
/// custom hover feedback. `prominent` = the accent-filled default action.
private struct FooterButton: View {
    let title: LocalizedStringKey
    let prominent: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hover = $0 && !disabled }
    }

    private var background: Color {
        if prominent {
            return Color.accentColor.opacity(hover ? 1.0 : 0.9)
        } else {
            return Color.primary.opacity(hover ? 0.14 : 0.07)
        }
    }
}

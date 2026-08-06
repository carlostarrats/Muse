//
//  WelcomeOnboardingView.swift
//  Muse
//
//  A short first-run introduction to the useful workflows that are otherwise
//  easy to miss. Presentation and persistence belong to the store.
//

import AppKit
import SwiftUI

enum WelcomeOnboardingPage: Int, CaseIterable, Identifiable {
    case welcome
    case organize
    case share

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .welcome:  String(localized: "Welcome to Muse")
        case .organize: String(localized: "More ways to organize")
        case .share:    String(localized: "Save and share collections")
        }
    }

    var paragraphs: [String] {
        switch self {
        case .welcome:
            [String(localized: "Browse and organize photos and other files on your Mac."),
             String(localized: "Add a folder to begin.")]
        case .organize:
            [String(localized: "Smart Collections update automatically using details like rating, date, color, or file type."),
             String(localized: "Right-click selected photos to add them to a collection or compare them side by side.")]
        case .share:
            [String(localized: "Open a collection and use Share to save a PDF, export images, or publish a portfolio website.")]
        }
    }

    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }
    var hasBack: Bool { previous != nil }
    var hasGuideLink: Bool { self == .share }
    var isLast: Bool { next == nil }
    var primaryTitle: String {
        isLast ? String(localized: "Get Started") : String(localized: "Next")
    }
}

struct WelcomeOnboardingView: View {
    private enum Control: Hashable {
        case guide
        case back
        case primary
    }

    let onDismiss: () -> Void

    @State private var page: WelcomeOnboardingPage = .welcome
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                Text(page.title)
                    .font(.system(size: 26, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(pageAccessibilityLabel)
                    .accessibilityFocused($titleFocused)

                Spacer(minLength: 16)

                pageDots
            }
            .frame(height: 34, alignment: .top)

            HStack(alignment: .top, spacing: 28) {
                pageCopy
                    .frame(width: 260, alignment: .topLeading)

                ZStack {
                    WelcomeOnboardingArtwork(page: page)
                        .id(page)
                        .transition(.asymmetric(
                            insertion: reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: 8)),
                            removal: .identity))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: page)
                .frame(maxWidth: .infinity, minHeight: 248, maxHeight: 248)
                .accessibilityHidden(true)
            }
            .padding(.top, 18)
            .frame(height: 272, alignment: .top)

            footer
                .frame(height: 42, alignment: .bottom)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .onAppear { moveAccessibilityFocusToTitle() }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard focusedControl == nil else { return .ignored }
            if press.key == .leftArrow, let previous = page.previous {
                move(to: previous)
                return .handled
            }
            if press.key == .rightArrow, let next = page.next {
                move(to: next)
                return .handled
            }
            return .ignored
        }
    }

    private var pageCopy: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph)
                    .font(.system(size: 14))
                    .fontWeight(page == .welcome && index == 1 ? .medium : .regular)
                    .foregroundStyle(page == .welcome && index == 1
                                     ? Color.primary : Color.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if page.hasGuideLink {
                guideAction
                    .padding(.top, 3)
            }
        }
    }

    private var guideAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Need help? Open Muse FAQs with the ⓘ button.")
                .foregroundStyle(.secondary)

            OnboardingGuideButton(title: String(localized: "Full Guide"),
                                  isFocused: focusedControl == .guide) {
                NSWorkspace.shared.open(AppLinks.guide)
            }
            .focused($focusedControl, equals: .guide)
            .accessibilityLabel("Open the Full Guide")
            .accessibilityHint("Opens a web page")
        }
        .font(.system(size: 14))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(WelcomeOnboardingPage.allCases) { candidate in
                Circle()
                    .fill(candidate == page
                          ? Color.accentColor
                          : Color.primary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let previous = page.previous {
                ModalButton(title: String(localized: "Back")) {
                    move(to: previous)
                }
                .focused($focusedControl, equals: .back)
            }

            ModalButton(title: page.primaryTitle,
                        kind: .prominent,
                        isDefault: true) {
                if let next = page.next {
                    move(to: next)
                } else {
                    onDismiss()
                }
            }
            .focused($focusedControl, equals: .primary)

            Spacer(minLength: 0)
        }
    }

    private var pageAccessibilityLabel: String {
        String(format: String(localized: "%@. Page %lld of 3."),
               page.title, Int64(page.number))
    }

    private func move(to newPage: WelcomeOnboardingPage) {
        page = newPage
        moveAccessibilityFocusToTitle()
    }

    private func moveAccessibilityFocusToTitle() {
        titleFocused = false
        DispatchQueue.main.async { titleFocused = true }
    }
}

private struct OnboardingGuideButton: View {
    let title: String
    let isFocused: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 31)
                .background(
                    Color.primary.opacity(hovering ? 0.22 : 0.15),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isFocused
                                      ? Color.accentColor
                                      : Color.primary.opacity(0.16),
                                      lineWidth: isFocused ? 2 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

//
//  WelcomeOnboardingArtwork.swift
//  Muse
//
//  Small, animated recreations of the actual Muse interface. These scenes are
//  the visual explanation for each onboarding page, so every moving part maps
//  to the workflow named by the copy rather than acting as decoration.
//

import SwiftUI

struct WelcomeOnboardingArtwork: View {
    let page: WelcomeOnboardingPage

    @State private var startedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: reduceMotion)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            VStack(spacing: 0) {
                DemoToolbar()
                scene(at: reduceMotion ? page.reducedMotionTime : elapsed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DemoColor.stage)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 17, y: 8)
        .onAppear { startedAt = Date() }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func scene(at elapsed: TimeInterval) -> some View {
        switch page {
        case .welcome:
            FolderDemo(time: elapsed.truncatingRemainder(dividingBy: 7.2))
        case .organize:
            OrganizeDemo(time: elapsed.truncatingRemainder(dividingBy: 8.0))
        case .share:
            ShareDemo(time: elapsed.truncatingRemainder(dividingBy: 8.4))
        }
    }
}

private extension WelcomeOnboardingPage {
    var reducedMotionTime: TimeInterval {
        switch self {
        case .welcome: 4.8
        case .organize: 6.4
        case .share: 4.7
        }
    }
}

private enum DemoColor {
    static let stage = Color(red: 0.118, green: 0.118, blue: 0.133)
    static let toolbar = Color(red: 0.145, green: 0.145, blue: 0.165)
    static let sidebar = Color(red: 0.141, green: 0.141, blue: 0.157)
    static let raised = Color(red: 0.202, green: 0.202, blue: 0.225)
    static let field = Color(red: 0.137, green: 0.137, blue: 0.153)
    static let line = Color.white.opacity(0.10)
    static let text = Color(red: 0.94, green: 0.94, blue: 0.95)
    static let muted = Color(red: 0.62, green: 0.62, blue: 0.66)
}

private struct DemoToolbar: View {
    var body: some View {
        HStack(spacing: 4) {
            DemoToolbarGroup(symbols: ["sidebar.left"], widths: [22])
                .padding(.trailing, 2)
            DemoToolbarGroup(symbols: ["arrow.up.arrow.down", "arrow.down", "line.3.horizontal"])
            DemoToolbarGroup(symbols: ["rectangle.portrait", "square.grid.2x2", "link"])

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text(verbatim: "Search files, tags, captions…")
                    .lineLimit(1)
            }
            .font(.system(size: 7))
            .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.50))
            .padding(.horizontal, 8)
            .frame(width: 138, height: 20, alignment: .leading)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 7,
                                             style: .continuous))
        }
        .padding(.horizontal, 7)
        .frame(height: 32)
        .background(DemoColor.toolbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DemoColor.line).frame(height: 1)
        }
    }
}

private struct DemoToolbarGroup: View {
    let symbols: [String]
    var widths: [CGFloat] = []

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.84))
                    .frame(width: widths.indices.contains(index) ? widths[index] : 18,
                           height: 20)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                        }
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct FolderDemo: View {
    let time: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let galleryOpacity = windowOpacity(time, 2.8, 3.5, 6.6, 7.2)
            let promptOpacity = 1 - ramp(time, 2.45, 3.05)
            let cursor = folderCursor(in: proxy.size)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "FOLDERS")
                            .font(.system(size: 7, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.60))
                            .padding(.leading, 14)
                            .padding(.top, 13)
                            .padding(.bottom, 7)

                        folderRow(symbol: "cloud", name: "Muse", count: "0")
                        folderRow(symbol: "folder", name: "Weekend Away", count: "6",
                                  selected: true)
                            .opacity(galleryOpacity)
                            .offset(y: (1 - galleryOpacity) * -5)
                        Spacer()
                    }
                    .frame(width: 112)
                    .background(DemoColor.sidebar)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(DemoColor.line).frame(width: 1)
                    }

                    ZStack {
                        VStack(spacing: 9) {
                            Text(verbatim: "Get started by adding a folder")
                                .font(.system(size: 9))
                                .foregroundStyle(DemoColor.muted)

                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                Text(verbatim: "Add Folder")
                            }
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.17))
                            .padding(.horizontal, 9)
                            .frame(height: 21)
                            .background(Color(red: 0.94, green: 0.94, blue: 0.95),
                                        in: Capsule())
                        }
                        .opacity(promptOpacity)

                        DemoPhotoGrid()
                            .padding(14)
                            .opacity(galleryOpacity)
                            .offset(y: (1 - galleryOpacity) * 9)
                    }
                }

                if cursor.opacity > 0 {
                    DemoPointer()
                        .opacity(cursor.opacity)
                        .position(cursor.position)
                }

                Circle()
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .scaleEffect(clickScale(time, 2.15, 2.7))
                    .opacity(clickOpacity(time, 2.15, 2.7))
                    .position(x: 112 + (proxy.size.width - 112) / 2 + 3,
                              y: proxy.size.height / 2 + 14)
            }
        }
    }

    private func folderRow(symbol: String, name: String, count: String,
                           selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(name).lineLimit(1)
            Spacer(minLength: 2)
            Text(count).opacity(0.7)
        }
        .font(.system(size: 8, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.white : DemoColor.muted)
        .padding(.horizontal, 7)
        .frame(height: 23)
        .background(selected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(.horizontal, 7)
    }

    private func folderCursor(in size: CGSize) -> (position: CGPoint, opacity: CGFloat) {
        let start = CGPoint(x: size.width - 28, y: size.height - 24)
        let button = CGPoint(x: 112 + (size.width - 112) / 2 + 10,
                             y: size.height / 2 + 18)
        let folder = CGPoint(x: 55, y: 57)
        let opacity = windowOpacity(time, 0.6, 0.9, 4.15, 4.55)
        if time < 2.05 {
            return (interpolate(start, button, ramp(time, 0.9, 2.05)), opacity)
        }
        if time < 3.05 { return (button, opacity) }
        return (interpolate(button, folder, ramp(time, 3.05, 4.05)), opacity)
    }
}

private struct OrganizeDemo: View {
    let time: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let resultOpacity = windowOpacity(time, 3.45, 4.05, 7.65, 8.0)
            let editorOpacity = 1 - ramp(time, 3.25, 3.8)
            let menuOpacity = windowOpacity(time, 5.15, 5.65, 7.5, 7.9)

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 7) {
                        Text(verbatim: "Favorites")
                            .font(.system(size: 12, weight: .bold))
                        Text(verbatim: "4")
                            .font(.system(size: 9))
                            .foregroundStyle(DemoColor.muted)
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal.decrease")
                            Text(verbatim: "Smart Collection")
                        }
                        .font(.system(size: 7))
                        .foregroundStyle(Color(red: 0.66, green: 0.83, blue: 1.0))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 43)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(DemoColor.line).frame(height: 1)
                    }

                    DemoPhotoGrid(selected: [0, 1])
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .padding(.bottom, 12)
                }
                .opacity(resultOpacity)

                DemoSmartEditor(saveHighlighted: time >= 2.25 && time <= 3.35)
                    .padding(.horizontal, 39)
                    .padding(.top, 11)
                    .padding(.bottom, 14)
                    .opacity(editorOpacity)

                DemoContextMenu(compareHighlighted: time >= 6.05 && time <= 7.35)
                    .frame(width: 138)
                    .padding(.top, 70)
                    .padding(.trailing, 12)
                    .opacity(menuOpacity)
                    .scaleEffect(0.94 + 0.06 * menuOpacity, anchor: .topTrailing)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct DemoSmartEditor: View {
    let saveHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "Smart Collection")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundStyle(DemoColor.muted)
            }
            .frame(height: 26, alignment: .top)

            Text(verbatim: "NAME")
                .font(.system(size: 6, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.60))
                .padding(.bottom, 3)

            Text(verbatim: "Favorites")
                .font(.system(size: 8))
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 23, alignment: .leading)
                .background(DemoColor.field,
                            in: RoundedRectangle(cornerRadius: 5,
                                                 style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(DemoColor.line, lineWidth: 1)
                }

            HStack(spacing: 6) {
                Text(verbatim: "Match")
                Text(verbatim: "All")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color(red: 0.35, green: 0.35, blue: 0.39),
                                in: RoundedRectangle(cornerRadius: 5,
                                                     style: .continuous))
                Text(verbatim: "Any")
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(DemoColor.field,
                                in: RoundedRectangle(cornerRadius: 5,
                                                     style: .continuous))
                Text(verbatim: "of the following rules")
                Spacer(minLength: 0)
            }
            .font(.system(size: 7))
            .foregroundStyle(Color(red: 0.70, green: 0.70, blue: 0.73))
            .frame(height: 31)

            HStack(spacing: 5) {
                ruleField("Rating", width: 62)
                ruleField("is at least", width: 70)
                Text(verbatim: "★★★★")
                    + Text(verbatim: "★")
                        .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.42))
            }
            .font(.system(size: 8))
            .foregroundStyle(Color.yellow)
            .padding(.horizontal, 7)
            .frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(DemoColor.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(DemoColor.line).frame(height: 1) }

            HStack(spacing: 5) {
                Spacer()
                editorButton("Cancel", highlighted: false)
                editorButton("Save", highlighted: true)
                    .brightness(saveHighlighted ? 0.2 : 0)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(13)
        .background(Color(red: 0.188, green: 0.188, blue: 0.212),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.48), radius: 16, y: 9)
    }

    private func ruleField(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.84))
            .padding(.horizontal, 6)
            .frame(width: width, height: 22, alignment: .leading)
            .background(DemoColor.field,
                        in: RoundedRectangle(cornerRadius: 5,
                                             style: .continuous))
    }

    private func editorButton(_ title: String, highlighted: Bool) -> some View {
        Text(title)
            .font(.system(size: 7))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(highlighted ? Color.accentColor : Color(red: 0.27, green: 0.27, blue: 0.30),
                        in: RoundedRectangle(cornerRadius: 5,
                                             style: .continuous))
    }
}

private struct DemoContextMenu: View {
    let compareHighlighted: Bool

    var body: some View {
        VStack(spacing: 0) {
            menuRow("rectangle.on.rectangle.angled", "Add to Collection", trailing: "›")
            menuRow("rectangle.split.2x1", "Compare Side by Side",
                    highlighted: compareHighlighted)
            Rectangle().fill(DemoColor.line).frame(height: 1).padding(.vertical, 3)
            menuRow("line.3.horizontal.decrease.circle", "New Smart Collection…")
        }
        .padding(5)
        .background(Color(red: 0.204, green: 0.204, blue: 0.228).opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 15, y: 8)
    }

    private func menuRow(_ symbol: String, _ title: String,
                         trailing: String? = nil, highlighted: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).frame(width: 11)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let trailing { Text(trailing).foregroundStyle(DemoColor.muted) }
        }
        .font(.system(size: 8))
        .foregroundStyle(highlighted ? Color.white : DemoColor.text)
        .padding(.horizontal, 7)
        .frame(height: 25)
        .background(highlighted ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct ShareDemo: View {
    let time: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let menuOpacity = windowOpacity(time, 2.05, 2.55, 5.25, 5.85)
            let browserOpacity = windowOpacity(time, 5.45, 6.15, 7.95, 8.4)
            let cursor = shareCursor(in: proxy.size)

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Text(verbatim: "Weekend Away")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                        Text(verbatim: "12")
                            .font(.system(size: 9))
                            .foregroundStyle(DemoColor.muted)
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 26)
                            .background(Color.accentColor,
                                        in: RoundedRectangle(cornerRadius: 7,
                                                             style: .continuous))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 43)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(DemoColor.line).frame(height: 1)
                    }

                    DemoPhotoGrid()
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                        .padding(.bottom, 12)
                }

                DemoShareMenu(publishHighlighted: time >= 4.05 && time <= 5.35)
                    .frame(width: 132)
                    .padding(.top, 34)
                    .padding(.trailing, 11)
                    .opacity(menuOpacity)
                    .scaleEffect(0.94 + 0.06 * menuOpacity, anchor: .topTrailing)

                DemoPublishedSite()
                    .padding(.horizontal, 17)
                    .padding(.top, 10)
                    .padding(.bottom, 13)
                    .opacity(browserOpacity)
                    .offset(y: (1 - browserOpacity) * 18)
                    .scaleEffect(0.97 + 0.03 * browserOpacity)

                if cursor.opacity > 0 {
                    DemoPointer()
                        .opacity(cursor.opacity)
                        .position(cursor.position)
                }

                Circle()
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .scaleEffect(clickScale(time, 1.9, 2.5))
                    .opacity(clickOpacity(time, 1.9, 2.5))
                    .position(x: proxy.size.width - 26, y: 22)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func shareCursor(in size: CGSize) -> (position: CGPoint, opacity: CGFloat) {
        let start = CGPoint(x: size.width - 45, y: size.height - 20)
        let share = CGPoint(x: size.width - 23, y: 26)
        let publish = CGPoint(x: size.width - 76, y: 109)
        let opacity = windowOpacity(time, 0.65, 0.95, 5.1, 5.6)
        if time < 1.9 {
            return (interpolate(start, share, ramp(time, 0.95, 1.9)), opacity)
        }
        if time < 3.1 { return (share, opacity) }
        return (interpolate(share, publish, ramp(time, 3.1, 4.25)), opacity)
    }
}

private struct DemoShareMenu: View {
    let publishHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "SHARE COLLECTION")
                .font(.system(size: 6.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.60))
                .padding(.horizontal, 7)
                .frame(height: 24)
            shareRow("doc", "Save as PDF")
            shareRow("square.and.arrow.down", "Export Images")
            shareRow("globe", "Publish Website", highlighted: publishHighlighted)
        }
        .padding(5)
        .background(Color(red: 0.204, green: 0.204, blue: 0.228).opacity(0.98),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 15, y: 8)
    }

    private func shareRow(_ symbol: String, _ title: String,
                          highlighted: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).frame(width: 11)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 8))
        .foregroundStyle(highlighted ? Color.white : DemoColor.text)
        .padding(.horizontal, 7)
        .frame(height: 25)
        .background(highlighted ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct DemoPublishedSite: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Circle().fill(Color(red: 0.76, green: 0.76, blue: 0.75)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.76, green: 0.76, blue: 0.75)).frame(width: 6, height: 6)
                Circle().fill(Color(red: 0.76, green: 0.76, blue: 0.75)).frame(width: 6, height: 6)
                Text(verbatim: "muse-share.pages.dev")
                    .font(.system(size: 6.5))
                    .foregroundStyle(Color(red: 0.46, green: 0.46, blue: 0.46))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Color(red: 0.91, green: 0.91, blue: 0.90))

            HStack {
                Text(verbatim: "Weekend Away")
                    .font(.system(size: 9, weight: .semibold))
                Spacer()
                Text(verbatim: "Shared with Muse")
                    .font(.system(size: 6))
                    .foregroundStyle(Color.gray)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)

            DemoPhotoGrid()
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
        }
        .foregroundStyle(Color(red: 0.13, green: 0.13, blue: 0.14))
        .background(Color(red: 0.97, green: 0.97, blue: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 17, y: 9)
    }
}

private struct DemoPhotoGrid: View {
    var selected: Set<Int> = []

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 7
            let width = max(1, (proxy.size.width - gap * 2) / 3)
            let height = max(1, (proxy.size.height - gap) / 2)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: gap), count: 3),
                      spacing: gap) {
                ForEach(Array(DemoPhoto.allCases.enumerated()), id: \.offset) { index, photo in
                    Image(photo.rawValue)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6,
                                                    style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(selected.contains(index)
                                              ? Color.accentColor
                                              : Color.white.opacity(0.05),
                                              lineWidth: selected.contains(index) ? 3 : 1)
                        }
                }
            }
        }
    }
}

private struct DemoPointer: View {
    var body: some View {
        PointerShape()
            .fill(.white)
            .overlay { PointerShape().stroke(Color.black.opacity(0.9), lineWidth: 1) }
            .frame(width: 16, height: 20)
            .shadow(color: .black.opacity(0.55), radius: 2, y: 2)
    }
}

private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.86))
        path.addLine(to: CGPoint(x: rect.width * 0.24, y: rect.height * 0.64))
        path.addLine(to: CGPoint(x: rect.width * 0.40, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.56, y: rect.height * 0.92))
        path.addLine(to: CGPoint(x: rect.width * 0.39, y: rect.height * 0.58))
        path.addLine(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.58))
        path.closeSubpath()
        return path
    }
}

private enum DemoPhoto: String, CaseIterable {
    case alpine = "OnboardingAlpine"
    case portrait = "OnboardingPortrait"
    case bridge = "OnboardingBridge"
    case flowers = "OnboardingFlowers"
    case volcano = "OnboardingVolcano"
    case waterfall = "OnboardingWaterfall"
}

private func ramp(_ value: TimeInterval, _ start: TimeInterval,
                  _ end: TimeInterval) -> CGFloat {
    guard end > start else { return value >= end ? 1 : 0 }
    return CGFloat(min(1, max(0, (value - start) / (end - start))))
}

private func windowOpacity(_ value: TimeInterval,
                           _ fadeInStart: TimeInterval,
                           _ fullStart: TimeInterval,
                           _ fullEnd: TimeInterval,
                           _ fadeOutEnd: TimeInterval) -> CGFloat {
    if value < fullStart { return ramp(value, fadeInStart, fullStart) }
    if value <= fullEnd { return 1 }
    return 1 - ramp(value, fullEnd, fadeOutEnd)
}

private func interpolate(_ from: CGPoint, _ to: CGPoint, _ progress: CGFloat) -> CGPoint {
    CGPoint(x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress)
}

private func clickOpacity(_ value: TimeInterval, _ start: TimeInterval,
                          _ end: TimeInterval) -> CGFloat {
    let midpoint = start + (end - start) * 0.35
    if value <= midpoint { return ramp(value, start, midpoint) * 0.85 }
    return (1 - ramp(value, midpoint, end)) * 0.85
}

private func clickScale(_ value: TimeInterval, _ start: TimeInterval,
                        _ end: TimeInterval) -> CGFloat {
    0.25 + ramp(value, start, end) * 1.15
}

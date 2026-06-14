//
//  AssetKind.swift
//  Muse
//
//  Classification of a file used to pick the right viewer and to drive
//  filtering. Detection is by extension first, content sniffing
//  (UTType / magic bytes) as a tiebreak when extension is missing.
//

import Foundation
import UniformTypeIdentifiers

enum AssetKind: String, Codable, Equatable, Hashable, CaseIterable {
    case image
    case raw
    case psd
    case svg
    case pdf
    case text
    case markdown
    case code
    case office
    case video
    case audio
    case model3d
    case font
    case archive
    case folder
    case unknown

    /// Whether this kind is something Muse can render natively.
    var hasNativeViewer: Bool {
        switch self {
        case .folder, .unknown: return false
        default: return true
        }
    }
}

extension AssetKind {
    /// Map a URL to an AssetKind. Folders detected first, then by file extension,
    /// then by UTType conformance for files without a recognizable extension.
    nonisolated static func detect(at url: URL) -> AssetKind {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            // .app, .photoslibrary, .pages, etc. — opaque bundles per Q33
            if isOpaqueBundle(url: url) {
                return classify(url: url, fallback: .unknown)
            }
            return .folder
        }
        return classify(url: url, fallback: .unknown)
    }

    nonisolated static func classify(url: URL, fallback: AssetKind) -> AssetKind {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            return classifyByUTType(url: url, fallback: fallback)
        }
        if let byExt = byExtension[ext] {
            return byExt
        }
        return classifyByUTType(url: url, fallback: fallback)
    }

    private nonisolated static func classifyByUTType(url: URL, fallback: AssetKind) -> AssetKind {
        guard let type = UTType(filenameExtension: url.pathExtension) ?? typeFromContent(url: url) else {
            return fallback
        }
        if type.conforms(to: .rawImage) { return .raw }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .plainText) { return .text }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .font) { return .font }
        return fallback
    }

    private nonisolated static func typeFromContent(url: URL) -> UTType? {
        try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
    }

    /// macOS package directories that should be treated as opaque files (don't descend).
    private nonisolated static func isOpaqueBundle(url: URL) -> Bool {
        let bundleExts: Set<String> = [
            "app", "photoslibrary", "rtfd", "pages", "numbers", "key",
            "framework", "bundle", "kext", "xcassets", "lproj", "pkg", "mpkg",
            "logicx", "garageband", "aplibrary", "fcpbundle", "musiclibrary"
        ]
        return bundleExts.contains(url.pathExtension.lowercased())
    }

    nonisolated static let byExtension: [String: AssetKind] = {
        var map: [String: AssetKind] = [:]
        let mapping: [(AssetKind, [String])] = [
            (.image,    ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "ico"]),
            (.raw,      ["cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf", "srw", "pef"]),
            (.psd,      ["psd"]),
            (.svg,      ["svg"]),
            (.pdf,      ["pdf"]),
            (.text,     ["txt", "log", "csv", "tsv"]),
            (.markdown, ["md", "markdown", "mdown", "mkd"]),
            (.code,     ["swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "cpp", "cc", "c", "h", "hpp",
                         "json", "yaml", "yml", "toml", "html", "htm", "css", "scss", "sass", "rb", "java",
                         "kt", "sh", "zsh", "bash", "fish", "metal", "glsl", "hlsl", "swiftpm", "swiftinterface"]),
            (.office,   ["rtf", "rtfd", "docx", "doc", "pages", "odt"]),
            (.video,    ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv"]),
            (.audio,    ["mp3", "wav", "aac", "m4a", "flac", "ogg", "opus", "aiff"]),
            (.model3d,  ["usdz", "usda", "usdc", "obj", "stl", "ply", "dae"]),
            (.font,     ["ttf", "otf", "woff", "woff2"]),
            (.archive,  ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z"]),
        ]
        for (kind, exts) in mapping {
            for ext in exts { map[ext] = kind }
        }
        return map
    }()
}

# Hero INFO Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic **INFO** card to the hero viewer's info column that surfaces a file's extra metadata (photo EXIF, PDF document properties, A/V duration), read on viewer-open with no DB storage, hidden entirely when the file has nothing extra to show.

**Architecture:** A pure, unit-tested `FileMetadata` core turns raw header dictionaries (CGImageSource EXIF/TIFF/GPS, PDFKit attributes) into ordered `InfoRow` label/value pairs plus an optional coordinate. A thin IO loader (`FileMetadata.load`) reads the headers off-main per `AssetKind` and delegates formatting to the pure core. `ViewerInfoColumn` renders a new `infoCard` below COLORS (gated on non-empty rows) with a text-only "Open in Maps" hand-off; `HeroImageViewer` loads the metadata alongside its existing `details`/palette load and passes it in.

**Tech Stack:** Swift, SwiftUI, AppKit, ImageIO (`CGImageSource`), PDFKit, AVFoundation, GRDB (existing), XCTest.

## Global Constraints

- **No network.** Location is **text coordinates + an "Open in Maps" button** (`maps://` via `NSWorkspace`). No `MKMapSnapshotter` / inline map — it fetches remote tiles and violates the update-only network policy.
- **No DB column, no migration.** Metadata is read on viewer-open only, mirroring the existing `computedPalette`/`fallbackPalette` pattern.
- **Never read dataless iCloud bytes.** Guard header reads with the dataless check (mirror `AssetKind.isDataless`: `.ubiquitousItemDownloadingStatusKey == .notDownloaded`) — return empty metadata for a not-downloaded placeholder; never force a download.
- **Card hides when empty.** If `rows.isEmpty`, the INFO card does not render (no placeholder).
- **No duplication of the subtitle line.** The subtitle already shows size · pixel dimensions · modified date; INFO must not repeat those.
- **Hero viewer only.** No grid/file-card metadata; non-hero `ViewerChrome` fallback unchanged.
- **Test command:** `xcodebuild -scheme Muse test` (full suite). Single class: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`. Build only: `xcodebuild -scheme Muse build`.
- **Pure logic is unit-tested; SwiftUI/AppKit views and CG/IO layers are not** (project convention).
- Card uses the existing `InfoCard`/`CardLabel` visual language in `ViewerInfoColumn.swift`. Column width is unchanged (`258 + 24`).

---

## File Structure

- **Create** `Muse/Muse/Viewers/FileMetadata.swift` — `InfoRow`, `FileMetadata`, the pure formatting functions, and the IO `load(url:kind:)` loader.
- **Create** `Muse/MuseTests/FileMetadataTests.swift` — tests for the pure formatting functions only.
- **Modify** `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` — add a `metadata: FileMetadata?` property, the `infoCard` view, and an "Open in Maps" button; insert the card between the colors card and the actions row.
- **Modify** `Muse/Muse/Views/Viewer/HeroImageViewer.swift` — add a `@State private var metadata: FileMetadata?`, load it in `loadDetails()`, and pass it into `ViewerInfoColumn`.

> Note: `Viewers/` (singular file viewers like `PDFViewerView.swift`, `FontViewerView.swift`) is where cross-viewer helpers belong; `FileMetadata` is consumed by the hero info column and conceptually about any file's metadata, so it lives there.

---

## Task 1: Pure `FileMetadata` core — image (EXIF/TIFF/GPS) formatting

**Files:**
- Create: `Muse/Muse/Viewers/FileMetadata.swift`
- Test: `Muse/MuseTests/FileMetadataTests.swift`

**Interfaces:**
- Consumes: nothing (new).
- Produces:
  - `struct InfoRow: Identifiable, Equatable { let id: UUID; let label: String; let value: String; init(_ label: String, _ value: String) }`
  - `struct FileMetadata: Equatable { var rows: [InfoRow]; var coordinate: Coordinate?; static let empty: FileMetadata }`
  - `struct Coordinate: Equatable { let lat: Double; let long: Double }`
  - `enum FileMetadata` static pure helpers:
    - `static func imageMetadata(exif: [String: Any], tiff: [String: Any], gps: [String: Any]) -> FileMetadata`
    - `static func formatTakenDate(_ raw: String?) -> String?`
    - `static func formatExposure(fNumber: Double?, exposureTime: Double?, iso: Int?) -> String?`
    - `static func coordinate(latitude: Double?, latRef: String?, longitude: Double?, longRef: String?) -> Coordinate?`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/FileMetadataTests.swift`:

```swift
import XCTest
@testable import Muse

final class FileMetadataTests: XCTestCase {

    // MARK: formatTakenDate
    func testTakenDateParsesExifFormat() {
        // EXIF DateTimeOriginal is "yyyy:MM:dd HH:mm:ss".
        let s = FileMetadata.formatTakenDate("2026:06:14 15:42:31")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("2026"), "expected year in \(s!)")
    }
    func testTakenDateNilOnGarbageOrNil() {
        XCTAssertNil(FileMetadata.formatTakenDate(nil))
        XCTAssertNil(FileMetadata.formatTakenDate("not a date"))
    }

    // MARK: formatExposure
    func testExposureFullTriple() {
        let s = FileMetadata.formatExposure(fNumber: 1.8, exposureTime: 1.0/120.0, iso: 64)
        XCTAssertEqual(s, "ƒ1.8 · 1/120 · ISO 64")
    }
    func testExposurePartial() {
        let s = FileMetadata.formatExposure(fNumber: 2.8, exposureTime: nil, iso: nil)
        XCTAssertEqual(s, "ƒ2.8")
    }
    func testExposureNilWhenEmpty() {
        XCTAssertNil(FileMetadata.formatExposure(fNumber: nil, exposureTime: nil, iso: nil))
    }
    func testExposureLongShutterShownAsSeconds() {
        // 0.5s is shown as "1/2" (reciprocal) — sub-second is the common case.
        let s = FileMetadata.formatExposure(fNumber: nil, exposureTime: 0.5, iso: nil)
        XCTAssertEqual(s, "1/2")
    }

    // MARK: coordinate (with hemisphere refs)
    func testCoordinateAppliesSouthWestSigns() {
        let c = FileMetadata.coordinate(latitude: 37.77, latRef: "S",
                                        longitude: 122.41, longRef: "W")
        XCTAssertEqual(c?.lat ?? 0, -37.77, accuracy: 0.001)
        XCTAssertEqual(c?.long ?? 0, -122.41, accuracy: 0.001)
    }
    func testCoordinateNilWhenMissing() {
        XCTAssertNil(FileMetadata.coordinate(latitude: nil, latRef: "N",
                                             longitude: 1.0, longRef: "E"))
    }

    // MARK: imageMetadata (assembly)
    func testImageMetadataBuildsRowsAndCoordinate() {
        let exif: [String: Any] = [
            "DateTimeOriginal": "2026:06:14 15:42:31",
            "FNumber": 1.8,
            "ExposureTime": 1.0/120.0,
            "ISOSpeedRatings": [64],
            "LensModel": "iPhone 15 Pro back camera 6.86mm f/1.78",
        ]
        let tiff: [String: Any] = ["Make": "Apple", "Model": "iPhone 15 Pro"]
        let gps: [String: Any] = [
            "Latitude": 37.77, "LatitudeRef": "N",
            "Longitude": 122.41, "LongitudeRef": "W",
        ]
        let m = FileMetadata.imageMetadata(exif: exif, tiff: tiff, gps: gps)
        let labels = m.rows.map(\.label)
        XCTAssertEqual(labels, ["Taken", "Camera", "Lens", "Exposure", "Location"])
        XCTAssertEqual(m.rows.first(where: { $0.label == "Camera" })?.value, "Apple iPhone 15 Pro")
        XCTAssertEqual(m.rows.first(where: { $0.label == "Exposure" })?.value, "ƒ1.8 · 1/120 · ISO 64")
        XCTAssertNotNil(m.coordinate)
        XCTAssertEqual(m.coordinate?.long ?? 0, -122.41, accuracy: 0.001)
    }
    func testImageMetadataEmptyDictsYieldEmpty() {
        let m = FileMetadata.imageMetadata(exif: [:], tiff: [:], gps: [:])
        XCTAssertTrue(m.rows.isEmpty)
        XCTAssertNil(m.coordinate)
        XCTAssertEqual(m, FileMetadata.empty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`
Expected: FAIL — `Cannot find 'FileMetadata' in scope` (type doesn't exist yet).

- [ ] **Step 3: Write the minimal implementation**

Create `Muse/Muse/Viewers/FileMetadata.swift`:

```swift
//
//  FileMetadata.swift
//  Muse
//
//  Extra per-file metadata shown in the hero viewer's INFO card: photo EXIF
//  (date taken / camera / lens / exposure / location), PDF document properties,
//  and A/V duration. Read on viewer-open only — never persisted (no DB column).
//
//  The formatting is pure (testable from raw header dictionaries); `load`
//  is the thin IO wrapper that reads the headers per AssetKind.
//

import Foundation

struct InfoRow: Identifiable, Equatable {
    let id: UUID
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.id = UUID()
        self.label = label
        self.value = value
    }
    // UUID is per-instance; compare on content so tests are deterministic.
    static func == (a: InfoRow, b: InfoRow) -> Bool {
        a.label == b.label && a.value == b.value
    }
}

struct Coordinate: Equatable {
    let lat: Double
    let long: Double
}

struct FileMetadata: Equatable {
    var rows: [InfoRow]
    var coordinate: Coordinate?

    static let empty = FileMetadata(rows: [], coordinate: nil)

    // MARK: - Pure image formatting

    /// Build INFO rows + coordinate from the three CGImageSource sub-dictionaries.
    /// Keys are the bare suffixes (e.g. "FNumber"), matching the kCGImageProperty
    /// constant names with their prefixes stripped.
    static func imageMetadata(exif: [String: Any], tiff: [String: Any],
                              gps: [String: Any]) -> FileMetadata {
        var rows: [InfoRow] = []

        if let taken = formatTakenDate(exif["DateTimeOriginal"] as? String) {
            rows.append(InfoRow("Taken", taken))
        }
        if let camera = camera(make: tiff["Make"] as? String, model: tiff["Model"] as? String) {
            rows.append(InfoRow("Camera", camera))
        }
        if let lens = (exif["LensModel"] as? String)?.trimmingCharacters(in: .whitespaces),
           !lens.isEmpty {
            rows.append(InfoRow("Lens", lens))
        }
        let iso = (exif["ISOSpeedRatings"] as? [Int])?.first ?? (exif["ISOSpeedRatings"] as? Int)
        if let exposure = formatExposure(fNumber: exif["FNumber"] as? Double,
                                         exposureTime: exif["ExposureTime"] as? Double,
                                         iso: iso) {
            rows.append(InfoRow("Exposure", exposure))
        }
        let coord = coordinate(latitude: gps["Latitude"] as? Double,
                               latRef: gps["LatitudeRef"] as? String,
                               longitude: gps["Longitude"] as? Double,
                               longRef: gps["LongitudeRef"] as? String)
        if let coord {
            rows.append(InfoRow("Location", String(format: "%.4f, %.4f", coord.lat, coord.long)))
        }
        return FileMetadata(rows: rows, coordinate: coord)
    }

    private static func camera(make: String?, model: String?) -> String? {
        let m = make?.trimmingCharacters(in: .whitespaces)
        let mod = model?.trimmingCharacters(in: .whitespaces)
        switch (m, mod) {
        case let (m?, mod?) where !m.isEmpty && !mod.isEmpty:
            // Avoid "Apple Apple ..." when the model already starts with the make.
            return mod.hasPrefix(m) ? mod : "\(m) \(mod)"
        case let (m?, _) where !m.isEmpty: return m
        case let (_, mod?) where !mod.isEmpty: return mod
        default: return nil
        }
    }

    static func formatTakenDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    static func formatExposure(fNumber: Double?, exposureTime: Double?, iso: Int?) -> String? {
        var parts: [String] = []
        if let f = fNumber {
            // Trim trailing ".0" (ƒ2 not ƒ2.0); keep one decimal otherwise.
            let s = f == f.rounded() ? String(format: "ƒ%.0f", f) : String(format: "ƒ%.1f", f)
            parts.append(s)
        }
        if let t = exposureTime, t > 0 {
            if t >= 1 {
                parts.append(String(format: "%gs", t))
            } else {
                parts.append("1/\(Int((1.0 / t).rounded()))")
            }
        }
        if let iso { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func coordinate(latitude: Double?, latRef: String?,
                           longitude: Double?, longRef: String?) -> Coordinate? {
        guard let lat = latitude, let long = longitude else { return nil }
        let signedLat = (latRef?.uppercased() == "S") ? -abs(lat) : lat
        let signedLong = (longRef?.uppercased() == "W") ? -abs(long) : long
        return Coordinate(lat: signedLat, long: signedLong)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`
Expected: PASS (all 9 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Viewers/FileMetadata.swift Muse/MuseTests/FileMetadataTests.swift
git commit -m "feat: FileMetadata pure image (EXIF/TIFF/GPS) formatting + tests"
```

---

## Task 2: Pure PDF + duration formatting

**Files:**
- Modify: `Muse/Muse/Viewers/FileMetadata.swift`
- Test: `Muse/MuseTests/FileMetadataTests.swift`

**Interfaces:**
- Consumes: `FileMetadata`, `InfoRow` (Task 1).
- Produces:
  - `static func pdfMetadata(pageCount: Int, attributes: [String: Any]) -> FileMetadata`
  - `static func formatDuration(_ seconds: Double?) -> String?`
  - `static func mediaMetadata(durationSeconds: Double?) -> FileMetadata`

- [ ] **Step 1: Write the failing tests**

Append to `Muse/MuseTests/FileMetadataTests.swift` (inside the class):

```swift
    // MARK: pdfMetadata
    func testPDFMetadataRowsInOrder() {
        let attrs: [String: Any] = [
            "Title": "Quarterly Report",
            "Author": "Jane Doe",
            "Creator": "Pages",
        ]
        let m = FileMetadata.pdfMetadata(pageCount: 12, attributes: attrs)
        XCTAssertEqual(m.rows.map(\.label), ["Pages", "Title", "Author", "Creator"])
        XCTAssertEqual(m.rows.first?.value, "12")
        XCTAssertNil(m.coordinate)
    }
    func testPDFMetadataPagesOnlyWhenNoAttrs() {
        let m = FileMetadata.pdfMetadata(pageCount: 3, attributes: [:])
        XCTAssertEqual(m.rows.map(\.label), ["Pages"])
    }
    func testPDFMetadataSkipsBlankAttrs() {
        let m = FileMetadata.pdfMetadata(pageCount: 1, attributes: ["Title": "", "Author": "  "])
        XCTAssertEqual(m.rows.map(\.label), ["Pages"])
    }

    // MARK: formatDuration / mediaMetadata
    func testDurationFormatsMinutesSeconds() {
        XCTAssertEqual(FileMetadata.formatDuration(222), "3:42")
        XCTAssertEqual(FileMetadata.formatDuration(5), "0:05")
    }
    func testDurationFormatsHours() {
        XCTAssertEqual(FileMetadata.formatDuration(3661), "1:01:01")
    }
    func testDurationNilOrZero() {
        XCTAssertNil(FileMetadata.formatDuration(nil))
        XCTAssertNil(FileMetadata.formatDuration(0))
    }
    func testMediaMetadataRow() {
        let m = FileMetadata.mediaMetadata(durationSeconds: 222)
        XCTAssertEqual(m.rows, [InfoRow("Duration", "3:42")])
    }
    func testMediaMetadataEmptyWhenNoDuration() {
        XCTAssertEqual(FileMetadata.mediaMetadata(durationSeconds: nil), FileMetadata.empty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`
Expected: FAIL — `Type 'FileMetadata' has no member 'pdfMetadata'` (and `formatDuration`, `mediaMetadata`).

- [ ] **Step 3: Write the minimal implementation**

Add to the `FileMetadata` struct in `Muse/Muse/Viewers/FileMetadata.swift`:

```swift
    // MARK: - Pure PDF formatting

    /// `attributes` keys are the bare PDFDocumentAttribute suffixes
    /// ("Title", "Author", "Creator") — the loader maps PDFKit's keys to these.
    static func pdfMetadata(pageCount: Int, attributes: [String: Any]) -> FileMetadata {
        var rows: [InfoRow] = [InfoRow("Pages", "\(pageCount)")]
        for key in ["Title", "Author", "Creator"] {
            if let v = (attributes[key] as? String)?.trimmingCharacters(in: .whitespaces),
               !v.isEmpty {
                rows.append(InfoRow(key, v))
            }
        }
        return FileMetadata(rows: rows, coordinate: nil)
    }

    // MARK: - Pure media formatting

    static func formatDuration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func mediaMetadata(durationSeconds: Double?) -> FileMetadata {
        guard let d = formatDuration(durationSeconds) else { return .empty }
        return FileMetadata(rows: [InfoRow("Duration", d)], coordinate: nil)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`
Expected: PASS (all tests, Task 1 + Task 2).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Viewers/FileMetadata.swift Muse/MuseTests/FileMetadataTests.swift
git commit -m "feat: FileMetadata pure PDF + duration formatting + tests"
```

---

## Task 3: IO loader `FileMetadata.load(url:kind:)`

**Files:**
- Modify: `Muse/Muse/Viewers/FileMetadata.swift`

**Interfaces:**
- Consumes: `FileMetadata.imageMetadata/pdfMetadata/mediaMetadata` (Tasks 1–2), `AssetKind` (existing, `Models/AssetKind.swift`).
- Produces: `static func load(url: URL, kind: AssetKind) async -> FileMetadata`

> No unit test: this is an IO/CG/PDFKit layer (project convention — pure logic only is unit-tested). It's covered by the Task 1–2 pure tests plus the manual verification in Task 5.

- [ ] **Step 1: Add the imports and loader**

At the top of `Muse/Muse/Viewers/FileMetadata.swift`, extend the imports:

```swift
import Foundation
import ImageIO
import PDFKit
import AVFoundation
```

Add to the `FileMetadata` struct:

```swift
    // MARK: - IO loader (not unit-tested: CG/PDFKit/AVFoundation layer)

    /// Read header metadata off-main for `url`, dispatched by `kind`. Returns
    /// `.empty` for kinds without extra metadata, for dataless iCloud
    /// placeholders (never forces a download), and on any read failure.
    static func load(url: URL, kind: AssetKind) async -> FileMetadata {
        // Never read bytes of a not-yet-downloaded iCloud file (mirrors
        // AssetKind.isDataless / the Indexer dataless rule).
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            return .empty
        }
        return await Task.detached(priority: .userInitiated) { () -> FileMetadata in
            switch kind {
            case .image, .raw, .psd:
                return loadImage(url: url)
            case .pdf:
                return loadPDF(url: url)
            case .video, .audio:
                return loadMedia(url: url)
            default:
                return .empty
            }
        }.value
    }

    private static func loadImage(url: URL) -> FileMetadata {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return .empty }
        // Strip the kCGImageProperty*<Group>* prefixes so the pure functions see
        // bare keys ("FNumber", "Make", "Latitude").
        func sub(_ key: CFString) -> [String: Any] {
            guard let dict = props[key] as? [CFString: Any] else { return [:] }
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k as String] = v }
            return out
        }
        return imageMetadata(exif: sub(kCGImagePropertyExifDictionary),
                             tiff: sub(kCGImagePropertyTIFFDictionary),
                             gps: sub(kCGImagePropertyGPSDictionary))
    }

    private static func loadPDF(url: URL) -> FileMetadata {
        guard let doc = PDFDocument(url: url) else { return .empty }
        let raw = doc.documentAttributes ?? [:]
        var attrs: [String: Any] = [:]
        // PDFKit keys are PDFDocumentAttribute (e.g. .titleAttribute) → bare names.
        if let t = raw[PDFDocumentAttribute.titleAttribute] { attrs["Title"] = t }
        if let a = raw[PDFDocumentAttribute.authorAttribute] { attrs["Author"] = a }
        if let c = raw[PDFDocumentAttribute.creatorAttribute] { attrs["Creator"] = c }
        return pdfMetadata(pageCount: doc.pageCount, attributes: attrs)
    }

    private static func loadMedia(url: URL) -> FileMetadata {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return mediaMetadata(durationSeconds: seconds.isFinite ? seconds : nil)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`. (No new test; the loader delegates to the already-tested pure functions.)

- [ ] **Step 3: Run the full unit suite (no regressions)**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMetadataTests`
Expected: PASS (unchanged from Task 2).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Viewers/FileMetadata.swift
git commit -m "feat: FileMetadata.load IO wrapper (ImageIO/PDFKit/AVFoundation) with dataless guard"
```

---

## Task 4: Render the INFO card in `ViewerInfoColumn`

**Files:**
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`

**Interfaces:**
- Consumes: `FileMetadata`, `InfoRow`, `Coordinate` (Tasks 1–3); existing `InfoCard`, `CardLabel` (same file).
- Produces: a `metadata: FileMetadata?` property on `ViewerInfoColumn` (consumed by Task 5).

> No unit test: SwiftUI view (project convention). Verified by build here + manual checks in Task 5.

- [ ] **Step 1: Add the `metadata` property**

In `ViewerInfoColumn` (after the `paletteLoading` property, around line 24), add:

```swift
    /// Extra file metadata (EXIF / PDF / A/V) shown in the INFO card. Loaded by
    /// the hero viewer on open; nil/empty → the card is omitted.
    var metadata: FileMetadata? = nil
```

- [ ] **Step 2: Insert the card into the body**

In `body`, the content `VStack` currently ends with the colors card then `actionsRow`. Insert the INFO card between them. Change:

```swift
                if !displayPalette.isEmpty {
                    colorsCard(palette: displayPalette)
                } else if paletteLoading {
                    colorsPlaceholderCard
                }
                actionsRow
```

to:

```swift
                if !displayPalette.isEmpty {
                    colorsCard(palette: displayPalette)
                } else if paletteLoading {
                    colorsPlaceholderCard
                }
                if let metadata, !metadata.rows.isEmpty {
                    infoCard(metadata)
                }
                actionsRow
```

- [ ] **Step 3: Add the `infoCard` view**

Add this private method to `ViewerInfoColumn` (next to `colorsCard`):

```swift
    // MARK: - Info card

    private func infoCard(_ metadata: FileMetadata) -> some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 8) {
                CardLabel(text: "INFO")
                ForEach(metadata.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.42))
                            .frame(width: 64, alignment: .leading)
                        Text(row.value)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let coord = metadata.coordinate {
                    HoverTextButton(label: "Open in Maps") {
                        let u = "maps://?ll=\(coord.lat),\(coord.long)"
                        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
                    }
                    .padding(.top, 2)
                    .accessibilityLabel("Open location in Maps")
                }
            }
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/Viewer/ViewerInfoColumn.swift
git commit -m "feat: INFO card in ViewerInfoColumn (rows + Open in Maps, hidden when empty)"
```

---

## Task 5: Load metadata in `HeroImageViewer` and pass it in

**Files:**
- Modify: `Muse/Muse/Views/Viewer/HeroImageViewer.swift`

**Interfaces:**
- Consumes: `FileMetadata.load(url:kind:)` (Task 3), `ViewerInfoColumn.metadata` (Task 4), `AssetKind.detect(at:)` (existing).
- Produces: the wired-up feature (terminal task).

> No unit test: view wiring (project convention). Verified by build + manual checks below.

- [ ] **Step 1: Add the state property**

After `@State private var details: ViewerFileDetails?` (around line 21), add:

```swift
    /// Extra metadata (EXIF / PDF / A/V) for the current file's INFO card.
    @State private var metadata: FileMetadata?
```

- [ ] **Step 2: Load it in `loadDetails()`**

In `loadDetails()`, after the existing `guard url == currentURL else { return }` / `details = loaded` lines (around line 429–430), add the metadata load. It's keyed on the same `currentURL` guard so a fast flip doesn't apply stale data:

```swift
        // Extra metadata for the INFO card (off-main, no DB). Derive the kind
        // from the live URL (navigation changes currentURL, not `file`).
        let kind = AssetKind.detect(at: url)
        let meta = await FileMetadata.load(url: url, kind: kind)
        if url == currentURL { metadata = meta }
```

- [ ] **Step 3: Pass it into `ViewerInfoColumn`**

In `rightRail`, add the `metadata` argument to the `ViewerInfoColumn(...)` call (after `paletteLoading:`, around line 177):

```swift
        ViewerInfoColumn(url: currentURL,
                         details: details,
                         fallbackPalette: computedPalette,
                         paletteLoading: !paletteResolved,
                         metadata: metadata,
                         backing: infoBackingColor,
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full unit suite**

Run: `xcodebuild -scheme Muse test`
Expected: `** TEST SUCCEEDED **` (existing suite + the new `FileMetadataTests`).

- [ ] **Step 6: Manual verification (run the app)**

Build & run (Cmd+R). Then:
1. Open a **photo with EXIF** in the hero (e.g. a real camera/phone JPEG) → INFO card shows Taken / Camera / Lens / Exposure, and Location + "Open in Maps" if geotagged. Click "Open in Maps" → Maps.app opens at the coordinates. **Confirm no network call from Muse itself** (the hand-off is to Maps.app).
2. Open a **PDF** → INFO card shows Pages + any Title/Author/Creator.
3. Open a **video** → INFO card shows Duration.
4. Open a **plain screenshot / a PNG with no EXIF** → **no INFO card** (and no empty placeholder; the actions row sits directly under COLORS).
5. **Navigate** with arrow keys between mixed files → the card updates/disappears correctly per file (no stale rows from the previous file).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/Viewer/HeroImageViewer.swift
git commit -m "feat: load FileMetadata on hero open and feed the INFO card"
```

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-06-20-hero-info-card-design.md`):
- Generic "INFO" card under COLORS, existing card styling → Task 4. ✓
- Type-adaptive rows (image EXIF / PDF / A/V) → Tasks 1–3. ✓
- Card hidden when no extra metadata → Task 4 (`!metadata.rows.isEmpty` gate); tested empty-dict path Tasks 1–2. ✓
- On-open extraction, no DB / migration → Tasks 3, 5. ✓
- Location text-only + Open in Maps, no inline map → Task 4. ✓
- Dataless iCloud guard → Task 3. ✓
- No subtitle duplication (size/dims/modified excluded; INFO carries Taken/Camera/Lens/Exposure/Location/Pages/Duration only) → Tasks 1–2. ✓
- Hero-only, no grid/non-hero changes → scope respected (only the three files). ✓
- `FileMetadataTests` pure tests; views/IO not unit-tested → Tasks 1–2 tests, Tasks 3–5 build+manual. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full code; commands have expected output. ✓

**3. Type consistency:** `FileMetadata`, `InfoRow(_:_:)`, `Coordinate`, `FileMetadata.empty`, `imageMetadata(exif:tiff:gps:)`, `pdfMetadata(pageCount:attributes:)`, `mediaMetadata(durationSeconds:)`, `formatTakenDate`, `formatExposure(fNumber:exposureTime:iso:)`, `formatDuration`, `coordinate(latitude:latRef:longitude:longRef:)`, `load(url:kind:)` are used identically across tasks. `ViewerInfoColumn.metadata` (Task 4) matches the argument passed in Task 5. `AssetKind.detect(at:)` matches the existing API. ✓

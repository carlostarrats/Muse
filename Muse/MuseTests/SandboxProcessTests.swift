//
//  SandboxProcessTests.swift
//  MuseTests
//
//  Runtime answer to a question static review cannot settle: may this
//  SANDBOXED app exec `/usr/bin/unzip`?
//
//  `ClipModelStore.unzip` shells out to it, so if the sandbox denies the exec
//  the CLIP model can never install and every Spec 03 semantic-search feature
//  is dead on arrival behind a fail-closed error message. The test host IS the
//  app, with the app's entitlements, so this exercises the real posture.
//
//  If this ever starts failing, the fix is a built-in ZIP reader — a
//  third-party dependency is not an option (DECIDED #26).
//

import XCTest
@testable import Muse

final class SandboxProcessTests: XCTestCase {

    func testSandboxedAppCanExecUnzipIntoItsContainer() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("unzip-probe-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Build a real archive with /usr/bin/zip is a second exec question, so
        // the fixture is a hand-written minimal ZIP: one stored (uncompressed)
        // entry named "hello.txt" containing "hi".
        let zipURL = dir.appendingPathComponent("probe.zip")
        try Self.storedZip(name: "hello.txt", contents: Data("hi".utf8)).write(to: zipURL)

        let out = dir.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", out.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "the sandbox refused /usr/bin/unzip — ClipModelStore.unzip cannot work")
        let unpacked = out.appendingPathComponent("hello.txt")
        XCTAssertEqual(try? String(contentsOf: unpacked, encoding: .utf8), "hi")
    }

    /// Minimal ZIP with a single STORED entry — no compression, so no
    /// dependency and no second exec is needed to build the fixture.
    private static func storedZip(name: String, contents: Data) -> Data {
        let nameBytes = Array(name.utf8)
        let crc = crc32(contents)
        var out = Data()

        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        // Local file header
        out += u32(0x0403_4b50)
        out += u16(10) + u16(0) + u16(0)          // version, flags, method (stored)
        out += u16(0) + u16(0)                    // mod time, mod date
        out += u32(crc) + u32(UInt32(contents.count)) + u32(UInt32(contents.count))
        out += u16(UInt16(nameBytes.count)) + u16(0)
        out += Data(nameBytes)
        let localHeaderSize = out.count
        out += contents

        // Central directory
        let centralStart = out.count
        out += u32(0x0201_4b50)
        out += u16(10) + u16(10) + u16(0) + u16(0)
        out += u16(0) + u16(0)
        out += u32(crc) + u32(UInt32(contents.count)) + u32(UInt32(contents.count))
        out += u16(UInt16(nameBytes.count)) + u16(0) + u16(0)
        out += u16(0) + u16(0) + u32(0) + u32(0)
        out += Data(nameBytes)
        let centralSize = out.count - centralStart
        _ = localHeaderSize

        // End of central directory
        out += u32(0x0605_4b50)
        out += u16(0) + u16(0) + u16(1) + u16(1)
        out += u32(UInt32(centralSize)) + u32(UInt32(centralStart)) + u16(0)
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

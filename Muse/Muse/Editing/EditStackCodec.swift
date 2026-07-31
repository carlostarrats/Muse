//
//  EditStackCodec.swift
//  Muse
//
//  Canonical bytes for an edit stack, and the hash derived from them.
//
//  "Canonical" = `.sortedKeys` JSON of the NORMALIZED stack. That is what
//  makes `stack_hash` stable: the same parameters always produce the same
//  bytes regardless of how the stack was assembled, so the thumbnail cache
//  key for an edited file is deterministic across launches and devices.
//  `EditStackCodecTests` pins the hash against a literal fixture — if that
//  test fails, every edited thumbnail in every library just re-keyed.
//

import Foundation
import CryptoKit

nonisolated enum EditStackCodec {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func encode(_ stack: EditStack) throws -> String {
        let data = try encoder.encode(stack.normalized())
        return String(decoding: data, as: UTF8.self)
    }

    /// nil for corrupt JSON, an unknown adjustment `type`, or a schemaVersion
    /// beyond ours. Decoding NEVER bumps a version — the returned stack keeps
    /// whatever the blob carried, so re-encoding it is byte-identical.
    ///
    /// A `processVersion` beyond ours DOES decode (so the blob round-trips
    /// untouched); `EditRenderer.canRender` is what refuses to render it.
    static func decode(_ json: String) -> EditStack? {
        guard let data = json.data(using: .utf8),
              let stack = try? JSONDecoder().decode(EditStack.self, from: data),
              stack.schemaVersion <= EditStack.currentSchemaVersion
        else { return nil }
        return stack.normalized()
    }

    /// Full SHA-256 hex of the canonical bytes.
    static func hash(_ stack: EditStack) -> String {
        hashOfRawBytes((try? encode(stack)) ?? "")
    }

    /// Hash a blob we could NOT decode (a stack from a newer schema arriving
    /// via sidecar). It still needs a stable, distinct-from-unedited cache
    /// key, and it must round-trip byte-identical, so the bytes themselves
    /// are the only honest input.
    static func hashOfRawBytes(_ json: String) -> String {
        SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

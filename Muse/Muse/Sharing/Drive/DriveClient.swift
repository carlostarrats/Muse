//
//  DriveClient.swift
//  Muse
//
//  Minimal Google Drive v3 REST client over URLSession — exactly the calls the
//  share flow needs, scoped to drive.file (only files Muse created). Every call
//  carries a fresh access token from GoogleOAuth. TLS-only by construction.
//

import Foundation

@MainActor final class DriveClient {
    enum DriveError: Error { case http(Int), badResponse, notFound }

    private let auth: GoogleOAuth
    init(auth: GoogleOAuth) { self.auth = auth }

    private let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    private let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"

    // MARK: folders

    func createFolder(name: String, parent: String) async throws -> String {
        let meta: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parent],
        ]
        return try await postJSON(filesEndpoint + "?fields=id", meta)
    }

    /// Reuse the stored Muse-root id if it still exists, else create a new one
    /// under My Drive root. (drive.file can't *find* a pre-existing folder it
    /// didn't create, so the caller persists the returned id.)
    func ensureMuseRoot(existingID: String?) async throws -> String {
        if let id = existingID, (try? await folderExists(id: id)) == true { return id }
        return try await createFolder(name: "Muse", parent: "root")
    }

    func folderExists(id: String) async throws -> Bool {
        guard Self.isValidFileID(id) else { throw DriveError.badResponse }
        var req = try await authed("\(filesEndpoint)/\(id)?fields=id,trashed")
        req.httpMethod = "GET"
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return false }
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw DriveError.http(code) }
        return (json["trashed"] as? Bool) != true
    }

    func deleteFolder(id: String) async throws {
        guard Self.isValidFileID(id) else { throw DriveError.badResponse }
        var req = try await authed("\(filesEndpoint)/\(id)")
        req.httpMethod = "DELETE"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 204 || code == 200 || code == 404 else { throw DriveError.http(code) }
    }

    // MARK: files

    /// Takes a `RenderedOutput`, never a bare URL — the render step runs BEFORE
    /// the strip, so a future edit can't reintroduce metadata past the stripper.
    func uploadFile(_ out: RenderedOutput, name: String, mime: String, parent: String) async throws -> String {
        // Strip all private metadata (GPS/EXIF/camera/IPTC/XMP/maker notes)
        // BEFORE upload: the file is made anyone-readable and its id rides the
        // public share URL, so the original — not just the EXIF-free Google
        // thumbnail — is reachable by recipients. Fail-closed (throws) rather
        // than ever upload an un-stripped original. Run off the main actor —
        // decode/re-encode is heavy CPU + memory and DriveClient is @MainActor.
        let stripped = try await Task.detached(priority: .utility) {
            try ImageMetadataStripper.strip(out, mime: mime)
        }.value
        let boundary = "muse-\(UUID().uuidString)"
        var req = try await authed(uploadEndpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            metadata: ["name": name, "parents": [parent]],
            fileData: stripped.data, mime: stripped.mime, boundary: boundary)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = json["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    /// Upload a share's `manifest.json`. NEVER for images — image bytes go
    /// through `uploadFile`'s metadata strip, fail-closed. That's enforced by
    /// the shape of this signature, not by convention: it takes `Data` the
    /// caller already JSON-encoded (there is no file to strip) and pins the mime
    /// internally rather than accepting one.
    func uploadManifest(_ json: Data, parent: String) async throws -> String {
        try await uploadJSON(json, name: "manifest.json", parent: parent)
    }

    /// Upload the tiny live presentation sidecar used by every new share. It
    /// contains only `{ "y": <layout> }`; changing it never touches images.
    func uploadLayoutSettings(_ json: Data, parent: String) async throws -> String {
        try await uploadJSON(json, name: "layout.json", parent: parent)
    }

    private func uploadJSON(_ json: Data, name: String, parent: String) async throws -> String {
        let boundary = "muse-\(UUID().uuidString)"
        var req = try await authed(uploadEndpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            metadata: ["name": name, "parents": [parent]],
            fileData: json, mime: "application/json", boundary: boundary)
        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let id = obj["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    /// Rewrite an existing `manifest.json`'s content in place. The file id — and
    /// therefore the portfolio's URL — never changes, which is what makes this
    /// call the ATOMIC cutover of a portfolio update.
    func updateManifest(id: String, json: Data) async throws {
        guard Self.isValidFileID(id) else { throw DriveError.badResponse }
        var req = try await authed("https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media")
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DriveError.http(code) }
    }

    /// Same media PATCH as a manifest rewrite, named separately at the call
    /// site so a layout-only Manage action cannot be mistaken for image/content
    /// replacement.
    func updateLayoutSettings(id: String, json: Data) async throws {
        try await updateManifest(id: id, json: json)
    }

    /// Build one paginated child-list request. Kept pure so the escaping, fields,
    /// and page-token contract are unit-testable without a live Drive account.
    static func listChildrenURL(of folderID: String, pageToken: String? = nil) throws -> URL {
        guard isValidFileID(folderID) else { throw DriveError.badResponse }
        guard var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
        else { throw DriveError.badResponse }
        comps.queryItems = [
            URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed=false"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        if let pageToken, pageToken.isEmpty == false {
            comps.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        guard let url = comps.url else { throw DriveError.badResponse }
        return url
    }

    /// Children of a folder Muse created (drive.file sees only its own files).
    /// Used by the portfolio update to sweep replaced images. A maximum-size
    /// share has 1,000 images plus manifest.json and layout.json, so it exceeds
    /// Drive's 1,000-item page size and MUST follow `nextPageToken`.
    func listChildren(of folderID: String) async throws -> [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        var pageToken: String?
        var seenTokens: Set<String> = []
        repeat {
            let url = try Self.listChildrenURL(of: folderID, pageToken: pageToken)
            var req = try await authed(url.absoluteString)
            req.httpMethod = "GET"
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = obj["files"] as? [[String: Any]]
            else { throw DriveError.http(code) }
            result.append(contentsOf: files.compactMap { file in
                guard let id = file["id"] as? String,
                      let name = file["name"] as? String else { return nil }
                return (id, name)
            })
            let next = (obj["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let next, seenTokens.insert(next).inserted == false {
                throw DriveError.badResponse // defensive: never loop on a repeated token
            }
            pageToken = next
        } while pageToken != nil
        return result
    }

    func setAnyoneReader(fileID: String) async throws {
        guard Self.isValidFileID(fileID) else { throw DriveError.badResponse }
        var req = try await authed("\(filesEndpoint)/\(fileID)/permissions")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["role": "reader", "type": "anyone"])
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DriveError.http(code) }
    }

    // MARK: helpers

    /// Pure multipart/related body: JSON metadata part + raw file part.
    static func multipartBody(metadata: [String: Any], fileData: Data,
                              mime: String, boundary: String) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        let metaJSON = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data("{}".utf8)
        // Defense-in-depth: `mime` is interpolated raw into a header line, so a
        // CR/LF (or any non-token byte) in it could forge extra headers or a
        // whole extra multipart part. Every caller's mime is currently a UTType-
        // registry value or a hardcoded constant (never CRLF-bearing), but pin it
        // to a strict `type/subtype` token grammar so a future caller can't turn
        // this into a header-injection foothold — anything off-grammar collapses
        // to the neutral default rather than reaching the header.
        let safeMime = isValidMIME(mime) ? mime : "application/octet-stream"
        append("--\(boundary)\r\n")
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(metaJSON); append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Type: \(safeMime)\r\n\r\n")
        body.append(fileData); append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    /// Strict RFC-2045 `type/subtype` token check: rejects CR/LF, whitespace, and
    /// header separators, so an interpolated mime can never inject a header line.
    static func isValidMIME(_ s: String) -> Bool {
        guard (1...255).contains(s.utf8.count) else { return false }
        let token = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        return parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { token.contains($0) }
        }
    }

    /// Drive ids are interpolated into REST paths and the child-list query. All
    /// ids returned by Drive use this URL-safe alphabet; validating records read
    /// from local JSON prevents a corrupted/tampered id from changing the path or
    /// query that a destructive Manage/portfolio action targets.
    static func isValidFileID(_ id: String) -> Bool {
        guard (20...200).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48...57, 65...90, 95, 97...122: return true // - 0-9 A-Z _ a-z
            default: return false
            }
        }
    }

    private func postJSON(_ endpoint: String, _ object: [String: Any]) async throws -> String {
        var req = try await authed(endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: object)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw DriveError.http(code) }
        return id
    }

    private func authed(_ urlString: String) async throws -> URLRequest {
        let token = try await auth.validAccessToken()
        // urlString embeds ids loaded from a local share record; a tampered/
        // corrupt id could make URL(string:) nil, so guard instead of force-unwrap.
        guard let url = URL(string: urlString) else { throw DriveError.badResponse }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}

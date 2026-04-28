//
//  ChatService.swift
//  Muse
//
//  Capability-gated chat panel backend. On Apple Intelligence-capable
//  Macs (macOS 26+), uses Foundation Models with tool calls into the
//  same internal tool registry App Intents uses. Hidden everywhere
//  else per Q9 (no MLX fallback in v1).
//

import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var messages: [ChatMessage] = []
    @Published var isResponding: Bool = false

    /// Whether Foundation Models is usable on this Mac right now.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private init() {}

    func send(_ prompt: String, scopeFolderURL: URL?) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: trimmed))
        isResponding = true
        defer { isResponding = false }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.availability == .available {
            await respondViaFoundationModels(prompt: trimmed, scope: scopeFolderURL)
            return
        }
        #endif
        // Should never hit — UI gate prevents send when unavailable
        messages.append(ChatMessage(role: .assistant, text: "(Apple Intelligence not available on this Mac.)"))
    }

    func clear() {
        messages.removeAll()
    }

    // MARK: - Foundation Models path

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func respondViaFoundationModels(prompt: String, scope: URL?) async {
        // For v1, simple QA without tool calls — we feed the model a
        // pre-baked context summary of the current folder so it can answer
        // questions about it. Tool-call-driven search is a follow-up; the
        // hardest part of that is wiring entity-typed tools, not the chat
        // surface itself.

        let session = LanguageModelSession(instructions: Self.systemInstructions)
        let context = await Self.buildContext(scope: scope)
        let composed = "\(context)\n\nUser question: \(prompt)"

        do {
            let response = try await session.respond(to: composed)
            messages.append(ChatMessage(role: .assistant, text: response.content))
        } catch {
            messages.append(ChatMessage(role: .assistant, text: "Error: \(error.localizedDescription)"))
        }
    }

    private static let systemInstructions = """
    You are an assistant that helps a user explore the contents of a single
    folder of files on their Mac. You are given a structured summary of the
    folder's files (basename, kind, tags, captions). Answer the user's
    question concisely using only this context. Never invent files or
    contents that aren't in the summary. If you cannot answer from the
    summary, say so.
    """

    private static func buildContext(scope: URL?) async -> String {
        guard let scope else { return "Folder context: (none — no folder is currently open)." }
        let files = FolderReader.files(in: scope, showHidden: false).prefix(80)
        if files.isEmpty {
            return "Folder \(scope.lastPathComponent) is empty."
        }
        var lines: [String] = ["Folder: \(scope.lastPathComponent)"]
        for f in files {
            let tags = await TagStore.shared.tags(for: f.url).map { $0.label }.joined(separator: ", ")
            let line = "- \(f.basename) [\(f.kind.rawValue)]" + (tags.isEmpty ? "" : " tags: \(tags)")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
    #endif
}

struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

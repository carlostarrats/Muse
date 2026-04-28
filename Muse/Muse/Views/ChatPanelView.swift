//
//  ChatPanelView.swift
//  Muse
//
//  Right-side chat panel — only ever shown when ChatService.isAvailable.
//  Hidden completely on Macs without Apple Intelligence.
//

import SwiftUI

struct ChatPanelView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var chat = ChatService.shared

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask Muse")
                    .font(.headline)
                Spacer()
                Button {
                    chat.clear()
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Clear conversation")
                Button {
                    appState.chatPanelVisible = false
                } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                        if chat.isResponding {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 12)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about this folder…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { submit() }
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.isResponding)
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .frame(width: 18)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 12)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(.white)
            }
        }
    }

    private func submit() {
        let prompt = draft
        draft = ""
        let scope = appState.selectedFolder?.url
        Task { await chat.send(prompt, scopeFolderURL: scope) }
    }
}

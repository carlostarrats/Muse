//
//  ViewerToast.swift
//  Muse
//
//  Bottom-center capsule toast for the hero viewer: a message plus an
//  optional action ("Undo"). Auto-dismisses after 3.5s when it carries an
//  action, 1.4s when it's purely informational.
//

import SwiftUI

struct ToastData: Identifiable {
    let id = UUID()
    var message: String
    var actionLabel: String?
    var action: (() -> Void)?
}

/// Full-area overlay container; aligns the capsule bottom-center and only
/// the capsule itself is hit-testable.
struct ViewerToast: View {
    @Binding var toast: ToastData?

    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            Spacer()
            if let toast {
                capsule(for: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(toast != nil)
        .onChange(of: toast?.id) { _, _ in scheduleDismiss() }
        .onDisappear { dismissTask?.cancel() }
    }

    private func capsule(for toast: ToastData) -> some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            if let label = toast.actionLabel {
                Button {
                    dismissTask?.cancel()
                    toast.action?()
                    withAnimation(.easeOut(duration: 0.18)) { self.toast = nil }
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .underline()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(.black.opacity(0.72))
                .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard let toast else { return }
        let seconds: Double = toast.action == nil ? 1.4 : 3.5
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }
}

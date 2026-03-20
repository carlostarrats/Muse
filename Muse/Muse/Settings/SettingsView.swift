//
//  SettingsView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import AppKit

// MARK: - Appearance preference

/// Raw-value enum stored in AppStorage so the preferred colour scheme survives restarts.
enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case light  = 1
    case dark   = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    @EnvironmentObject var appState: AppState

    @AppStorage("appearance") private var appearanceRaw: Int = AppearanceMode.system.rawValue

    // Disk-usage is calculated on appear and cached here
    @State private var diskUsageBytes: Int64? = nil
    @State private var isDiskUsageLoading: Bool = false

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        Form {
            storageSection
            Divider()
            appearanceSection
            Divider()
            aiTaggingSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .preferredColorScheme(appearanceMode.colorScheme)
        .task {
            await calculateDiskUsage()
        }
    }

    // MARK: - Storage section

    private var storageSection: some View {
        Section("Storage") {
            // Storage path
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Location")
                        .font(.subheadline)
                    Text(DatabaseManager.appSupportDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Open in Finder") {
                    NSWorkspace.shared.open(DatabaseManager.appSupportDirectory)
                }
                .controlSize(.small)
            }

            // Image count
            HStack {
                Text("Images")
                Spacer()
                Text("\(appState.images.count)")
                    .foregroundStyle(.secondary)
            }

            // Disk usage
            HStack {
                Text("Disk usage")
                Spacer()
                if isDiskUsageLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if let bytes = diskUsageBytes {
                    Text(formatBytes(bytes))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - AI Tagging section

    private var aiTaggingSection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text("AI-powered tagging is coming soon.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("OpenAI API key")
                Spacer()
                SecureField("Not yet available", text: .constant(""))
                    .disabled(true)
                    .frame(width: 200)
            }
            .foregroundStyle(.secondary)

            HStack {
                Text("Model")
                Spacer()
                TextField("Not yet available", text: .constant(""))
                    .disabled(true)
                    .frame(width: 200)
            }
            .foregroundStyle(.secondary)
        } header: {
            Text("AI Tagging")
        }
    }

    // MARK: - Helpers

    private func calculateDiskUsage() async {
        isDiskUsageLoading = true
        let url = DatabaseManager.imagesDirectory
        let bytes = await Task.detached(priority: .utility) {
            Self.directorySize(at: url)
        }.value
        diskUsageBytes = bytes
        isDiskUsageLoading = false
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}

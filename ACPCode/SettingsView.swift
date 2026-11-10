import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Settings panel: connections, MCP servers, agent screens, app and developer settings.
/// Grouped cards with a round close button; the rows and the connection screens live in `Fork/Settings/`.
struct SettingsView: View {
    @ObservedObject var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isExportingLogs = false
    @State private var exportedLogURL: URL?
    @State private var exportError: String?
    @State private var showDeleteConfirmation = false

    private var sessionLogger: CodexSessionLogger? { model.codexSessionLoggerForExport }

    private var closeButtonPlacement: ToolbarItemPlacement {
#if os(macOS)
        .cancellationAction
#else
        .topBarLeading
#endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsConnectionsSection(model: model)
                    SettingsMCPSection(model: model)
                    SettingsAgentSection(model: model)
                    appSection
                    developerSection
                }
                .readableColumn()
                .padding(16)
            }
            .background(ForkColor.surfaceGrouped.ignoresSafeArea())
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: closeButtonPlacement) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("settingsCloseButton")
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 420, idealHeight: 500)
#endif
        .sheet(isPresented: Binding(
            get: { exportedLogURL != nil },
            set: { if !$0 { exportedLogURL = nil } }
        )) {
            if let url = exportedLogURL {
                ShareSheetView(activityItems: [url])
            }
        }
    }

    // MARK: - App

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("App")
            SettingsCard {
#if os(iOS)
                PushSettingsRow()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                Divider()
                    .padding(.leading, 16)
#endif
                Button {
                    openFeedbackEmail()
                } label: {
                    SettingsRow(icon: "envelope", title: "Send Feedback")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settingsSendFeedback")
            }
        }
    }

    // MARK: - Developer

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("Developer")
            SettingsCard {
                SettingsRow(icon: "hammer", title: "Developer mode", showsDivider: true) {
                    Toggle("Developer mode", isOn: $model.devModeEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("settingsDeveloperMode")
                }
                SettingsRow(icon: "doc.text", title: "Codex session logging") {
                    Toggle("Codex session logging", isOn: $model.codexSessionLoggingEnabled)
                        .labelsHidden()
                        .accessibilityIdentifier("settingsCodexSessionLogging")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Shows extra diagnostics like connection status on server cards.")
                Text("Writes per-session JSONL logs for Codex app-server. Stored in Application Support.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

            if model.codexSessionLoggingEnabled {
                SettingsCard {
                    Button {
                        exportSessionLogs()
                    } label: {
                        SettingsRow(icon: "square.and.arrow.up", title: "Share Session Logs", showsDivider: true) {
                            if isExportingLogs {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExportingLogs)
                    .accessibilityIdentifier("settingsShareSessionLogs")

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        SettingsRow(icon: "trash", title: "Delete All Logs", iconColor: .red, titleColor: .red)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsDeleteAllLogs")
                    .alert("Delete All Logs?", isPresented: $showDeleteConfirmation) {
                        Button("Delete", role: .destructive) {
                            deleteAllLogs()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will permanently remove all Codex session log files.")
                    }
                }

                if let exportError {
                    Text(exportError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    // MARK: - Actions (unchanged from the previous Settings form)

    private func openFeedbackEmail() {
        let email = "info@halliharp.com"
        let subject = "ACP Code Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"

        if let url = URL(string: urlString) {
#if os(iOS)
            UIApplication.shared.open(url)
#else
            NSWorkspace.shared.open(url)
#endif
        }
    }

    private func deleteAllLogs() {
        guard let logger = sessionLogger else { return }
        Task { await logger.deleteAllLogs() }
    }

    private func exportSessionLogs() {
        guard let logger = sessionLogger else {
            exportError = "Session logger not available."
            return
        }
        isExportingLogs = true
        exportError = nil

        Task.detached {
            let logFiles = logger.collectLogFileURLs()
            guard !logFiles.isEmpty else {
                await MainActor.run {
                    isExportingLogs = false
                    exportError = "No log files found."
                }
                return
            }

            let tempDir = FileManager.default.temporaryDirectory
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let timestamp = formatter.string(from: Date())
            let zipName = "codex-logs-\(timestamp).zip"
            let zipURL = tempDir.appendingPathComponent(zipName)

            // Remove previous export if exists
            try? FileManager.default.removeItem(at: zipURL)

            // Create a directory with the logs then zip it
            let stagingDir = tempDir.appendingPathComponent("codex-logs-staging-\(timestamp)")
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            for logFile in logFiles {
                let dest = stagingDir.appendingPathComponent(logFile.lastPathComponent)
                try? FileManager.default.copyItem(at: logFile, to: dest)
            }

            // Use NSFileCoordinator to create a zip
            var error: NSError?
            let coordinator = NSFileCoordinator()
            var resultURL: URL?
            coordinator.coordinate(
                readingItemAt: stagingDir,
                options: .forUploading,
                error: &error
            ) { zippedURL in
                let finalURL = tempDir.appendingPathComponent(zipName)
                try? FileManager.default.removeItem(at: finalURL)
                try? FileManager.default.copyItem(at: zippedURL, to: finalURL)
                resultURL = finalURL
            }

            // Cleanup staging
            try? FileManager.default.removeItem(at: stagingDir)

            await MainActor.run {
                isExportingLogs = false
                if let url = resultURL {
                    exportedLogURL = url
                } else {
                    exportError = error?.localizedDescription ?? "Failed to create log archive."
                }
            }
        }
    }
}

/// The Agent part of Settings. It shows only for a gateway connection, because both screens need its client.
private struct SettingsAgentSection: View {
    @ObservedObject var model: AppViewModel
    @State private var showingClaudeConnections = false

    var body: some View {
        if model.selectedServerViewModel?.isGatewayServer == true, let server = model.selectedServer {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionLabel("Agent")
                SettingsCard {
                    Button {
                        showingClaudeConnections = true
                    } label: {
                        SettingsRow(icon: "link", title: "Claude connections", showsChevron: true, showsDivider: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settingsClaudeConnections")

                    SettingsGitCredentialsLink(model: model, scheme: server.scheme)
                        .id(server.id)
                }
            }
            .sheet(isPresented: $showingClaudeConnections) {
                GatewayConnectionsView(clientProvider: { [weak model] in model?.selectedGatewayClient() }) {
                    showingClaudeConnections = false
                }
            }
        }
    }
}

/// The row that pushes the Git credentials of the connected gateway (D-105). Its model is made once per connection.
private struct SettingsGitCredentialsLink: View {
    @StateObject private var credentials: GatewayGitCredentialsModel

    init(model: AppViewModel, scheme: String) {
        _credentials = StateObject(wrappedValue: GatewayGitCredentialsModel(
            clientProvider: { [weak model] in model?.selectedGatewayClient() },
            connectionScheme: scheme
        ))
    }

    var body: some View {
        NavigationLink {
            GatewayGitCredentialsView(model: credentials)
        } label: {
            SettingsRow(icon: "key", title: "Git credentials", showsChevron: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settingsGitCredentials")
    }
}

#if os(iOS)
private struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheetView: View {
    let activityItems: [Any]

    var body: some View {
        VStack(spacing: 12) {
            Text("Log file exported")
                .font(.headline)
            if let url = activityItems.first as? URL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
        .padding()
        .frame(minWidth: 300, minHeight: 120)
    }
}
#endif

#Preview {
    SettingsView(model: AppViewModel(
        storage: .inMemory(),
        defaults: UserDefaults(suiteName: "SettingsPreview") ?? .standard,
        shouldStartNetworkMonitoring: false,
        shouldConnectOnStartup: false
    ))
}

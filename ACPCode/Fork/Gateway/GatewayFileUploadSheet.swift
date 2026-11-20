import SwiftUI
import UniformTypeIdentifiers
import ACPClient

/// Upload Files for a gateway project (D-115, extended to several files by D-117). The files are checked here with
/// the gateway's rules before anything is sent, and they are sent one after another. The gateway's own text is shown
/// when it still refuses a file. Nothing is retried on its own, except a busy project, which is asked again.
struct GatewayFileUploadSheet: View {
    @StateObject private var model: GatewayFileUploadModel
    @State private var choosing = false
    let projectName: String
    let onClose: () -> Void

    init(projectId: String, projectName: String, clientProvider: @escaping () -> GatewayClient?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GatewayFileUploadModel(projectId: projectId, clientProvider: clientProvider))
        self.projectName = projectName
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        choosing = true
                    } label: {
                        Label("Choose Files", systemImage: "doc.badge.plus")
                    }
                    .disabled(model.isSending || model.isChecking)
                    .accessibilityIdentifier("uploadChooseFile")
                } header: {
                    Text("Files")
                } footer: {
                    Text(footerText)
                }

                if let message = model.message {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("uploadProblem")
                    }
                }

                if !model.items.isEmpty {
                    Section {
                        ForEach(model.items) { item in
                            itemRow(item)
                        }
                    } header: {
                        Text("Queue")
                    }
                }
            }
            .navigationTitle("Upload Files")
            .navigationBarTitleDisplayModeIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.discardAll()
                        onClose()
                    }
                    .accessibilityIdentifier("uploadClose")
                }
                ToolbarItem(placement: .confirmationAction) {
                    primaryButton
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    model.choose(urls)
                }
            }
        }
        .onDisappear {
            model.discardAll()
        }
    }

    private var footerText: String {
        "Up to \(GatewayUploadRules.maxBytes / (1024 * 1024)) MB per file, \(GatewayFileUploadModel.maxFiles) files at once and "
            + "\(GatewayFileUploadModel.maxTotalBytes / (1024 * 1024)) MB in all. The files are saved in \(projectName)'s folder "
            + "on the Mac, where the agent can read them. Allowed types: \(GatewayUploadRules.allowedTypesText)."
    }

    @ViewBuilder
    private var primaryButton: some View {
        if model.isSending {
            Button("Cancel") { model.cancel() }
                .accessibilityIdentifier("uploadCancel")
        } else {
            Button("Upload") { model.send() }
                .disabled(!model.canSend)
                .accessibilityIdentifier("uploadSend")
        }
    }

    @ViewBuilder
    private func itemRow(_ item: GatewayFileUploadModel.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text(Self.statusText(for: item.state, size: item.size))
                    .font(.caption)
                    .foregroundStyle(Self.statusColor(for: item.state))
                    .accessibilityIdentifier("uploadItemStatus")
            }
            Spacer(minLength: 8)
            itemActions(item)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func itemActions(_ item: GatewayFileUploadModel.Item) -> some View {
        switch item.state {
        case .waiting:
            removeButton(item)
        case .refused:
            Button("Send Again") { model.retry(item.id) }
                .disabled(model.isSending)
                .accessibilityIdentifier("uploadRetry")
            removeButton(item)
        case .unknown:
            Button {
                Task { await model.checkOutcome(item.id) }
            } label: {
                if model.isChecking {
                    ProgressView()
                } else {
                    Text("Check")
                }
            }
            .disabled(model.isChecking)
            .accessibilityLabel("Check whether \(item.name) is on the Mac")
            .accessibilityIdentifier("uploadCheck")
            removeButton(item)
        case .saved(let path, _):
#if os(iOS)
            Button("Copy Path") {
                UIPasteboard.general.string = path
            }
            .accessibilityIdentifier("uploadCopyPath")
#else
            EmptyView()
#endif
        case .sending, .retrying:
            ProgressView()
        }
    }

    private func removeButton(_ item: GatewayFileUploadModel.Item) -> some View {
        Button(role: .destructive) {
            model.remove(item.id)
        } label: {
            Image(systemName: "trash")
        }
        .disabled(model.isSending)
        .accessibilityLabel("Remove \(item.name)")
        .accessibilityIdentifier("uploadRemove")
    }

    static func statusText(for state: GatewayFileUploadModel.Item.State, size: Int) -> String {
        switch state {
        case .waiting:
            return "Waiting, \(describe(size))"
        case .sending:
            return "Sending…"
        case .retrying(let attempt):
            return "The project is busy. Trying again (\(attempt) of \(GatewayFileUploadModel.busyAttemptLimit))."
        case .saved(let path, let bytes):
            return "Saved as \(path), \(describe(bytes))."
        case .refused(let text), .unknown(let text):
            return text
        }
    }

    static func statusColor(for state: GatewayFileUploadModel.Item.State) -> Color {
        switch state {
        case .refused: return .red
        case .unknown: return .orange
        case .saved: return .green
        default: return .secondary
        }
    }

    private static func describe(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private extension View {
    /// The navigation title style that exists on this platform. A no-op on macOS.
    @ViewBuilder
    func navigationBarTitleDisplayModeIfAvailable() -> some View {
#if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}

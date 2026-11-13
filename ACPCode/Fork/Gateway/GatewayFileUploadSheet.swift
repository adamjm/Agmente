import SwiftUI
import UniformTypeIdentifiers
import ACPClient

/// Upload File for a gateway project (D-109): one file, saved in the project's folder on the Mac. The file
/// is checked here with the gateway's rules before anything is sent. The gateway's own text is shown when it
/// still refuses. Nothing is retried on its own.
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
                        Label(model.pickedName ?? "Choose a File", systemImage: "doc.badge.plus")
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("uploadChooseFile")
                } header: {
                    Text("File")
                } footer: {
                    Text("Up to 8 MB. The file is saved in \(projectName)'s folder on the Mac, where the agent can read it. Allowed types: png, jpg, jpeg, gif, webp, heic, pdf, txt, md, csv, json.")
                }

                statusSection
            }
            .navigationTitle("Upload File")
            .navigationBarTitleDisplayModeIfAvailable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.discard()
                        onClose()
                    }
                    .accessibilityIdentifier("uploadClose")
                }
                ToolbarItem(placement: .confirmationAction) {
                    primaryButton
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.choose(url)
                }
            }
        }
        .onDisappear {
            model.discard()
        }
    }

    private var isBusy: Bool {
        if case .sending = model.phase { return true }
        return model.isChecking
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.phase {
        case .sending:
            Button("Cancel") { model.cancel() }
                .accessibilityIdentifier("uploadCancel")
        case .picked:
            Button("Upload") { model.send() }
                .accessibilityIdentifier("uploadSend")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.phase {
        case .empty:
            if let message = model.message {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("uploadProblem")
                }
            }
        case .picked(let name, let size):
            Section {
                Text("\(name), \(Self.describe(size)). Ready to upload to \(projectName).")
                    .accessibilityIdentifier("uploadReady")
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("uploadProblem")
                }
            }
        case .sending(let name):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Sending \(name) to \(projectName)…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("uploadSending")
            }
        case .saved(let path, let bytes):
            Section {
                Label("Saved as \(path), \(Self.describe(bytes)).", systemImage: "checkmark.circle")
                    .accessibilityIdentifier("uploadSaved")
                Button("Copy Path") {
#if os(iOS)
                    UIPasteboard.general.string = path
#endif
                }
                .accessibilityIdentifier("uploadCopyPath")
            }
        case .unknownOutcome(let name):
            Section {
                Text(model.message ?? "Could not confirm the upload. The file may be on the Mac.")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("uploadUnknown")
                Button {
                    Task { await model.checkOutcome() }
                } label: {
                    if model.isChecking {
                        ProgressView()
                    } else {
                        Text("Check Files")
                    }
                }
                .disabled(model.isChecking)
                .accessibilityLabel("Check whether \(name) is on the Mac")
                .accessibilityIdentifier("uploadCheck")
            }
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

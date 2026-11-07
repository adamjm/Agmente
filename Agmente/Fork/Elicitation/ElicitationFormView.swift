import SwiftUI
import ACP

/// Attached once at the root of the app: shows the first waiting form as a sheet (FR-44).
struct ElicitationSheetHost: View {
    @ObservedObject var inbox: ElicitationInboxModel

    var body: some View {
        Color.clear
            .sheet(isPresented: Binding(get: { inbox.current != nil }, set: { _ in })) {
                if let form = inbox.current {
                    ElicitationFormView(form: form)
                }
            }
            .alert("Agent question closed", isPresented: Binding(get: { inbox.notice != nil }, set: { if !$0 { inbox.notice = nil } })) {
                Button("OK", role: .cancel) { inbox.notice = nil }
            } message: {
                Text(inbox.notice ?? "")
            }
    }
}

/// The form the agent asked for: its message, one control per supported field, and the three answers.
struct ElicitationFormView: View {
    @ObservedObject var form: ElicitationFormModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(form.request.message)
                        .accessibilityIdentifier("elicitationMessage")
                }
                Section {
                    ForEach(form.request.fields) { field in
                        fieldRow(field)
                    }
                }
                if form.hasUnsupportedRequiredFields {
                    Section {
                        Text("This form is not supported in this app; you can decline or cancel.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("elicitationUnsupported")
                    }
                }
                if let message = form.errorMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("elicitationError")
                    }
                }
                Section {
                    Button("Accept") { Task { await form.submit() } }
                        .disabled(form.isSending || form.blockingReason != nil)
                        .accessibilityIdentifier("elicitationAccept")
                    Button("Decline") { Task { await form.decline() } }
                        .disabled(form.isSending)
                        .accessibilityIdentifier("elicitationDecline")
                    Button("Cancel") { Task { await form.cancel() } }
                        .disabled(form.isSending)
                        .accessibilityIdentifier("elicitationCancel")
                }
            }
            .navigationTitle("Agent question")
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func fieldRow(_ field: ElicitationField) -> some View {
        let label = field.required ? "\(field.label) (required)" : field.label
        switch field.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                TextField(label, text: textBinding(field.name))
                    .accessibilityIdentifier("field-\(field.name)")
                if let description = field.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
            }
        case .number, .integer:
            VStack(alignment: .leading, spacing: 4) {
                TextField(label, text: textBinding(field.name))
#if os(iOS)
                    .keyboardType(field.kind == .integer ? .numberPad : .decimalPad)
#endif
                    .accessibilityIdentifier("field-\(field.name)")
                if let description = field.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
            }
        case .boolean:
            VStack(alignment: .leading, spacing: 4) {
                Toggle(label, isOn: Binding(get: { form.toggles[field.name] ?? false }, set: { form.toggles[field.name] = $0 }))
                    .accessibilityIdentifier("field-\(field.name)")
                if let description = field.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
            }
        case .choice(let options):
            VStack(alignment: .leading, spacing: 4) {
                Picker(label, selection: textBinding(field.name)) {
                    Text("Not set").tag("")
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .accessibilityIdentifier("field-\(field.name)")
                if let description = field.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
            }
        case .unsupported(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(field.label): not supported (\(reason))")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { form.texts[name] ?? "" }, set: { form.texts[name] = $0 })
    }
}

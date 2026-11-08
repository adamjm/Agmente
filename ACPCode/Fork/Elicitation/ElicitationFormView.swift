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
            // Each option is its own Form row, so the choices read as separate, tappable answers. Packing them
            // into one row made them a single block of text under one label.
            Text(label)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("field-\(field.name)")
            ForEach(options) { option in
                choiceButton(field: field, option: option)
            }
            if let description = field.description { Text(description).font(.footnote).foregroundStyle(.secondary) }
        case .unsupported(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(field.label): not supported (\(reason))")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// One option of a choice field. Tapping it selects it; tapping the selected option of an optional
    /// field clears the answer, so the field can be left out.
    @ViewBuilder
    private func choiceButton(field: ElicitationField, option: ElicitationOption) -> some View {
        let isSelected = (form.texts[field.name] ?? "") == option.value
        Button {
            if isSelected && !field.required {
                form.texts[field.name] = ""
            } else {
                form.texts[field.name] = option.value
            }
        } label: {
            HStack {
                Text(option.title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("choice-\(field.name)-\(option.value)")
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(get: { form.texts[name] ?? "" }, set: { form.texts[name] = $0 })
    }
}

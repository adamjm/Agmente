import Foundation
import ACP

/// One form the agent asked for (FR-44, D-090, PLAN 6C.3): the message and the fields of its requested
/// schema. Parsing refuses what this app cannot honour (a non-form mode, a schema that is not an object).
/// A field this app cannot render is kept and marked `unsupported`, so the form can say so.
struct ElicitationRequest: Equatable, Sendable {
    /// The gateway's id, `acpcode-elic-<hex>`.
    let id: String
    let sessionId: String
    let toolCallId: String?
    let message: String
    /// Sorted by field name (the wire object has no order once it is decoded).
    let fields: [ElicitationField]

    enum ParseError: Error, Equatable, Sendable {
        /// The event is not an `elicitation/create` request with an id and params.
        case notAnElicitation
        /// The mode is missing or not `form` (URL mode is refused).
        case unsupportedMode(String?)
        /// `requestedSchema` is missing, or its `type` is not `object`, or its `properties` or `required` have the wrong shape.
        case schemaNotObject
        /// A required string field is missing or empty.
        case missingField(String)
    }

    static let method = "elicitation/create"
    static let idPrefix = "acpcode-elic-"

    /// Parses the logged message of an `_acpcode/event` (`GatewayEvent.message`).
    static func parse(_ message: ACP.Value) throws -> ElicitationRequest {
        guard let object = message.objectValue,
              object["method"]?.stringValue == method,
              let id = object["id"]?.stringValue, id.hasPrefix(idPrefix),
              let params = object["params"]?.objectValue else {
            throw ParseError.notAnElicitation
        }
        guard let sessionId = nonEmpty(params["sessionId"]) else { throw ParseError.missingField("sessionId") }
        let mode = params["mode"]?.stringValue
        guard mode == "form" else { throw ParseError.unsupportedMode(mode) }
        guard let text = nonEmpty(params["message"]) else { throw ParseError.missingField("message") }

        guard let schema = params["requestedSchema"]?.objectValue,
              schema["type"]?.stringValue == "object" else {
            throw ParseError.schemaNotObject
        }
        var properties: [String: ACP.Value] = [:]
        if let raw = schema["properties"] {
            guard let object = raw.objectValue else { throw ParseError.schemaNotObject }
            properties = object
        }
        var required: [String] = []
        if let raw = schema["required"] {
            guard let array = raw.arrayValue else { throw ParseError.schemaNotObject }
            required = array.compactMap(\.stringValue)
        }
        let requiredSet = Set(required)

        var fields = properties.keys.sorted().map { name in
            ElicitationField(name: name, spec: properties[name] ?? .null, required: requiredSet.contains(name))
        }
        // A required name with no property cannot be answered, so it is kept as unsupported and blocks accept.
        for name in requiredSet.subtracting(properties.keys).sorted() {
            fields.append(ElicitationField(name: name, kind: .unsupported("missing from properties"), label: name, description: nil, required: true))
        }

        return ElicitationRequest(id: id, sessionId: sessionId, toolCallId: params["toolCallId"]?.stringValue,
                                  message: text, fields: fields)
    }

    var hasUnsupportedFields: Bool { fields.contains { !$0.isSupported } }

    /// Only a required field that cannot be answered earns the "not supported" note; optional ones are left out.
    var hasUnsupportedRequiredFields: Bool { fields.contains { $0.required && !$0.isSupported } }

    private static func nonEmpty(_ value: ACP.Value?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}

/// One property of the requested schema.
struct ElicitationField: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case text
        /// A string with a fixed list of values: `enum` (with optional `enumNames`), or `oneOf` / `anyOf`
        /// entries that each give a `const` and an optional `title`.
        case choice([ElicitationOption])
        case number
        case integer
        case boolean
        /// Any other shape. The associated text is the JSON type, or the reason.
        case unsupported(String)
    }

    let name: String
    let kind: Kind
    let label: String
    let description: String?
    let required: Bool

    var id: String { name }

    var isSupported: Bool {
        if case .unsupported = kind { return false }
        return true
    }

    init(name: String, kind: Kind, label: String, description: String?, required: Bool) {
        self.name = name
        self.kind = kind
        self.label = label
        self.description = description
        self.required = required
    }

    init(name: String, spec: ACP.Value, required: Bool) {
        self.name = name
        self.required = required
        self.label = spec["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? name
        self.description = spec["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        guard spec.objectValue != nil else {
            self.kind = .unsupported("invalid")
            return
        }
        let type = spec["type"]?.stringValue ?? ""
        switch type {
        case "string":
            if let raw = spec["enum"] {
                if let values = raw.arrayValue?.compactMap(\.stringValue), !values.isEmpty,
                   values.count == raw.arrayValue?.count, Set(values).count == values.count {
                    // enumNames, when it has one name per value, gives the labels; otherwise the values are shown.
                    let names = spec["enumNames"]?.arrayValue?.compactMap(\.stringValue)
                    let titles = (names?.count == values.count) ? names ?? values : values
                    self.kind = .choice(zip(values, titles).map { ElicitationOption(value: $0, title: $1) })
                } else {
                    self.kind = .unsupported("enum")
                }
            } else if let raw = spec["oneOf"] ?? spec["anyOf"] {
                if let options = Self.titledOptions(raw) {
                    self.kind = .choice(options)
                } else {
                    self.kind = .unsupported("choice list")
                }
            } else {
                self.kind = .text
            }
        case "number": self.kind = .number
        case "integer": self.kind = .integer
        case "boolean": self.kind = .boolean
        default: self.kind = .unsupported(type.isEmpty ? "no type" : type)
        }
    }

    /// Reads a `oneOf` or `anyOf` list of `{const, title?}` entries. Any entry without a non-empty string
    /// `const`, or a repeated value, makes the whole list unsupported rather than a partial menu.
    static func titledOptions(_ raw: ACP.Value) -> [ElicitationOption]? {
        guard let items = raw.arrayValue, !items.isEmpty else { return nil }
        var options: [ElicitationOption] = []
        for item in items {
            guard item.objectValue != nil, let value = item["const"]?.stringValue, !value.isEmpty else { return nil }
            let title = item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? value
            options.append(ElicitationOption(value: value, title: title))
        }
        guard Set(options.map(\.value)).count == options.count else { return nil }
        return options
    }
}

/// One value a choice field accepts, and the label to show for it.
struct ElicitationOption: Equatable, Sendable, Identifiable {
    let value: String
    let title: String

    var id: String { value }
}

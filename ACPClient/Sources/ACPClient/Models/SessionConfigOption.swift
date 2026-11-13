import Foundation
import ACP

public enum ACPSessionConfigOptionValue: Sendable, Equatable {
    case string(String)
    case bool(Bool)

    public var acpValue: ACP.Value {
        switch self {
        case .string(let value):
            return .string(value)
        case .bool(let value):
            return .bool(value)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

public struct ACPSessionConfigOptionChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public enum ACPSessionConfigOptionKind: Sendable, Equatable {
    case select(options: [ACPSessionConfigOptionChoice])
    case boolean
    case unknown(String)

    public var typeName: String {
        switch self {
        case .select:
            return "select"
        case .boolean:
            return "boolean"
        case .unknown(let raw):
            return raw
        }
    }
}

public struct ACPSessionConfigOption: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let kind: ACPSessionConfigOptionKind
    public let currentValue: ACPSessionConfigOptionValue

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        kind: ACPSessionConfigOptionKind,
        currentValue: ACPSessionConfigOptionValue
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.kind = kind
        self.currentValue = currentValue
    }

    public var selectedChoiceName: String? {
        guard case .select(let options) = kind,
              let selectedId = currentValue.stringValue else { return nil }
        return options.first(where: { $0.id == selectedId })?.name
    }

    public var isModeSelector: Bool {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedId == "mode" || normalizedCategory == "mode"
    }

    /// Model picker: category `model` (ACP schema SessionConfigOptionCategory) or id `model`.
    /// The `model_config` category is a model parameter, not the picker, so it is not matched.
    public var isModelSelector: Bool {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedId == "model" || normalizedCategory == "model"
    }
}

public enum ACPSessionConfigOptionParser {
    public static func parse(from value: ACP.Value?) -> [ACPSessionConfigOption] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap(parseOption(from:))
    }

    public static func parse(from object: [String: ACP.Value]?) -> [ACPSessionConfigOption] {
        parse(from: object?["configOptions"])
    }

    public static func modeInfo(from options: [ACPSessionConfigOption]) -> ACPModesInfo? {
        guard let modeOption = options.first(where: { $0.isModeSelector }),
              case .select(let choices) = modeOption.kind else { return nil }

        let modes = choices.map { AgentModeOption(id: $0.id, name: $0.name, description: $0.description) }
        let currentModeId = modeOption.currentValue.stringValue
        if modes.isEmpty && currentModeId == nil {
            return nil
        }

        return ACPModesInfo(availableModes: modes, currentModeId: currentModeId)
    }

    private static func parseOption(from value: ACP.Value) -> ACPSessionConfigOption? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let name = object["name"]?.stringValue else {
            return nil
        }

        let description = object["description"]?.stringValue
        let category = object["category"]?.stringValue
        let rawType = object["type"]?.stringValue?.lowercased() ?? "select"
        let currentValue = parseCurrentValue(from: object["currentValue"]) ?? .string("")

        let kind: ACPSessionConfigOptionKind
        switch rawType {
        case "select":
            kind = .select(options: parseChoices(from: object["options"]))
        case "boolean", "flag":
            kind = .boolean
        default:
            kind = .unknown(rawType)
        }

        return ACPSessionConfigOption(
            id: id,
            name: name,
            description: description,
            category: category,
            kind: kind,
            currentValue: currentValue
        )
    }

    private static func parseCurrentValue(from value: ACP.Value?) -> ACPSessionConfigOptionValue? {
        if let string = value?.stringValue {
            return .string(string)
        }
        if let bool = value?.boolValue {
            return .bool(bool)
        }
        return nil
    }

    private static func parseChoices(from value: ACP.Value?) -> [ACPSessionConfigOptionChoice] {
        guard case let .array(items)? = value else { return [] }

        var choices: [ACPSessionConfigOptionChoice] = []
        for item in items {
            guard let object = item.objectValue else { continue }

            if case let .array(grouped)? = object["options"] {
                choices.append(contentsOf: parseChoices(from: .array(grouped)))
                continue
            }

            guard let choiceId = object["value"]?.stringValue ?? object["id"]?.stringValue,
                  let choiceName = object["name"]?.stringValue ?? object["title"]?.stringValue else {
                continue
            }

            choices.append(
                ACPSessionConfigOptionChoice(
                    id: choiceId,
                    name: choiceName,
                    description: object["description"]?.stringValue
                )
            )
        }

        return choices
    }
}

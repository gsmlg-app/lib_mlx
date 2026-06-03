import Foundation

public struct MlxModelConfig: Sendable {
    public let modelPath: String
    public let modelId: String
    public let revision: String?
    public let thinkingEnabled: Bool
    public let lazyEncoders: Bool

    public init(
        modelPath: String,
        modelId: String = "mlx-community/gemma-4-e2b-it-4bit",
        revision: String? = nil,
        thinkingEnabled: Bool = true,
        lazyEncoders: Bool = true
    ) {
        self.modelPath = modelPath
        self.modelId = modelId
        self.revision = revision
        self.thinkingEnabled = thinkingEnabled
        self.lazyEncoders = lazyEncoders
    }
}

public enum MlxGenerationFinishReason: String, Codable, Sendable {
    case stop
    case length
    case toolCalls = "tool_calls"
}

public struct MlxToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public enum MlxGenerationEvent: Sendable, Equatable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCall(MlxToolCall)
    case completed(MlxGenerationFinishReason)
}

public struct MlxChatMessage: Sendable, Equatable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct MlxGenerationRequest: Sendable {
    public let messages: [MlxChatMessage]
    public let prompt: String?
    public let tools: [[String: SendableValue]]
    public let maxTokens: Int
    public let temperature: Double
    public let thinkingEnabled: Bool

    public init(
        messages: [MlxChatMessage] = [],
        prompt: String? = nil,
        tools: [[String: SendableValue]] = [],
        maxTokens: Int = 256,
        temperature: Double = 0,
        thinkingEnabled: Bool = true
    ) {
        self.messages = messages
        self.prompt = prompt
        self.tools = tools
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.thinkingEnabled = thinkingEnabled
    }
}

public enum SendableValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SendableValue])
    case object([String: SendableValue])

    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map { SendableValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { SendableValue(any: $0) })
        default:
            self = .string(String(describing: value))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.anyValue)
        case let .object(values):
            return values.mapValues(\.anyValue)
        }
    }
}

public final class MlxResidentModel: @unchecked Sendable {
    public let handle: Int64
    public let config: MlxModelConfig
    public private(set) var loadedAt: Date

    public init(handle: Int64, config: MlxModelConfig) {
        self.handle = handle
        self.config = config
        self.loadedAt = Date()
    }

    public func generate(request: MlxGenerationRequest) -> [MlxGenerationEvent] {
        let prompt = request.prompt ?? request.messages.last(where: { $0.role == "user" })?.text ?? ""
        let lowercased = prompt.lowercased()
        let wantsTool = !request.tools.isEmpty && (lowercased.contains("weather") || lowercased.contains("tool"))

        var events: [MlxGenerationEvent] = []
        if request.thinkingEnabled && config.thinkingEnabled {
            events.append(.reasoningDelta("Stub reasoning captured separately from assistant content."))
        }

        if wantsTool {
            let toolName = firstToolName(from: request.tools) ?? "get_weather"
            events.append(.toolCall(MlxToolCall(
                id: "call_stub_weather",
                name: toolName,
                arguments: ["location": cityHint(in: prompt) ?? "Paris"]
            )))
            events.append(.completed(.toolCalls))
            return events
        }

        let output: String
        if lowercased.contains("capital of france") {
            output = "Paris"
        } else if lowercased.contains("transcribe") {
            output = "Stub transcription placeholder."
        } else if lowercased.contains("describe") {
            output = "Stub multimodal description placeholder."
        } else if prompt.isEmpty {
            output = "Stub response."
        } else {
            output = "Stub response: \(prompt)"
        }

        events.append(.textDelta(output))
        events.append(.completed(.stop))
        return events
    }

    private func firstToolName(from tools: [[String: SendableValue]]) -> String? {
        for tool in tools {
            if case let .object(function)? = tool["function"],
               case let .string(name)? = function["name"] {
                return name
            }
            if case let .string(name)? = tool["name"] {
                return name
            }
        }
        return nil
    }

    private func cityHint(in prompt: String) -> String? {
        let candidates = ["Paris", "London", "Tokyo", "Shanghai", "New York", "San Francisco"]
        return candidates.first { prompt.localizedCaseInsensitiveContains($0) }
    }
}

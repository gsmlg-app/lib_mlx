import Foundation

public struct MlxAvailableModel: Sendable, Equatable {
    public let id: String
    public let huggingFaceModelId: String
    public var huggingFaceModelPageURL: URL { URL(string: "https://huggingface.co/\(huggingFaceModelId)")! }
    public static let gemma4E2b = Self(id: "gemma-4-e2b", huggingFaceModelId: "mlx-community/gemma-4-e2b-it-4bit")
    public static let gemma4E4b = Self(id: "gemma-4-e4b", huggingFaceModelId: "mlx-community/gemma-4-e4b-it-4bit")
    public static let all = [gemma4E2b]
    public static let defaultModel = gemma4E2b
    public static let pinnedRevision = "238767527555cb75a05732a84dff5d6ba0dd6809"
    public static func named(_ id: String) -> Self? { all.first { $0.id == id } }
}

public struct MlxModelConfig: Sendable {
    public let modelPath: String
    public let modelId: String
    public let revision: String?
    public let thinkingEnabled: Bool
    public let lazyEncoders: Bool
    public let contextLength: Int
    public let prefillStepSize: Int
    public let memoryLimitBytes: Int?
    public let cacheLimitBytes: Int
    public init(modelPath: String, modelId: String = MlxAvailableModel.defaultModel.huggingFaceModelId,
                revision: String? = nil, thinkingEnabled: Bool = true, lazyEncoders: Bool = true,
                contextLength: Int = 8192, prefillStepSize: Int = 256,
                memoryLimitBytes: Int? = nil, cacheLimitBytes: Int = 64 * 1024 * 1024) {
        self.modelPath = modelPath; self.modelId = modelId; self.revision = revision
        self.thinkingEnabled = thinkingEnabled; self.lazyEncoders = lazyEncoders
        self.contextLength = contextLength; self.prefillStepSize = prefillStepSize
        self.memoryLimitBytes = memoryLimitBytes; self.cacheLimitBytes = cacheLimitBytes
    }
    public init(modelPath: String, model: MlxAvailableModel, revision: String? = nil,
                thinkingEnabled: Bool = true, lazyEncoders: Bool = true, contextLength: Int = 8192,
                prefillStepSize: Int = 256, memoryLimitBytes: Int? = nil,
                cacheLimitBytes: Int = 64 * 1024 * 1024) {
        self.init(modelPath: modelPath, modelId: model.huggingFaceModelId, revision: revision,
                  thinkingEnabled: thinkingEnabled, lazyEncoders: lazyEncoders, contextLength: contextLength,
                  prefillStepSize: prefillStepSize, memoryLimitBytes: memoryLimitBytes, cacheLimitBytes: cacheLimitBytes)
    }
}

public enum MlxGenerationFinishReason: String, Codable, Sendable { case stop, length; case toolCalls = "tool_calls" }
public struct MlxToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: SendableValue
    public init(id: String, name: String, arguments: SendableValue) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}
public struct MlxToolCallDelta: Sendable, Equatable {
    public let index: Int
    public let id: String?
    public let name: String?
    public let arguments: String
    public init(index: Int, id: String? = nil, name: String? = nil, arguments: String) {
        self.index = index; self.id = id; self.name = name; self.arguments = arguments
    }
}
public struct MlxUsage: Sendable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let cachedTokens: Int
    public let reasoningTokens: Int
    public let promptSeconds: Double
    public let generationSeconds: Double
    public var totalTokens: Int { promptTokens + completionTokens }
    public init(promptTokens: Int, completionTokens: Int, cachedTokens: Int = 0, reasoningTokens: Int = 0,
                promptSeconds: Double = 0, generationSeconds: Double = 0) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.cachedTokens = cachedTokens; self.reasoningTokens = reasoningTokens
        self.promptSeconds = promptSeconds; self.generationSeconds = generationSeconds
    }
}
public enum MlxGenerationEvent: Sendable, Equatable {
    case reasoningDelta(String), textDelta(String), toolCall(MlxToolCall), toolCallDelta(MlxToolCallDelta)
    case usage(MlxUsage), completed(MlxGenerationFinishReason)
}
public enum MlxContentPart: Sendable, Equatable {
    case text(String)
    case imageURL(String)
    case inputAudio(data: String, format: String)
    case audioURL(String)
    case unsupported(type: String, payload: SendableValue)
}
public struct MlxChatMessage: Sendable, Equatable {
    public let role: String
    public let content: [MlxContentPart]
    public let toolCalls: [MlxToolCall]
    public let toolCallID: String?
    public let name: String?
    /// Preserved for the pinned template's history/tool-turn reasoning rules.
    public let reasoningContent: String?
    public var text: String { content.compactMap { if case .text(let s) = $0 { return s }; return nil }.joined() }
    public init(role: String, content: [MlxContentPart], toolCalls: [MlxToolCall] = [], toolCallID: String? = nil, name: String? = nil, reasoningContent: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID; self.name = name
        self.reasoningContent = reasoningContent
    }
    public init(role: String, text: String) { self.init(role: role, content: [.text(text)]) }
}
public struct MlxGenerationRequest: Sendable {
    public let messages: [MlxChatMessage]
    public let prompt: String?
    public let instructions: String?
    public let tools: [[String: SendableValue]]
    public let maxTokens: Int
    public let temperature: Double
    public let topP: Double
    public let topK: Int
    public let seed: UInt64?
    public let thinkingEnabled: Bool
    public init(messages: [MlxChatMessage] = [], prompt: String? = nil, instructions: String? = nil,
                tools: [[String: SendableValue]] = [], maxTokens: Int = 256, temperature: Double = 0,
                topP: Double = 1, topK: Int = 0, seed: UInt64? = nil, thinkingEnabled: Bool = true) {
        self.messages = messages; self.prompt = prompt; self.instructions = instructions; self.tools = tools
        self.maxTokens = maxTokens; self.temperature = temperature; self.topP = topP; self.topK = topK
        self.seed = seed; self.thinkingEnabled = thinkingEnabled
    }
}
public struct MlxCoreError: Error, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
public enum SendableValue: Sendable, Equatable {
    case null, bool(Bool), int(Int), uint(UInt64), double(Double), string(String), array([SendableValue]), object([String: SendableValue])
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else if String(cString: v.objCType).contains("f") || String(cString: v.objCType).contains("d") { self = .double(v.doubleValue) }
            else if let signed = Int(v.stringValue) { self = .int(signed) }
            else if let unsigned = UInt64(v.stringValue) { self = .uint(unsigned) }
            else { self = .double(v.doubleValue) }
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { Self(any: $0) })
        case let v as [String: Any]: self = .object(v.mapValues { Self(any: $0) })
        default: self = .null
        }
    }
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .uint(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.mapValues(\.anyValue)
        }
    }
}
import CoreFoundation

import Foundation
import CoreFoundation
import MlxCore

enum OpenAIEndpoint: String, Sendable {
    case chat = "/v1/chat/completions"
    case responses = "/v1/responses"
}

/// Conversion is independent of transport and backend; all ordered input survives validation.
struct OpenAIRequest {
    let request: MlxGenerationRequest
    let stream: Bool
    let includeUsage: Bool

    static func convert(data: Data, endpoint: OpenAIEndpoint, modelID: String) throws -> OpenAIRequest {
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("Request body must be a JSON object.") }
        let allowed: Set<String> = ["model", "stream", "stream_options", "messages", "input", "instructions", "tools", "tool_choice", "parallel_tool_calls", "max_tokens", "max_completion_tokens", "max_output_tokens", "temperature", "top_p", "top_k", "seed", "thinking", "reasoning"]
        if let key = body.keys.sorted().first(where: { !allowed.contains($0) }) { throw invalid("Unsupported parameter: \(key).") }
        if let value = body["model"] { guard let model = value as? String, model == modelID else { throw invalid("model must name the loaded model: \(modelID).") } }
        let stream = try bool(body["stream"], name: "stream") ?? false
        var includeUsage = false
        if let options = body["stream_options"] {
            guard let options = options as? [String: Any], Set(options.keys).isSubset(of: ["include_usage"]), stream else { throw invalid("stream_options supports include_usage only for streaming requests.") }
            includeUsage = try bool(options["include_usage"], name: "stream_options.include_usage") ?? false
        }
        if let choice = body["tool_choice"] { guard (choice as? String) == "auto" else { throw invalid("Only tool_choice auto is supported.") } }
        if try bool(body["parallel_tool_calls"], name: "parallel_tool_calls") == true { throw invalid("parallel_tool_calls is not supported.") }
        let tokenFields = ["max_tokens", "max_completion_tokens", "max_output_tokens"].filter { body[$0] != nil }
        guard tokenFields.count <= 1 else { throw invalid("Specify only one token limit.") }
        let maxTokens = try integer(tokenFields.first.flatMap { body[$0] }, name: tokenFields.first ?? "max_tokens") ?? 256
        guard maxTokens > 0 else { throw invalid("Token limit must be positive.") }
        let temperature = try number(body["temperature"], name: "temperature") ?? 0
        let topP = try number(body["top_p"], name: "top_p") ?? 1
        let topK = try integer(body["top_k"], name: "top_k") ?? 0
        guard temperature >= 0, temperature <= 2, topP > 0, topP <= 1, topK >= 0 else { throw invalid("Invalid sampling parameter range.") }
        let seedNumber = try integer(body["seed"], name: "seed")
        guard seedNumber == nil || seedNumber! >= 0 else { throw invalid("seed must be nonnegative.") }
        var thinking = try bool(body["thinking"], name: "thinking") ?? false
        if let reasoning = body["reasoning"] {
            guard let reasoning = reasoning as? [String: Any], Set(reasoning.keys).isSubset(of: ["summary"]), reasoning["summary"] == nil || reasoning["summary"] as? String == "auto" else { throw invalid("reasoning supports summary: auto only; reasoning effort is unsupported.") }
            thinking = true
        }
        let tools: [[String: SendableValue]]
        if let input = body["tools"] {
            guard let input = input as? [[String: Any]], input.allSatisfy({ $0["type"] as? String == "function" }) else { throw invalid("tools must contain function definitions.") }
            for tool in input {
                let function = tool["function"] as? [String: Any] ?? tool
                guard let name = function["name"] as? String, !name.isEmpty else { throw invalid("Each function tool requires a name.") }
                if let parameters = function["parameters"] { guard parameters is [String: Any] else { throw invalid("Function parameters must be a JSON schema object.") } }
            }
            tools = input.map { $0.mapValues { SendableValue(any: $0) } }
        } else { tools = [] }
        let instructions: String?
        if let value = body["instructions"] { guard let text = value as? String else { throw invalid("instructions must be a string.") }; instructions = text }
        else { instructions = nil }
        let messages: [MlxChatMessage]
        switch endpoint {
        case .chat:
            guard body["input"] == nil, instructions == nil, let input = body["messages"] as? [[String: Any]], !input.isEmpty else { throw invalid("messages must be a nonempty array; input/instructions belong to Responses.") }
            messages = try input.map(chatMessage)
        case .responses:
            guard body["messages"] == nil, let input = body["input"] else { throw invalid("Responses requires input; messages belongs to chat completions.") }
            if let text = input as? String { messages = [MlxChatMessage(role: "user", text: text)] }
            else if let items = input as? [[String: Any]], !items.isEmpty { messages = try items.map(responseItem) }
            else { throw invalid("input must be a string or nonempty ordered input array.") }
        }
        return OpenAIRequest(request: MlxGenerationRequest(messages: messages, instructions: instructions, tools: tools, maxTokens: maxTokens,
            temperature: temperature, topP: topP, topK: topK, seed: seedNumber.map(UInt64.init), thinkingEnabled: thinking), stream: stream, includeUsage: includeUsage)
    }

    private static func chatMessage(_ value: [String: Any]) throws -> MlxChatMessage {
        guard let role = value["role"] as? String, ["system", "developer", "user", "assistant", "tool"].contains(role) else { throw invalid("Unsupported message role.") }
        let content = try parts(value["content"], allowNull: role == "assistant")
        let calls: [MlxToolCall]
        if let raw = value["tool_calls"] {
            guard role == "assistant", let raw = raw as? [[String: Any]] else { throw invalid("tool_calls requires an assistant message and an array.") }
            calls = try raw.map { call in
                guard call["type"] as? String == "function", let id = call["id"] as? String, !id.isEmpty,
                      let function = call["function"] as? [String: Any], let name = function["name"] as? String, !name.isEmpty,
                      let arguments = function["arguments"] as? String, let data = arguments.data(using: .utf8) else { throw invalid("Malformed assistant function call.") }
                let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                return MlxToolCall(id: id, name: name, arguments: SendableValue(any: json))
            }
        } else { calls = [] }
        var callID: String?
        if role == "tool" {
            guard let id = value["tool_call_id"] as? String, !id.isEmpty else { throw invalid("Tool results require tool_call_id.") }
            callID = id
        }
        if let name = value["name"], !(name is String) { throw invalid("Message name must be a string.") }
        let reasoningValue = value["reasoning_content"] ?? value["reasoning"]
        if let reasoningValue, !(reasoningValue is String) {
            throw invalid("Assistant reasoning must be a string.")
        }
        guard reasoningValue == nil || role == "assistant" else { throw invalid("Only assistant messages may contain reasoning.") }
        if let lhs = value["reasoning_content"] as? String, let rhs = value["reasoning"] as? String, lhs != rhs {
            throw invalid("Conflicting assistant reasoning fields.")
        }
        return MlxChatMessage(role: role, content: content, toolCalls: calls, toolCallID: callID,
                              name: value["name"] as? String, reasoningContent: reasoningValue as? String)
    }

    private static func responseItem(_ item: [String: Any]) throws -> MlxChatMessage {
        switch item["type"] as? String ?? "message" {
        case "message": return try chatMessage(item)
        case "function_call":
            guard let id = item["call_id"] as? String, !id.isEmpty, let name = item["name"] as? String, !name.isEmpty,
                  let args = item["arguments"] as? String else { throw invalid("Malformed function_call input.") }
            let json = try JSONSerialization.jsonObject(with: Data(args.utf8), options: [.fragmentsAllowed])
            return MlxChatMessage(role: "assistant", content: [], toolCalls: [MlxToolCall(id: id, name: name, arguments: SendableValue(any: json))])
        case "function_call_output":
            guard let id = item["call_id"] as? String, !id.isEmpty, let output = item["output"] else { throw invalid("Malformed function_call_output input.") }
            return MlxChatMessage(role: "tool", content: try parts(output), toolCallID: id)
        default: throw invalid("Unsupported Responses input item type.")
        }
    }

    private static func parts(_ value: Any?, allowNull: Bool = false) throws -> [MlxContentPart] {
        if let text = value as? String { return [.text(text)] }
        if allowNull && (value == nil || value is NSNull) { return [] }
        guard let values = value as? [[String: Any]] else { throw invalid("Message content must be text or an ordered content array.") }
        return try values.map { part in
            guard let type = part["type"] as? String else { throw invalid("Content parts require a type.") }
            switch type {
            case "text", "input_text", "output_text":
                guard let text = part["text"] as? String else { throw invalid("Text content requires text.") }; return .text(text)
            case "image_url", "input_image":
                guard let url = (part["image_url"] as? String) ?? (part["image_url"] as? [String: Any])?["url"] as? String, !url.isEmpty else { throw invalid("Image content requires image_url.") }; return .imageURL(url)
            case "input_audio":
                let audio = part["input_audio"] as? [String: Any] ?? part
                guard let data = audio["data"] as? String,
                      let format = audio["format"] as? String, !data.isEmpty, !format.isEmpty else { throw invalid("Audio content requires data and format.") }
                return .inputAudio(data: data, format: format)
            case "audio_url":
                guard let url = (part["audio_url"] as? String) ?? (part["audio_url"] as? [String: Any])?["url"] as? String else { throw invalid("Audio URL content requires a URL.") }; return .audioURL(url)
            default: throw invalid("Unsupported content part: \(type).")
            }
        }
    }

    private static func bool(_ value: Any?, name: String) throws -> Bool? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("\(name) must be a boolean.") }
        return number.boolValue
    }
    private static func integer(_ value: Any?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max) else { throw invalid("\(name) must be a nonnegative integer in range.") }
        return number.intValue
    }
    private static func number(_ value: Any?, name: String) throws -> Double? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid("\(name) must be a finite number.") }
        return number.doubleValue
    }
    private static func invalid(_ message: String) -> MlxCoreError { MlxCoreError("invalid_request", message) }
}

import Foundation
import MlxCore

/// Each awaited event writes immediately; there is no array of precomputed stream events.
actor OpenAIOutput {
    private struct Item {
        enum Kind { case text, reasoning, tool }
        var kind: Kind
        var id: String
        var callID: String = ""
        var name = ""
        var text = ""
    }
    let endpoint: OpenAIEndpoint
    let modelID: String
    let stream: Bool
    let includeUsage: Bool
    let writer: SocketWriter
    let id: String
    let created = Int(Date().timeIntervalSince1970)
    private var items: [Item] = []
    var textIndex: Int?
    var reasoningIndex: Int?
    var toolIndices: [Int: Int] = [:]
    var usage: MlxUsage?
    var reason: MlxGenerationFinishReason?
    var sequence = 0
    var outputBytes = 0
    var begun = false

    init(endpoint: OpenAIEndpoint, modelID: String, stream: Bool, includeUsage: Bool = false, writer: SocketWriter) {
        self.endpoint = endpoint; self.modelID = modelID; self.stream = stream; self.includeUsage = includeUsage; self.writer = writer
        id = (endpoint == .chat ? "chatcmpl_" : "resp_") + UUID().uuidString
    }
    private func begin() async throws {
        guard !begun else { return }
        begun = true
        guard stream else { return }
        try await writer.begin(stream: true)
        switch endpoint {
        case .chat: try await chat(delta: ["role": "assistant"])
        case .responses:
            try await event("response.created", ["response": response(status: "in_progress", output: [])])
            try await event("response.in_progress", ["response": response(status: "in_progress", output: [])])
        }
    }
    func accept(_ value: MlxGenerationEvent) async throws {
        try Task.checkCancellation()
        guard reason == nil else { throw MlxCoreError("invalid_backend_event", "Backend emitted an event after completion.") }
        try await begin()
        switch value {
        case .textDelta(let text): try await append(text, reasoning: false)
        case .reasoningDelta(let text): try await append(text, reasoning: true)
        case .toolCall(let call):
            let existing = items.firstIndex { $0.kind == .tool && $0.callID == call.id }
            let slot: Int
            if let existing { slot = existing }
            else { slot = try await tool(index: (toolIndices.keys.max() ?? -1) + 1, id: call.id, name: call.name) }
            let arguments = jsonString(call.arguments.anyValue)
            // A final structured tool call can accompany deltas; do not duplicate their arguments.
            if items[slot].text.isEmpty { try await toolDelta(slot: slot, index: toolIndices.first(where: { $0.value == slot })?.key ?? slot, text: arguments) }
            else { items[slot].text = arguments }
            items[slot].name = call.name
        case .toolCallDelta(let delta):
            let slot = try await tool(index: delta.index, id: delta.id, name: delta.name)
            try await toolDelta(slot: slot, index: delta.index, text: delta.arguments)
        case .usage(let value): usage = value
        case .completed(let value): reason = value
        }
    }
    private func reserve(_ text: String) throws {
        guard text.utf8.count <= 1024 * 1024, text.utf8.count <= 64 * 1024 * 1024 - outputBytes else {
            throw MlxCoreError("output_too_large", "Backend output exceeded the bounded response limit.")
        }
        outputBytes += text.utf8.count
    }
    private func append(_ text: String, reasoning: Bool) async throws {
        try reserve(text)
        let slot: Int
        if let existing = reasoning ? reasoningIndex : textIndex { slot = existing }
        else {
            slot = items.count
            items.append(Item(kind: reasoning ? .reasoning : .text, id: (reasoning ? "rs_" : "msg_") + UUID().uuidString))
            if reasoning { reasoningIndex = slot } else { textIndex = slot }
            if stream && endpoint == .responses {
                try await event("response.output_item.added", ["output_index": slot, "item": itemObject(slot, done: false)])
                if !reasoning {
                    try await event("response.content_part.added", ["item_id": items[slot].id, "output_index": slot, "content_index": 0, "part": textPart("")])
                }
            }
        }
        items[slot].text += text
        guard stream else { return }
        if endpoint == .chat { try await chat(delta: [reasoning ? "reasoning_content" : "content": text]) }
        else { try await event(reasoning ? "response.reasoning_text.delta" : "response.output_text.delta", ["item_id": items[slot].id, "output_index": slot, "content_index": 0, "delta": text]) }
    }
    private func tool(index: Int, id: String?, name: String?) async throws -> Int {
        guard index >= 0, index < 1024 else { throw MlxCoreError("invalid_backend_event", "Invalid tool-call index.") }
        if let slot = toolIndices[index] {
            if let id { items[slot].callID = id }
            if let name { items[slot].name = name }
            if stream && endpoint == .chat && (id != nil || name != nil) {
                var fields: [String: Any] = ["index": index]
                if let id { fields["id"] = id }
                if let name { fields["function"] = ["name": name] }
                try await chat(delta: ["tool_calls": [fields]])
            }
            return slot
        }
        let slot = items.count
        items.append(Item(kind: .tool, id: "fc_" + UUID().uuidString, callID: id ?? "call_" + UUID().uuidString, name: name ?? ""))
        toolIndices[index] = slot
        if stream {
            if endpoint == .responses { try await event("response.output_item.added", ["output_index": slot, "item": itemObject(slot, done: false)]) }
            else { try await chat(delta: ["tool_calls": [["index": index, "id": items[slot].callID, "type": "function", "function": ["name": items[slot].name, "arguments": ""]]]]) }
        }
        return slot
    }
    private func toolDelta(slot: Int, index: Int, text: String) async throws {
        try reserve(text); items[slot].text += text
        guard stream else { return }
        if endpoint == .chat { try await chat(delta: ["tool_calls": [["index": index, "function": ["arguments": text]]]]) }
        else { try await event("response.function_call_arguments.delta", ["item_id": items[slot].id, "output_index": slot, "delta": text]) }
    }
    func finish() async throws {
        guard let reason else { throw MlxCoreError("incomplete_generation", "Backend ended without a completion event.") }
        if !stream {
            if endpoint == .chat { try await writer.json(chatObject(reason: reason)) }
            else { try await writer.json(response(status: reason == .length ? "incomplete" : "completed")) }
            return
        }
        if endpoint == .chat {
            try await chat(delta: [:], finish: reason.rawValue)
            if includeUsage, let usage { try await writer.bytes(Data("data: \(jsonString(["id": id, "object": "chat.completion.chunk", "created": created, "model": modelID, "choices": [], "usage": usageObject(usage)]))\n\n".utf8)) }
            try await writer.bytes(Data("data: [DONE]\n\n".utf8))
        } else {
            for slot in items.indices {
                let item = items[slot]
                switch item.kind {
                case .text:
                    try await event("response.output_text.done", ["item_id": item.id, "output_index": slot, "content_index": 0, "text": item.text])
                    try await event("response.content_part.done", ["item_id": item.id, "output_index": slot, "content_index": 0, "part": textPart(item.text)])
                case .reasoning:
                    try await event("response.reasoning_text.done", ["item_id": item.id, "output_index": slot, "content_index": 0, "text": item.text])
                case .tool:
                    try await event("response.function_call_arguments.done", ["item_id": item.id, "output_index": slot, "arguments": item.text, "name": item.name])
                }
                try await event("response.output_item.done", ["output_index": slot, "item": itemObject(slot, done: true)])
            }
            let status = reason == .length ? "incomplete" : "completed"
            try await event("response.\(status)", ["response": response(status: status)])
        }
        try await writer.finish()
    }
    private func chat(delta: [String: Any], finish: String? = nil) async throws {
        let object: [String: Any] = ["id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
            "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
        try await writer.bytes(Data("data: \(jsonString(object))\n\n".utf8))
    }
    private func event(_ type: String, _ fields: [String: Any]) async throws {
        sequence += 1
        var object = fields; object["type"] = type; object["sequence_number"] = sequence
        try await writer.bytes(Data("event: \(type)\ndata: \(jsonString(object))\n\n".utf8))
    }
    private func textPart(_ text: String) -> [String: Any] { ["type": "output_text", "text": text, "annotations": []] }
    private func itemObject(_ slot: Int, done: Bool) -> [String: Any] {
        let item = items[slot], status = done ? "completed" : "in_progress"
        switch item.kind {
        case .text: return ["id": item.id, "type": "message", "role": "assistant", "status": status, "content": done ? [textPart(item.text)] : []]
        case .reasoning: return ["id": item.id, "type": "reasoning", "status": status, "summary": [], "content": done ? [["type": "reasoning_text", "text": item.text]] : []]
        case .tool: return ["id": item.id, "type": "function_call", "call_id": item.callID, "name": item.name, "arguments": item.text, "status": status]
        }
    }
    private func usageObject(_ usage: MlxUsage) -> [String: Any] {
        let timings = ["prefill_seconds": usage.promptSeconds, "generation_seconds": usage.generationSeconds]
        if endpoint == .chat { return ["prompt_tokens": usage.promptTokens, "completion_tokens": usage.completionTokens, "total_tokens": usage.totalTokens,
            "prompt_tokens_details": ["cached_tokens": usage.cachedTokens], "completion_tokens_details": ["reasoning_tokens": usage.reasoningTokens], "timings": timings] }
        return ["input_tokens": usage.promptTokens, "output_tokens": usage.completionTokens, "total_tokens": usage.totalTokens,
            "input_tokens_details": ["cached_tokens": usage.cachedTokens], "output_tokens_details": ["reasoning_tokens": usage.reasoningTokens], "timings": timings]
    }
    private func response(status: String, output: [[String: Any]]? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "object": "response", "created_at": created, "model": modelID, "status": status,
            "output": output ?? items.indices.map { itemObject($0, done: true) }, "output_text": items.filter { $0.kind == .text }.map(\.text).joined(),
            "parallel_tool_calls": false, "tool_choice": "auto", "usage": usage.map(usageObject) as Any? ?? NSNull()]
        result["incomplete_details"] = status == "incomplete" ? ["reason": "max_output_tokens"] : NSNull()
        return result
    }
    private func chatObject(reason: MlxGenerationFinishReason) -> [String: Any] {
        let text = items.filter { $0.kind == .text }.map(\.text).joined()
        let reasoning = items.filter { $0.kind == .reasoning }.map(\.text).joined()
        let tools = items.filter { $0.kind == .tool }
        var message: [String: Any] = ["role": "assistant", "content": text.isEmpty && !tools.isEmpty ? NSNull() : text as Any]
        if !reasoning.isEmpty { message["reasoning_content"] = reasoning }
        if !tools.isEmpty { message["tool_calls"] = tools.map { ["id": $0.callID, "type": "function", "function": ["name": $0.name, "arguments": $0.text]] } }
        return ["id": id, "object": "chat.completion", "created": created, "model": modelID,
            "choices": [["index": 0, "message": message, "finish_reason": reason.rawValue]], "usage": usage.map(usageObject) as Any? ?? NSNull()]
    }
}

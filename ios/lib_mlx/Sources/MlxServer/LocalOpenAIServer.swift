import Foundation
import MlxCore
import Network

public struct MlxServerConfig: Sendable {
    public let host: String
    public let port: UInt16
    public let modelId: String
    public let queueLimit: Int

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 0,
        modelId: String,
        queueLimit: Int = 1
    ) {
        self.host = host
        self.port = port
        self.modelId = modelId
        self.queueLimit = queueLimit
    }
}

public struct MlxServerRuntimeInfo: Sendable {
    public let host: String
    public let port: UInt16
    public let modelId: String

    public var baseURL: String {
        "http://\(host):\(port)"
    }
}

public enum MlxServerError: Error {
    case invalidPort(UInt16)
    case startTimedOut
}

public final class LocalOpenAIServer: @unchecked Sendable {
    private let model: MlxResidentModel
    private let queue = DispatchQueue(label: "app.gsmlg.lib_mlx.local-openai-server")
    private var listener: NWListener?
    private var activeGeneration = false
    private var config: MlxServerConfig?

    public init(model: MlxResidentModel) {
        self.model = model
    }

    public var isRunning: Bool {
        listener != nil
    }

    public func start(config: MlxServerConfig) throws -> MlxServerRuntimeInfo {
        if let listener, let current = self.config {
            return MlxServerRuntimeInfo(
                host: current.host,
                port: listener.port?.rawValue ?? current.port,
                modelId: current.modelId
            )
        }

        let requestedPort: NWEndpoint.Port
        if config.port == 0 {
            requestedPort = .any
        } else if let nwPort = NWEndpoint.Port(rawValue: config.port) {
            requestedPort = nwPort
        } else {
            throw MlxServerError.invalidPort(config.port)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: requestedPort)
        let ready = DispatchSemaphore(value: 0)
        var failed: NWError?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case let .failed(error):
                failed = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        let timeout = ready.wait(timeout: .now() + 2)
        if timeout == .timedOut {
            listener.cancel()
            throw MlxServerError.startTimedOut
        }
        if let failed {
            listener.cancel()
            throw failed
        }

        self.listener = listener
        self.config = config
        return MlxServerRuntimeInfo(
            host: config.host,
            port: listener.port?.rawValue ?? config.port,
            modelId: config.modelId
        )
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        config = nil
        activeGeneration = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil || complete {
                connection.cancel()
                return
            }

            var next = accumulated
            if let data {
                next.append(data)
            }

            if let request = HTTPRequest.parse(next) {
                let response = self.handle(request)
                self.send(response, on: connection)
                return
            }

            self.receive(on: connection, accumulated: next)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "POST" else {
            return .json(status: 405, object: errorObject("method_not_allowed", "Only GET and POST are supported."))
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            return .json(status: 200, object: modelsObject())
        case ("POST", "/v1/chat/completions"):
            return guardedGeneration(request: request, endpoint: .chatCompletions)
        case ("POST", "/v1/responses"):
            return guardedGeneration(request: request, endpoint: .responses)
        default:
            return .json(status: 404, object: errorObject("not_found", "Endpoint not found."))
        }
    }

    private enum Endpoint {
        case chatCompletions
        case responses
    }

    private func guardedGeneration(request: HTTPRequest, endpoint: Endpoint) -> HTTPResponse {
        if activeGeneration {
            return .json(status: 429, object: errorObject("queue_full", "Another generation is already in flight."))
        }

        activeGeneration = true
        defer { activeGeneration = false }

        guard let body = request.jsonBody else {
            return .json(status: 400, object: errorObject("invalid_json", "Request body must be a JSON object."))
        }

        let generationRequest = makeGenerationRequest(from: body, endpoint: endpoint)
        let events = model.generate(request: generationRequest)
        let stream = body["stream"] as? Bool == true

        switch endpoint {
        case .chatCompletions:
            return stream ? chatCompletionStream(events: events) : .json(status: 200, object: chatCompletionObject(events: events))
        case .responses:
            return stream ? responsesStream(events: events) : .json(status: 200, object: responseObject(events: events))
        }
    }

    private func makeGenerationRequest(from body: [String: Any], endpoint: Endpoint) -> MlxGenerationRequest {
        let maxTokens = body["max_tokens"] as? Int ?? body["max_output_tokens"] as? Int ?? 256
        let temperature = body["temperature"] as? Double ?? 0
        let thinkingEnabled = (body["thinking"] as? Bool) ?? ((body["reasoning"] as? [String: Any]) != nil)
        let tools = (body["tools"] as? [[String: Any]] ?? []).map { $0.mapValues { SendableValue(any: $0) } }

        switch endpoint {
        case .chatCompletions:
            let messages = (body["messages"] as? [[String: Any]] ?? []).map { message -> MlxChatMessage in
                MlxChatMessage(
                    role: message["role"] as? String ?? "user",
                    text: text(fromChatContent: message["content"])
                )
            }
            return MlxGenerationRequest(
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                thinkingEnabled: thinkingEnabled
            )
        case .responses:
            return MlxGenerationRequest(
                prompt: text(fromResponsesInput: body["input"]),
                tools: tools,
                maxTokens: maxTokens,
                temperature: temperature,
                thinkingEnabled: thinkingEnabled
            )
        }
    }

    private func text(fromChatContent value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if part["type"] as? String == "text" {
                    return part["text"] as? String
                }
                if let text = part["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func text(fromResponsesInput value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let items = value as? [[String: Any]] {
            return items.compactMap { item in
                if let content = item["content"] as? String {
                    return content
                }
                if let content = item["content"] as? [[String: Any]] {
                    return content.compactMap { part in
                        part["text"] as? String
                    }.joined(separator: "\n")
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func modelsObject() -> [String: Any] {
        [
            "object": "list",
            "data": [[
                "id": modelId,
                "object": "model",
                "created": timestamp,
                "owned_by": "local"
            ]]
        ]
    }

    private func chatCompletionObject(events: [MlxGenerationEvent]) -> [String: Any] {
        let collapsed = CollapsedEvents(events)
        var message: [String: Any] = [
            "role": "assistant",
            "content": collapsed.text.isEmpty && !collapsed.toolCalls.isEmpty ? NSNull() : collapsed.text
        ]
        if !collapsed.reasoning.isEmpty {
            message["reasoning_content"] = collapsed.reasoning
        }
        if !collapsed.toolCalls.isEmpty {
            message["tool_calls"] = collapsed.toolCalls.map(chatToolCallObject)
        }

        return [
            "id": "chatcmpl_\(UUID().uuidString)",
            "object": "chat.completion",
            "created": timestamp,
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": collapsed.finishReason.rawValue
            ]],
            "usage": usageObject(outputText: collapsed.text)
        ]
    }

    private func chatCompletionStream(events: [MlxGenerationEvent]) -> HTTPResponse {
        let id = "chatcmpl_\(UUID().uuidString)"
        var chunks: [[String: Any]] = [[
            "id": id,
            "object": "chat.completion.chunk",
            "created": timestamp,
            "model": modelId,
            "choices": [[
                "index": 0,
                "delta": ["role": "assistant"],
                "finish_reason": NSNull()
            ]]
        ]]

        for event in events {
            switch event {
            case let .reasoningDelta(text):
                chunks.append(chatDeltaChunk(id: id, delta: ["reasoning_content": text], finishReason: nil))
            case let .textDelta(text):
                chunks.append(chatDeltaChunk(id: id, delta: ["content": text], finishReason: nil))
            case let .toolCall(toolCall):
                chunks.append(chatDeltaChunk(id: id, delta: ["tool_calls": [chatToolCallDelta(toolCall)]], finishReason: nil))
            case let .completed(reason):
                chunks.append(chatDeltaChunk(id: id, delta: [:], finishReason: reason.rawValue))
            }
        }

        var payload = chunks.map { "data: \(jsonString($0))\n\n" }.joined()
        payload += "data: [DONE]\n\n"
        return .sse(payload)
    }

    private func chatDeltaChunk(id: String, delta: [String: Any], finishReason: String?) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": timestamp,
            "model": modelId,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason.map { $0 as Any } ?? NSNull()
            ]]
        ]
    }

    private func responseObject(events: [MlxGenerationEvent]) -> [String: Any] {
        let collapsed = CollapsedEvents(events)
        return responseObject(collapsed: collapsed)
    }

    private func responseObject(
        collapsed: CollapsedEvents,
        responseId: String = "resp_\(UUID().uuidString)",
        createdAt: Int? = nil,
        outputItems: [[String: Any]]? = nil
    ) -> [String: Any] {
        let output = outputItems ?? responseOutputItems(collapsed: collapsed)
        return [
            "id": responseId,
            "object": "response",
            "created_at": createdAt ?? timestamp,
            "model": modelId,
            "status": "completed",
            "output": output,
            "output_text": collapsed.text,
            "parallel_tool_calls": false,
            "reasoning": [
                "effort": NSNull(),
                "summary": NSNull()
            ],
            "tool_choice": "auto",
            "usage": usageObject(outputText: collapsed.text, reasoningText: collapsed.reasoning)
        ]
    }

    private func responsesStream(events: [MlxGenerationEvent]) -> HTTPResponse {
        let collapsed = CollapsedEvents(events)
        let responseId = "resp_\(UUID().uuidString)"
        let createdAt = timestamp
        var builder = ResponsesStreamBuilder()
        var outputIndex = 0
        var finalOutputItems: [[String: Any]] = []

        builder.append("response.created", [
            "type": "response.created",
            "response": [
                "id": responseId,
                "object": "response",
                "created_at": createdAt,
                "model": modelId,
                "status": "in_progress",
                "output": [],
                "parallel_tool_calls": false,
                "reasoning": [
                    "effort": NSNull(),
                    "summary": NSNull()
                ],
                "tool_choice": "auto",
                "usage": NSNull()
            ]
        ])

        if !collapsed.reasoning.isEmpty {
            let itemId = "rs_\(UUID().uuidString)"
            let finalItem = responseReasoningItem(
                id: itemId,
                text: collapsed.reasoning,
                status: "completed"
            )

            builder.append("response.output_item.added", [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": responseReasoningItem(id: itemId, text: nil, status: "in_progress")
            ])
            builder.append("response.reasoning_text.delta", [
                "type": "response.reasoning_text.delta",
                "delta": collapsed.reasoning,
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0
            ])
            builder.append("response.reasoning_text.done", [
                "type": "response.reasoning_text.done",
                "text": collapsed.reasoning,
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0
            ])
            builder.append("response.output_item.done", [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": finalItem
            ])

            finalOutputItems.append(finalItem)
            outputIndex += 1
        }

        if !collapsed.text.isEmpty {
            let itemId = "msg_\(UUID().uuidString)"
            let finalItem = responseMessageItem(id: itemId, text: collapsed.text, status: "completed")

            builder.append("response.output_item.added", [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": responseMessageItem(id: itemId, text: nil, status: "in_progress")
            ])
            builder.append("response.content_part.added", [
                "type": "response.content_part.added",
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0,
                "part": responseOutputTextPart(text: "")
            ])
            builder.append("response.output_text.delta", [
                "type": "response.output_text.delta",
                "delta": collapsed.text,
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0
            ])
            builder.append("response.output_text.done", [
                "type": "response.output_text.done",
                "text": collapsed.text,
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0
            ])
            builder.append("response.content_part.done", [
                "type": "response.content_part.done",
                "item_id": itemId,
                "output_index": outputIndex,
                "content_index": 0,
                "part": responseOutputTextPart(text: collapsed.text)
            ])
            builder.append("response.output_item.done", [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": finalItem
            ])

            finalOutputItems.append(finalItem)
            outputIndex += 1
        }

        for toolCall in collapsed.toolCalls {
            let finalItem = responseToolCallObject(toolCall, status: "completed")
            builder.append("response.output_item.added", [
                "type": "response.output_item.added",
                "output_index": outputIndex,
                "item": responseToolCallObject(toolCall, status: "in_progress", arguments: "")
            ])
            builder.append("response.function_call_arguments.delta", [
                "type": "response.function_call_arguments.delta",
                "delta": jsonString(toolCall.arguments),
                "item_id": toolCall.id,
                "output_index": outputIndex
            ])
            builder.append("response.function_call_arguments.done", [
                "type": "response.function_call_arguments.done",
                "arguments": jsonString(toolCall.arguments),
                "name": toolCall.name,
                "item_id": toolCall.id,
                "output_index": outputIndex
            ])
            builder.append("response.output_item.done", [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": finalItem
            ])

            finalOutputItems.append(finalItem)
            outputIndex += 1
        }

        let response = responseObject(
            collapsed: collapsed,
            responseId: responseId,
            createdAt: createdAt,
            outputItems: finalOutputItems
        )
        builder.append("response.completed", [
            "type": "response.completed",
            "response": response
        ])
        return .sse(builder.payload)
    }

    private func responseOutputItems(collapsed: CollapsedEvents) -> [[String: Any]] {
        var output: [[String: Any]] = []

        if !collapsed.reasoning.isEmpty {
            output.append(responseReasoningItem(
                id: "rs_\(UUID().uuidString)",
                text: collapsed.reasoning,
                status: "completed"
            ))
        }

        if !collapsed.text.isEmpty {
            output.append(responseMessageItem(
                id: "msg_\(UUID().uuidString)",
                text: collapsed.text,
                status: "completed"
            ))
        }

        for toolCall in collapsed.toolCalls {
            output.append(responseToolCallObject(toolCall, status: "completed"))
        }

        return output
    }

    private func chatToolCallObject(_ toolCall: MlxToolCall) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function",
            "function": [
                "name": toolCall.name,
                "arguments": jsonString(toolCall.arguments)
            ]
        ]
    }

    private func chatToolCallDelta(_ toolCall: MlxToolCall) -> [String: Any] {
        [
            "index": 0,
            "id": toolCall.id,
            "type": "function",
            "function": [
                "name": toolCall.name,
                "arguments": jsonString(toolCall.arguments)
            ]
        ]
    }

    private func responseReasoningItem(id: String, text: String?, status: String) -> [String: Any] {
        [
            "id": id,
            "type": "reasoning",
            "status": status,
            "content": text.map {
                [[
                    "type": "reasoning_text",
                    "text": $0
                ]]
            } ?? [],
            "summary": []
        ]
    }

    private func responseMessageItem(id: String, text: String?, status: String) -> [String: Any] {
        [
            "id": id,
            "type": "message",
            "role": "assistant",
            "status": status,
            "content": text.map {
                [responseOutputTextPart(text: $0)]
            } ?? []
        ]
    }

    private func responseOutputTextPart(text: String) -> [String: Any] {
        [
            "type": "output_text",
            "text": text,
            "annotations": []
        ]
    }

    private func responseToolCallObject(
        _ toolCall: MlxToolCall,
        status: String,
        arguments: String? = nil
    ) -> [String: Any] {
        [
            "id": toolCall.id,
            "type": "function_call",
            "status": status,
            "call_id": toolCall.id,
            "name": toolCall.name,
            "arguments": arguments ?? jsonString(toolCall.arguments)
        ]
    }

    private func usageObject(outputText: String, reasoningText: String = "") -> [String: Any] {
        let outputTokens = tokenCount(outputText)
        let reasoningTokens = reasoningText.isEmpty ? 0 : tokenCount(reasoningText)
        return [
            "input_tokens": 0,
            "output_tokens": outputTokens + reasoningTokens,
            "output_tokens_details": [
                "reasoning_tokens": reasoningTokens
            ],
            "total_tokens": outputTokens + reasoningTokens
        ]
    }

    private func tokenCount(_ text: String) -> Int {
        max(1, text.split(separator: " ").count)
    }

    private func errorObject(_ code: String, _ message: String) -> [String: Any] {
        [
            "error": [
                "message": message,
                "type": "invalid_request_error",
                "code": code
            ]
        ]
    }

    private var modelId: String {
        config?.modelId ?? model.config.modelId
    }

    private var timestamp: Int {
        Int(Date().timeIntervalSince1970)
    }
}

private struct CollapsedEvents {
    let text: String
    let reasoning: String
    let toolCalls: [MlxToolCall]
    let finishReason: MlxGenerationFinishReason

    init(_ events: [MlxGenerationEvent]) {
        var text = ""
        var reasoning = ""
        var toolCalls: [MlxToolCall] = []
        var finishReason = MlxGenerationFinishReason.stop

        for event in events {
            switch event {
            case let .textDelta(delta):
                text += delta
            case let .reasoningDelta(delta):
                reasoning += delta
            case let .toolCall(toolCall):
                toolCalls.append(toolCall)
            case let .completed(reason):
                finishReason = reason
            }
        }

        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.finishReason = finishReason
    }
}

private struct ResponsesStreamBuilder {
    private(set) var payload = ""
    private var sequenceNumber = 0

    mutating func append(_ event: String, _ object: [String: Any]) {
        sequenceNumber += 1
        var object = object
        object["sequence_number"] = sequenceNumber
        payload += sseEvent(event, object)
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let startLine = lines.first else {
            return nil
        }

        let startParts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard startParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            headers[pieces[0].lowercased()] = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bodyStart = separator.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else {
            return nil
        }

        let path = startParts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? startParts[1]
        return HTTPRequest(
            method: startParts[0],
            path: path,
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + contentLength)])
        )
    }
}

private struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(status: Int, object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: Data(jsonString(object).utf8))
    }

    static func sse(_ payload: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/event-stream", body: Data(payload.utf8))
    }

    func serialized() -> Data {
        let reason = statusReason(status)
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store\r\n"
        headers += "Connection: close\r\n\r\n"

        var output = Data(headers.utf8)
        output.append(body)
        return output
    }

    private func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        default: return "Internal Server Error"
        }
    }
}

private func sseEvent(_ event: String, _ object: [String: Any]) -> String {
    "event: \(event)\ndata: \(jsonString(object))\n\n"
}

private func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

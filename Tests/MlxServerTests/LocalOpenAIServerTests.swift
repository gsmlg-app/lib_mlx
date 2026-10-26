import Foundation
import Darwin
import MlxCore
@testable import MlxServer
import XCTest

final class LocalOpenAIServerTests: XCTestCase {
    func testLoopbackBindingAliasAndIdempotentStartStop() throws {
        let server = immediateServer()
        XCTAssertThrowsError(try server.start(config: .init(host: "0.0.0.0")))
        let first = try server.start(config: .init(host: "localhost"))
        XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertNotEqual(first.port, 0)
        XCTAssertEqual(first.modelId, "resident-id")
        XCTAssertEqual(try server.start(config: .init(port: 42, modelId: "ignored")).port, first.port)
        server.stop(); server.stop()
        XCTAssertFalse(server.isRunning)
        let restarted = try server.start(config: .init(modelId: "public-alias"))
        XCTAssertEqual(restarted.modelId, "public-alias")
        let models = try RawSocket(port: restarted.port)
        try models.write("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let response = try models.readToEnd()
        XCTAssertTrue(response.contains("\"id\":\"public-alias\""))
        XCTAssertTrue(response.contains("\"resident_model_id\":\"resident-id\""))
        server.stop()
    }

    func testConcurrentStartAndStopAreIdempotent() throws {
        let server = immediateServer()
        let lock = NSLock()
        var ports: [UInt16] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let info = try server.start(config: .init())
                lock.lock(); ports.append(info.port); lock.unlock()
            } catch { XCTFail("Concurrent start failed: \(error)") }
        }
        XCTAssertEqual(Set(ports).count, 1)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in server.stop() }
        XCTAssertFalse(server.isRunning)
        XCTAssertThrowsError(try server.start(config: .init(headerTimeout: 1e20)))
        XCTAssertThrowsError(try server.start(config: .init(requestTimeout: Double.greatestFiniteMagnitude)))
        XCTAssertThrowsError(try server.start(config: .init(writeTimeout: 86_401)))
    }

    func testFragmentedContentLengthAndChunkedRequests() throws {
        let server = immediateServer()
        let info = try server.start(config: .init())
        defer { server.stop() }
        let json = #"{"messages":[{"role":"user","content":"hello"}]}"#
        let fixed = try RawSocket(port: info.port)
        try fixed.write("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(json.utf8.count)\r\n\r\n")
        for part in json.utf8 { try fixed.write(Data([part])) }
        let fixedResponse = try fixed.readToEnd()
        XCTAssertTrue(fixedResponse.contains("200 OK"), fixedResponse)
        XCTAssertTrue(fixedResponse.contains("hello from backend"), fixedResponse)
        let chunked = try RawSocket(port: info.port)
        try chunked.write("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
        let halves = [String(json.prefix(12)), String(json.dropFirst(12))]
        for part in halves { try chunked.write("\(String(part.utf8.count, radix: 16))\r\n\(part)\r\n") }
        try chunked.write("0\r\n\r\n")
        XCTAssertTrue(try chunked.readToEnd().contains("hello from backend"))
    }

    func testLegitimateLargeContextAndChunkedBodyLimit() throws {
        let server = immediateServer()
        let info = try server.start(config: .init(maximumBodyBytes: 256 * 1024))
        defer { server.stop() }
        let large = try RawSocket(port: info.port)
        try large.post(body: "{\"messages\":[{\"role\":\"user\",\"content\":\"\(String(repeating: "x", count: 128 * 1024))\"}]}")
        XCTAssertTrue(try large.readToEnd().contains("200 OK"))
        let chunked = try RawSocket(port: info.port)
        try chunked.write("POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n50000\r\n")
        try chunked.write(String(repeating: "x", count: 256 * 1024 + 1))
        XCTAssertTrue(try chunked.readToEnd().contains("413"))
    }

    func testFramingRejectsInvalidLengthsAndConflicts() throws {
        let server = immediateServer()
        let info = try server.start(config: .init())
        defer { server.stop() }
        for fields in ["Content-Length: -1", "Content-Length: 999999999999999999999999999999", "Content-Length: 1\r\nContent-Length: 2", "Content-Length: 1\r\nTransfer-Encoding: chunked"] {
            let socket = try RawSocket(port: info.port)
            try socket.write("POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\n\(fields)\r\n\r\nx")
            let response = try socket.readToEnd()
            XCTAssertTrue(response.contains("400 Bad Request"), response)
        }
    }

    func testFragmentedTrailersShareHeaderLimitAndWireMetadataIsBounded() throws {
        let server = immediateServer()
        let info = try server.start(config: .init(maximumBodyBytes: 256, maximumHeaderBytes: 256))
        defer { server.stop() }
        let json = #"{"messages":[{"role":"user","content":"hello"}]}"#
        let prefix = "POST /v1/chat/completions HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\(String(json.utf8.count, radix: 16))\r\n\(json)\r\n0\r\n"
        let valid = try RawSocket(port: info.port)
        try valid.write(prefix)
        for fragment in ["X-Test", ": ok\r", "\n", "\r\n"] { try valid.write(fragment) }
        XCTAssertTrue(try valid.readToEnd().contains("200 OK"))
        let oversized = try RawSocket(port: info.port)
        try oversized.write(prefix)
        for _ in 0..<20 { try oversized.write("X-Long: 1234567890\r\n") }
        try oversized.write("\r\n")
        XCTAssertTrue(try oversized.readToEnd().contains("431"))
        let incomplete = try RawSocket(port: info.port)
        try incomplete.write(prefix)
        // Many incomplete trailer fields remain decoder-owned. The absolute wire/metadata
        // limit must reject them without waiting for a final CRLF or the request timer.
        let flood = String(repeating: "X-Long: \(String(repeating: "x", count: 1024))\r\n", count: 1100)
        try? incomplete.write(flood)
        // An upload rejected while peer bytes remain can reset TCP after the
        // error is delivered. Require the actual status before reading EOF.
        XCTAssertTrue(try incomplete.read(until: "431").contains("431"))
    }

    func testBodyHeaderAndIncompleteRequestTimeoutLimits() throws {
        let server = immediateServer()
        let info = try server.start(config: .init(maximumBodyBytes: 32, maximumHeaderBytes: 128, headerTimeout: 0.1, requestTimeout: 0.1))
        defer { server.stop() }
        let oversized = try RawSocket(port: info.port)
        try oversized.write("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 100\r\n\r\n")
        XCTAssertTrue(try oversized.readToEnd().contains("400 Bad Request"))
        let header = try RawSocket(port: info.port)
        try header.write("GET /v1/models HTTP/1.1\r\nX-Large: \(String(repeating: "a", count: 150))\r\n\r\n")
        XCTAssertTrue(try header.readToEnd().contains("431"))
        let incompleteHeader = try RawSocket(port: info.port)
        try incompleteHeader.write("GET /v1/models HTTP/1.1\r\n")
        XCTAssertTrue(try incompleteHeader.readToEnd().contains("408"))
        let incompleteBody = try RawSocket(port: info.port)
        try incompleteBody.write("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 20\r\n\r\nx")
        XCTAssertTrue(try incompleteBody.readToEnd().contains("408"))
    }

    func testStreamingArrivesBeforeBackendCompletionAndUsageIsMeasured() async throws {
        let control = ControlledBackend()
        let server = LocalOpenAIServer(generate: { request, emit in try await control.generate(request, emit: emit) })
        let info = try server.start(config: .init())
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        try socket.post(body: #"{"stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hello"}]}"#)
        let first = try socket.read(until: "first-delta")
        XCTAssertTrue(first.contains("text/event-stream"))
        XCTAssertFalse(first.contains("[DONE]"))
        let started = await control.started
        XCTAssertEqual(started, 1)
        await control.release()
        let end = try socket.readToEnd()
        XCTAssertTrue(end.contains("second-delta"))
        XCTAssertTrue(end.contains("[DONE]"))
        XCTAssertTrue(end.contains("\"prompt_tokens\":7"))
        XCTAssertTrue(end.contains("\"completion_tokens\":2"))
    }

    func testChatStreamUsageRequiresExplicitOptIn() throws {
        let server = immediateServer()
        let info = try server.start(config: .init())
        defer { server.stop() }
        for includeUsage in [nil, false, true] as [Bool?] {
            let socket = try RawSocket(port: info.port)
            var body: [String: Any] = ["stream": true, "messages": [["role": "user", "content": "hello"]]]
            if let includeUsage { body["stream_options"] = ["include_usage": includeUsage] }
            try socket.post(body: String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self))
            let response = try socket.readToEnd()
            XCTAssertTrue(response.contains("200 OK"))
            XCTAssertTrue(response.contains("data: [DONE]"))
            XCTAssertEqual(response.contains("\"usage\":"), includeUsage == true)
            if includeUsage == true {
                XCTAssertTrue(response.contains("\"prompt_tokens\":7"))
                XCTAssertTrue(response.contains("\"completion_tokens\":3"))
            }
        }
    }

    func testNonstreamAndResponsesUsageAreUnaffectedByChatOptIn() throws {
        let server = immediateServer()
        let info = try server.start(config: .init())
        defer { server.stop() }
        let chat = try RawSocket(port: info.port)
        try chat.post()
        let chatResponse = try chat.readToEnd()
        XCTAssertTrue(chatResponse.contains("\"prompt_tokens\":7"))
        XCTAssertTrue(chatResponse.contains("\"completion_tokens\":3"))
        let responses = try RawSocket(port: info.port)
        try responses.post(body: #"{"stream":true,"stream_options":{"include_usage":false},"input":"hello"}"#, path: "/v1/responses")
        let response = try responses.readToEnd()
        XCTAssertTrue(response.contains("event: response.completed"))
        XCTAssertTrue(response.contains("\"input_tokens\":7"))
        XCTAssertTrue(response.contains("\"output_tokens\":3"))
    }

    func testRequestConversionPreservesUsageOptIn() throws {
        for includeUsage in [nil, false, true] as [Bool?] {
            var body: [String: Any] = ["stream": true, "messages": [["role": "user", "content": "hello"]]]
            if let includeUsage { body["stream_options"] = ["include_usage": includeUsage] }
            let converted = try OpenAIRequest.convert(data: JSONSerialization.data(withJSONObject: body), endpoint: .chat, modelID: "test-model")
            XCTAssertEqual(converted.includeUsage, includeUsage ?? false)
        }
    }

    func testWaitingQueueExcludesActiveAndCancelledWaiterIsRemoved() async throws {
        let control = ControlledBackend()
        let server = LocalOpenAIServer(generate: { request, emit in try await control.generate(request, emit: emit) })
        let info = try server.start(config: .init(queueLimit: 1))
        defer { server.stop() }
        let active = try RawSocket(port: info.port); try active.post(stream: true)
        _ = try active.read(until: "first-delta")
        let waiting = try RawSocket(port: info.port); try waiting.post(stream: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        let overflow = try RawSocket(port: info.port); try overflow.post(stream: true)
        XCTAssertTrue(try overflow.readToEnd().contains("429 Too Many Requests"))
        waiting.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        let replacement = try RawSocket(port: info.port); try replacement.post(stream: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        let count = await control.started; XCTAssertEqual(count, 1)
        active.close()
        _ = try replacement.read(until: "first-delta")
        let replacements = await control.started; XCTAssertEqual(replacements, 2)
        replacement.close()
    }

    func testDisconnectAndStopAwaitCancellationAndCloseAcceptedSockets() async throws {
        let control = ControlledBackend()
        let server = LocalOpenAIServer(generate: { request, emit in try await control.generate(request, emit: emit) })
        let info = try server.start(config: .init())
        let active = try RawSocket(port: info.port); try active.post(stream: true)
        _ = try active.read(until: "first-delta")
        let idle = try RawSocket(port: info.port)
        server.stop()
        let finished = await control.finished; XCTAssertEqual(finished, 1)
        XCTAssertEqual(try idle.readToEnd(), "")
        XCTAssertFalse(server.isRunning)
    }

    func testSlowConsumerIsBoundedAndStopUnwindsPendingWrite() async throws {
        let counter = SaturatingBackend()
        let server = LocalOpenAIServer(generate: { request, emit in try await counter.generate(request, emit: emit) })
        let info = try server.start(config: .init(writeTimeout: 0.1))
        let socket = try RawSocket(port: info.port, receiveBuffer: 1024)
        try socket.post(stream: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(before), 2)
        let sent = await counter.sent
        let finished = await counter.finished
        XCTAssertGreaterThan(sent, 0)
        XCTAssertLessThan(sent, 2048, "Awaited writes must stop production before the response memory cap.")
        XCTAssertTrue(finished)
    }

    func testManyIncrementalDeltasAreNotLost() throws {
        let server = LocalOpenAIServer { _, emit in
            for index in 0..<500 { try await emit(.textDelta("token-\(index);")) }
            try await emit(.completed(.stop))
        }
        let info = try server.start(config: .init())
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        try socket.post(stream: true)
        let response = try socket.readToEnd()
        for index in 0..<500 { XCTAssertTrue(response.contains("token-\(index);")) }
        XCTAssertEqual(response.components(separatedBy: "data: [DONE]").count, 2)
    }

    func testLargeResponsesCompletionUsesBoundedWrites() throws {
        let server = LocalOpenAIServer { _, emit in
            for _ in 0..<40 { try await emit(.textDelta(String(repeating: "x", count: 32 * 1024))) }
            try await emit(.completed(.stop))
        }
        let info = try server.start(config: .init())
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        try socket.post(body: #"{"stream":true,"input":"hello"}"#, path: "/v1/responses")
        let response = try socket.readToEnd()
        XCTAssertTrue(response.contains("event: response.completed"))
        XCTAssertFalse(response.contains("event: error"))
        XCTAssertGreaterThan(response.utf8.count, 1024 * 1024)
    }

    func testBackendAdmissionErrorKeepsHTTPStatusAndCodeBeforeSSEStarts() throws {
        let server = LocalOpenAIServer { _, _ in
            throw MlxCoreError("context_length_exceeded", "Prompt exceeds device context budget.")
        }
        let info = try server.start(config: .init())
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        try socket.post(stream: true)
        let response = try socket.readToEnd()
        XCTAssertTrue(response.contains("400 Bad Request"))
        XCTAssertTrue(response.contains("context_length_exceeded"))
        XCTAssertFalse(response.contains("text/event-stream"))
    }

    func testConnectionBoundClosesExcessAcceptedSockets() throws {
        let server = immediateServer()
        let info = try server.start(config: .init(maximumConnections: 1))
        defer { server.stop() }
        let held = try RawSocket(port: info.port)
        try held.write("GET /v1/models HTTP/1.1\r\n")
        let excess = try RawSocket(port: info.port)
        do {
            let response = try excess.readToEnd()
            XCTAssertEqual(response, "")
        }
        catch let error as POSIXError { XCTAssertEqual(error.code, .ECONNRESET) }
        // A rejected socket must not close the listener or disturb an admitted peer.
        try held.write("Host: localhost\r\n\r\n")
        XCTAssertTrue(try held.readToEnd().contains("200 OK"))
        let replacement = try RawSocket(port: info.port)
        try replacement.write("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertTrue(try replacement.readToEnd().contains("200 OK"))
    }

    func testWrongModelUnsupportedAndMalformedParametersAreRejected() throws {
        let server = immediateServer()
        let info = try server.start(config: .init())
        defer { server.stop() }
        for extra in ["\"model\":\"wrong\",", "\"temperature\":true,", "\"max_tokens\":-1,", "\"n\":2,", "\"top_p\":2,"] {
            let socket = try RawSocket(port: info.port)
            try socket.post(body: "{\(extra)\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}")
            XCTAssertTrue(try socket.readToEnd().contains("400 Bad Request"))
        }
    }

    func testPureConversionPreservesOrderInstructionsPartsAndTypedToolValues() throws {
        let body: [String: Any] = ["instructions": "system instruction", "input": [
            ["role": "system", "content": "first"],
            ["role": "user", "content": [["type": "input_text", "text": "before"], ["type": "input_image", "image_url": "data:image/png;base64,abc"], ["type": "input_audio", "data": "abc", "format": "wav"], ["type": "input_text", "text": "after"]]],
            ["type": "function_call", "call_id": "call-1", "name": "f", "arguments": #"{"integer":1,"boolean":true,"decimal":1.5,"array":[null,2]}"#],
            ["type": "function_call_output", "call_id": "call-1", "output": "result"],
            ["role": "assistant", "content": "last", "reasoning_content": "template decides retention"]
        ]]
        let result = try OpenAIRequest.convert(data: JSONSerialization.data(withJSONObject: body), endpoint: .responses, modelID: "resident-id").request
        XCTAssertEqual(result.instructions, "system instruction")
        XCTAssertEqual(result.messages.map(\.role), ["system", "user", "assistant", "tool", "assistant"])
        XCTAssertEqual(result.messages[1].content, [.text("before"), .imageURL("data:image/png;base64,abc"), .inputAudio(data: "abc", format: "wav"), .text("after")])
        XCTAssertEqual(result.messages[3].toolCallID, "call-1")
        XCTAssertEqual(result.messages[4].reasoningContent, "template decides retention")
        XCTAssertEqual(result.messages[2].toolCalls.first?.arguments, .object(["integer": .int(1), "boolean": .bool(true), "decimal": .double(1.5), "array": .array([.null, .int(2)])]))
    }

    func testResponsesUsesOrderedLifecycleAndToolArgumentDeltas() throws {
        let server = LocalOpenAIServer { _, emit in
            try await emit(.reasoningDelta("consider"))
            try await emit(.textDelta("answer"))
            try await emit(.toolCallDelta(.init(index: 0, id: "call-real", name: "weather", arguments: "{\"city\":")))
            try await emit(.toolCallDelta(.init(index: 0, arguments: "\"Paris\"}")))
            try await emit(.usage(.init(promptTokens: 3, completionTokens: 4)))
            try await emit(.completed(.toolCalls))
        }
        let info = try server.start(config: .init())
        defer { server.stop() }
        let socket = try RawSocket(port: info.port)
        try socket.post(body: #"{"stream":true,"input":"hello"}"#, path: "/v1/responses")
        let response = try socket.readToEnd()
        XCTAssertTrue(response.contains("response.created"))
        XCTAssertTrue(response.contains("response.reasoning_text.delta"))
        XCTAssertTrue(response.contains("response.output_text.delta"))
        XCTAssertTrue(response.contains("response.function_call_arguments.delta"))
        XCTAssertTrue(response.contains("response.function_call_arguments.done"))
        XCTAssertTrue(response.contains("response.completed"))
        XCTAssertTrue(response.contains("call-real"))
    }

    private func immediateServer() -> LocalOpenAIServer {
        LocalOpenAIServer(modelID: "resident-id") { _, emit in
            try await emit(.textDelta("hello from backend"))
            try await emit(.usage(.init(promptTokens: 7, completionTokens: 3)))
            try await emit(.completed(.stop))
        }
    }
}

private actor ControlledBackend {
    var started = 0
    var finished = 0
    var released = false
    func release() { released = true }
    func generate(_ request: MlxGenerationRequest, emit: GenerationSink) async throws {
        started += 1
        defer { finished += 1 }
        try await emit(.textDelta("first-delta"))
        while !released { try await Task.sleep(nanoseconds: 5_000_000) }
        try await emit(.textDelta("second-delta"))
        try await emit(.usage(.init(promptTokens: 7, completionTokens: 2)))
        try await emit(.completed(.stop))
    }
}

private actor SaturatingBackend {
    var sent = 0
    var finished = false
    func generate(_ request: MlxGenerationRequest, emit: GenerationSink) async throws {
        defer { finished = true }
        for _ in 0..<10_000 {
            try await emit(.textDelta(String(repeating: "x", count: 32 * 1024)))
            sent += 1
        }
        try await emit(.completed(.stop))
    }
}

private final class RawSocket {
    private var fd: Int32
    init(port: UInt16, receiveBuffer: Int32? = nil) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        if var receiveBuffer { setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard status == 0 else { close(); throw POSIXError(.ECONNREFUSED) }
    }
    func post(stream: Bool = false) throws { try post(body: "{\"stream\":\(stream),\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}") }
    func post(body: String, path: String = "/v1/chat/completions") throws {
        try write("POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: application/json\r\n\r\n\(body)")
    }
    func write(_ string: String) throws { try write(Data(string.utf8)) }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var count = 0
            while count < raw.count {
                let written = Darwin.send(fd, raw.baseAddress!.advanced(by: count), raw.count - count, 0)
                guard written > 0 else { throw POSIXError(.EIO) }; count += written
            }
        }
    }
    func read(until marker: String? = nil) throws -> String {
        var result = Data(); var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: bytes.prefix(count))
            if let marker, String(decoding: result, as: UTF8.self).contains(marker) { break }
        }
        return String(decoding: result, as: UTF8.self)
    }
    func readToEnd() throws -> String { try read() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    deinit { close() }
}

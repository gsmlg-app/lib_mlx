import XCTest
@testable import MlxCore

final class MlxCoreTests: XCTestCase {
    private let config = MlxModelConfig(modelPath: "/missing")

    func testConfigurationRejectsArchitecturalOverflowAndUnpinnedRevision() throws {
        XCTAssertThrowsError(try MlxResidentModel.validateConfiguration(.init(modelPath: "", contextLength: 131_073)))
        XCTAssertThrowsError(try MlxResidentModel.validateConfiguration(.init(modelPath: "", revision: "main")))
        XCTAssertNoThrow(try MlxResidentModel.validateConfiguration(.init(modelPath: "", contextLength: 131_072)))
    }
    func testContextAdmissionUsesTotalBudgetWithoutOverflow() throws {
        XCTAssertNoThrow(try AppleMLXBackend.admit(promptTokens: 8000, outputTokens: 192, contextLength: 8192))
        XCTAssertThrowsError(try AppleMLXBackend.admit(promptTokens: 8001, outputTokens: 192, contextLength: 8192))
        XCTAssertThrowsError(try AppleMLXBackend.admit(promptTokens: Int.max, outputTokens: Int.max, contextLength: 8192))
    }
    func testProductionLeaseIsExclusiveAndOwnerChecked() async throws {
        let lease = MLXDeviceLease()
        let owner = try await lease.acquire()
        do { _ = try await lease.acquire(); XCTFail("Second production lease must be rejected") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "model_busy") }
        await lease.release(UUID())
        do { _ = try await lease.acquire(); XCTFail("An unrelated token cannot release the model") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "model_busy") }
        await lease.release(owner)
        let next = try await lease.acquire()
        await lease.release(next)
    }
    func testProductionLoadFailsWithoutAssets() async {
        do { _ = try await MlxResidentModel.load(handle: 1, config: config); XCTFail("Missing assets must not create a model") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "invalid_model_assets") }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testTypedContentAndJSONArePreservedAndUnsupportedCapabilitiesRejected() throws {
        let backend = GateBackend()
        let model = MlxResidentModel(handle: 1, config: config, backend: backend)
        let args: SendableValue = .object(["count": .int(2), "flag": .bool(true), "nested": .array([.null, .double(1.5)])])
        let call = MlxToolCall(id: "call_1", name: "lookup", arguments: args)
        let message = MlxChatMessage(role: "assistant", content: [.text("a"), .imageURL("file:///image"), .text("b")], toolCalls: [call])
        XCTAssertEqual(message.content.count, 3)
        XCTAssertEqual(message.toolCalls.first?.arguments, args)
        XCTAssertThrowsError(try model.validate(request: .init(messages: [message])))
        XCTAssertThrowsError(try model.validate(request: .init(messages: [.init(role: "user", content: [.inputAudio(data: "x", format: "wav")])])))
        XCTAssertThrowsError(try model.validate(request: .init(prompt: "hi", tools: [["name": .string("lookup")]])))
        XCTAssertNoThrow(try model.validate(request: .init(prompt: "hi")))
        XCTAssertEqual(SendableValue(any: 1), .int(1))
        XCTAssertEqual(SendableValue(any: true), .bool(true))
    }
    func testReasoningMarkersAreSeparatedAcrossEveryChunkBoundary() {
        let text = "Hello<|channel>thought\nreasoning<channel|>answer"
        for boundary in 0...text.count {
            var splitter = ReasoningSplitter()
            let split = text.index(text.startIndex, offsetBy: boundary)
            let events = splitter.append(String(text[..<split])) + splitter.append(String(text[split...]), final: true)
            let visible = events.compactMap { if case .textDelta(let s) = $0 { return s }; return nil }.joined()
            let reasoning = events.compactMap { if case .reasoningDelta(let s) = $0 { return s }; return nil }.joined()
            XCTAssertEqual(visible, "Helloanswer", "boundary=\(boundary)")
            XCTAssertEqual(reasoning, "reasoning", "boundary=\(boundary)")
        }
    }
    func testBackpressureAndCancellationTeardown() async throws {
        let backend = GateBackend()
        let model = MlxResidentModel(handle: 1, config: config, backend: backend)
        let sink = SinkGate()
        let task = Task { try await model.generate(request: .init(prompt: "hi")) { event in try await sink.receive(event) } }
        await backend.waitStarted()
        await sink.waitEntered()
        let emitted = await backend.emitted
        XCTAssertEqual(emitted, 1, "Producer must wait for the sink before emitting another event")
        task.cancel()
        await sink.release()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let ended = await backend.ended
        XCTAssertTrue(ended)
        let snapshot = await model.snapshot()
        XCTAssertFalse(snapshot.activeGeneration)
    }
    func testPressureBlocksAdmissionAndShutdownIsIrreversible() async throws {
        let backend = GateBackend()
        let model = MlxResidentModel(handle: 1, config: config, backend: backend)
        let pressure = Task { await model.handleMemoryPressure(suspend: true) }
        await backend.waitClearing()
        do { try await model.generate(request: .init(prompt: "hi")) { _ in }; XCTFail("Must reject while draining") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "model_unavailable") }
        let shutdown = Task { await model.shutdown() }
        await backend.releaseClear()
        await pressure.value
        await shutdown.value
        await model.resume()
        await model.handleMemoryPressure()
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.status, "unloaded")
        let shutdownCount = await backend.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        do { try await model.generate(request: .init(prompt: "hi")) { _ in }; XCTFail("Cannot resume unloaded model") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "model_unavailable") }
    }
}

private actor GateBackend: MlxBackend {
    var emitted = 0
    var ended = false
    var shutdownCount = 0
    private var started = false
    private var clearing = false
    private var clearContinuation: CheckedContinuation<Void, Never>?
    func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws {
        started = true
        defer { ended = true }
        for _ in 0..<100 {
            try Task.checkCancellation()
            emitted += 1
            try await emit(.textDelta("x"))
        }
    }
    func waitStarted() async { while !started { await Task.yield() } }
    func clearCache() async { clearing = true; await withCheckedContinuation { clearContinuation = $0 } }
    func waitClearing() async { while !clearing { await Task.yield() } }
    func releaseClear() { clearContinuation?.resume(); clearContinuation = nil }
    func shutdown() { shutdownCount += 1 }
}
private actor SinkGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func receive(_ event: MlxGenerationEvent) async throws {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
    }
    func waitEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

final class MlxRealModelTests: XCTestCase {
    func testPinnedCheckpointTextGenerationAndContextRejection() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIB_MLX_TEST_MODEL_PATH"] else {
            throw XCTSkip("Set LIB_MLX_TEST_MODEL_PATH to the verified pinned model directory for the hardware integration test.")
        }
        let model = try await MlxResidentModel.load(handle: 99, config: .init(modelPath: path, contextLength: 2048, prefillStepSize: 64))
        let events = EventStore()
        try await model.generate(request: .init(prompt: "What is the capital of France? Answer in one word.", maxTokens: 32, thinkingEnabled: false)) {
            await events.append($0)
        }
        let output = await events.values
        let text = output.compactMap { if case .textDelta(let value) = $0 { return value }; return nil }.joined()
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Paris"), "Real checkpoint output: \(text)")
        let usages = output.compactMap { if case .usage(let value) = $0 { return value }; return nil }
        XCTAssertEqual(usages.count, 1)
        XCTAssertGreaterThan(usages.first?.promptTokens ?? 0, 0)
        XCTAssertGreaterThan(usages.first?.completionTokens ?? 0, 0)
        XCTAssertLessThanOrEqual(usages.first?.completionTokens ?? Int.max, 32)
        XCTAssertEqual(output.last, .completed(.stop))
        print("REAL_MLX text=\(text) usage=\(String(describing: usages.first))")
        let thoughts = EventStore()
        try await model.generate(request: .init(prompt: "What is 17 + 26? Think briefly, then give the sum.", maxTokens: 256, thinkingEnabled: true)) {
            await thoughts.append($0)
        }
        let thinkingOutput = await thoughts.values
        let reasoning = thinkingOutput.compactMap { if case .reasoningDelta(let value) = $0 { return value }; return nil }.joined()
        let answer = thinkingOutput.compactMap { if case .textDelta(let value) = $0 { return value }; return nil }.joined()
        XCTAssertFalse(reasoning.isEmpty, "Thinking mode must produce a separate reasoning channel")
        XCTAssertFalse(answer.isEmpty, "Thinking mode must also produce assistant text")
        XCTAssertFalse(answer.contains("<|channel>"))
        print("REAL_MLX reasoning_characters=\(reasoning.count) answer=\(answer)")
        let cancelled = Task {
            try await model.generate(request: .init(prompt: String(repeating: "test ", count: 1600), maxTokens: 64, thinkingEnabled: false)) { _ in }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancellationStart = Date()
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected real prefill/decode cancellation") }
        catch is CancellationError {}
        print("REAL_MLX cancellation_teardown_seconds=\(Date().timeIntervalSince(cancellationStart))")
        do {
            try await model.generate(request: .init(prompt: String(repeating: "test ", count: 2200), maxTokens: 32)) { _ in }
            XCTFail("The tokenized prompt must exceed the configured 2048-token device limit")
        } catch let error as MlxCoreError { XCTAssertEqual(error.code, "context_length_exceeded") }
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.backend, "mlx-swift-gemma4-text")
        XCTAssertGreaterThan(snapshot.memory.activeBytes, 0)
        print("REAL_MLX memory=\(snapshot.memory) cache_policy=\(snapshot.cachePolicy)")
        await model.shutdown()
        let unloaded = await model.snapshot()
        XCTAssertEqual(unloaded.status, "unloaded")
    }
}
private actor EventStore {
    var values: [MlxGenerationEvent] = []
    func append(_ value: MlxGenerationEvent) { values.append(value) }
}

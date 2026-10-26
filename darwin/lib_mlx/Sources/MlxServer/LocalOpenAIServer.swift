import Foundation
import MlxCore
import NIOCore
import NIOPosix
import NIOHTTP1

public struct MlxServerConfig: Sendable {
    public let host: String
    public let port: UInt16
    /// Optional public alias; the resident model identifier is used by default.
    public let modelId: String?
    /// Waiting requests, excluding the one active generation.
    public let queueLimit: Int
    public let maximumBodyBytes: Int
    public let maximumHeaderBytes: Int
    public let headerTimeout: TimeInterval
    public let requestTimeout: TimeInterval
    public let writeTimeout: TimeInterval
    public let maximumConnections: Int

    public init(host: String = "127.0.0.1", port: UInt16 = 0, modelId: String? = nil,
                queueLimit: Int = 1, maximumBodyBytes: Int = 64 * 1024 * 1024,
                maximumHeaderBytes: Int = 32 * 1024, headerTimeout: TimeInterval = 10,
                requestTimeout: TimeInterval = 120, writeTimeout: TimeInterval = 30,
                maximumConnections: Int = 64) {
        self.host = host; self.port = port; self.modelId = modelId; self.queueLimit = queueLimit
        self.maximumBodyBytes = maximumBodyBytes; self.maximumHeaderBytes = maximumHeaderBytes
        self.headerTimeout = headerTimeout; self.requestTimeout = requestTimeout
        self.writeTimeout = writeTimeout; self.maximumConnections = maximumConnections
    }
}

public struct MlxServerRuntimeInfo: Sendable {
    public let host: String
    public let port: UInt16
    public let modelId: String
    public var baseURL: String { "http://\(host == "::1" ? "[::1]" : host):\(port)" }
}

public enum MlxServerError: Error {
    case invalidConfiguration(String)
    case queueFull
}

typealias GenerationSink = @Sendable (MlxGenerationEvent) async throws -> Void
typealias Generate = @Sendable (MlxGenerationRequest, @escaping GenerationSink) async throws -> Void

public final class LocalOpenAIServer: @unchecked Sendable {
    private let residentModelID: String
    private let generate: Generate
    private let validate: @Sendable (MlxGenerationRequest) throws -> Void
    private let lifecycle = NSLock()
    private var running: ServerRun?

    public init(model: MlxResidentModel) {
        residentModelID = model.config.modelId
        generate = { request, emit in try await model.generate(request: request, emit: emit) }
        validate = { request in try model.validate(request: request) }
    }

    // Injection is internal and available only through @testable import; production always owns a resident model.
    init(modelID: String = "test-model", validate: @escaping @Sendable (MlxGenerationRequest) throws -> Void = { _ in },
         generate: @escaping Generate) {
        residentModelID = modelID; self.generate = generate; self.validate = validate
    }

    public var isRunning: Bool {
        lifecycle.lock(); defer { lifecycle.unlock() }
        return running != nil
    }

    public func start(config: MlxServerConfig) throws -> MlxServerRuntimeInfo {
        lifecycle.lock(); defer { lifecycle.unlock() }
        if let running { return running.info }
        guard ["127.0.0.1", "::1", "localhost"].contains(config.host) else {
            throw MlxServerError.invalidConfiguration("Only a loopback bind address is permitted.")
        }
        guard config.queueLimit >= 0, config.maximumBodyBytes > 0, config.maximumHeaderBytes > 0,
              config.maximumConnections > 0, config.headerTimeout.isFinite, config.headerTimeout > 0,
              config.requestTimeout.isFinite, config.requestTimeout > 0,
              config.writeTimeout.isFinite, config.writeTimeout > 0,
              [config.headerTimeout, config.requestTimeout, config.writeTimeout].allSatisfy({ $0 <= 86_400 }),
              config.modelId?.isEmpty != true else {
            throw MlxServerError.invalidConfiguration("Server limits and timeouts must be positive; queueLimit may be zero.")
        }
        let run = ServerRun(config: config, modelID: config.modelId ?? residentModelID, residentModelID: residentModelID,
                            generate: generate, validate: validate)
        do {
            try run.bind()
            running = run
            return run.info
        } catch {
            run.stop()
            throw error
        }
    }

    /// Returns only after accepted sockets close and all generation tasks have unwound.
    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        running?.stop()
        running = nil
    }

    deinit { stop() }
}

private final class ServerRun: @unchecked Sendable {
    let config: MlxServerConfig
    let modelID: String
    let residentModelID: String
    let generate: Generate
    let validate: @Sendable (MlxGenerationRequest) throws -> Void
    let gate: GenerationGate
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private let tasksFinished = DispatchGroup()
    private var accepting = true
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var listener: Channel?
    private var stopped = false
    private(set) var info: MlxServerRuntimeInfo

    init(config: MlxServerConfig, modelID: String, residentModelID: String, generate: @escaping Generate,
         validate: @escaping @Sendable (MlxGenerationRequest) throws -> Void) {
        self.config = config; self.modelID = modelID; self.residentModelID = residentModelID; self.generate = generate; self.validate = validate
        gate = GenerationGate(limit: config.queueLimit)
        info = MlxServerRuntimeInfo(host: config.host, port: config.port, modelId: modelID)
    }

    func bind() throws {
        // Resolve localhost explicitly so the bound address cannot expand to a non-loopback interface.
        let host = config.host == "localhost" ? "127.0.0.1" : config.host
        listener = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: Int32(clamping: config.maximumConnections))
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: ChannelOptions.Types.WriteBufferWaterMark(low: 16_384, high: 65_536))
            .childChannelInitializer { [self] channel in
                // Bootstrap still has to register/activate this accepted socket after
                // initialization. Closing it here races registration (alreadyClosed).
                guard add(channel) else { return channel.pipeline.addHandler(RejectConnectionHandler()) }
                let budget = RequestBudget(config: config)
                return channel.pipeline.addHandler(HeaderLimitHandler(budget: budget)).flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: false)
                }.flatMap {
                    channel.pipeline.addHandler(RequestHandler(run: self, budget: budget))
                }
            }.bind(host: host, port: Int(config.port)).wait()
        guard let address = listener?.localAddress, let port = address.port, let ip = address.ipAddress else {
            throw MlxServerError.invalidConfiguration("The bound socket has no local address.")
        }
        info = MlxServerRuntimeInfo(host: ip, port: UInt16(port), modelId: modelID)
    }

    func add(_ channel: Channel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepting, channels.count < config.maximumConnections else { return false }
        channels[ObjectIdentifier(channel)] = channel
        return true
    }

    func remove(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        channels.removeValue(forKey: ObjectIdentifier(channel))
    }

    func work(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        lock.lock()
        tasksFinished.enter()
        let task = Task { [self] in
            await operation()
            finishWork(id)
        }
        tasks[id] = task
        if !accepting { task.cancel() }
        lock.unlock()
        return task
    }

    private func finishWork(_ id: UUID) {
        lock.lock(); tasks.removeValue(forKey: id); lock.unlock()
        tasksFinished.leave()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true; accepting = false
        let currentTasks = Array(tasks.values), currentChannels = Array(channels.values)
        lock.unlock()
        // Close the listener first, then all accepted channels, then await cancellation cleanup.
        try? listener?.close().wait()
        currentTasks.forEach { $0.cancel() }
        currentChannels.forEach { try? $0.close().wait() }
        tasksFinished.wait()
        try? group.syncShutdownGracefully()
        listener = nil
        lock.lock(); channels.removeAll(); lock.unlock()
    }
}

private final class RejectConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelActive(context: ChannelHandlerContext) { context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}

private actor GenerationGate {
    let limit: Int
    private var active = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(limit: Int) { self.limit = limit }

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if !active { active = true; return }
        guard waiting.count < limit else { throw MlxServerError.queueFull }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

    func release() {
        if waiting.isEmpty { active = false }
        else { waiting.removeFirst().1.resume() }
    }
}

private struct HeaderLimitError: Error {}

/// Accessed only on the channel event loop. The wire ceiling bounds decoder-owned partial
/// chunk metadata/trailers as well as the body retained by RequestHandler.
private final class RequestBudget {
    let headerLimit: Int
    let wireLimit: Int
    let metadataLimit: Int
    var wireBytes = 0
    var bodyBytes = 0
    var initialHeaderBytes = 0
    init(config: MlxServerConfig) {
        headerLimit = config.maximumHeaderBytes
        // Chunk extensions and framing get a separate bounded allowance, not an unbounded
        // exception to the body limit. Ordinary 64 MiB uploads with 64 KiB chunks fit easily.
        metadataLimit = Self.add(config.maximumHeaderBytes, 1024 * 1024)
        wireLimit = Self.add(config.maximumBodyBytes, metadataLimit)
    }
    static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }
    var metadataWithinLimit: Bool { wireBytes - bodyBytes <= metadataLimit }
    func receive(_ bytes: Int) -> Bool {
        guard bytes <= wireLimit - wireBytes else { return false }
        wireBytes += bytes
        return true
    }
}

/// Bound incomplete headers before the HTTP decoder retains them.
private final class HeaderLimitHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    let budget: RequestBudget
    var count = 0
    var suffix: UInt32 = 0
    var ended = false
    init(budget: RequestBudget) { self.budget = budget }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard budget.receive(unwrapInboundIn(data).readableBytes) else {
            context.fireErrorCaught(HeaderLimitError()); return
        }
        if !ended {
            for byte in unwrapInboundIn(data).readableBytesView {
                count += 1
                if count > budget.headerLimit { ended = true; context.fireErrorCaught(HeaderLimitError()); return }
                suffix = (suffix << 8) | UInt32(byte)
                if suffix == 0x0d0a0d0a { ended = true; budget.initialHeaderBytes = count; break }
            }
        }
        context.fireChannelRead(data)
        if !budget.metadataWithinLimit { context.fireErrorCaught(HeaderLimitError()) }
    }
}

private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let run: ServerRun
    let budget: RequestBudget
    var head: HTTPRequestHead?
    var body = Data()
    var complete = false
    var task: Task<Void, Never>?
    var headerTimer: Scheduled<Void>?
    var bodyTimer: Scheduled<Void>?

    init(run: ServerRun, budget: RequestBudget) { self.run = run; self.budget = budget }
    func handlerAdded(context: ChannelHandlerContext) {
        headerTimer = context.eventLoop.scheduleTask(in: .nanoseconds(Int64(run.config.headerTimeout * 1e9))) { [weak self] in
            guard self?.head == nil else { return }
            self?.fail(context, status: .requestTimeout, code: "request_timeout", message: "HTTP headers timed out.")
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !complete else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            headerTimer?.cancel()
            guard self.head == nil else { fail(context); return }
            self.head = head
            let bytes = head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 } + head.uri.utf8.count
            guard bytes <= run.config.maximumHeaderBytes else {
                fail(context, status: .requestHeaderFieldsTooLarge, code: "headers_too_large", message: "HTTP headers exceed the configured limit."); return
            }
            let lengths = head.headers["content-length"]
            if !lengths.isEmpty {
                guard lengths.count == 1, head.headers["transfer-encoding"].isEmpty,
                      !lengths[0].isEmpty, lengths[0].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                      let length = Int(lengths[0]), length <= run.config.maximumBodyBytes else {
                    fail(context, status: .badRequest, code: "invalid_content_length", message: "Invalid, conflicting, or oversized Content-Length."); return
                }
            }
            let encodings = head.headers["transfer-encoding"]
            guard encodings.isEmpty || encodings.map({ $0.lowercased() }) == ["chunked"] else { fail(context); return }
            bodyTimer = context.eventLoop.scheduleTask(in: .nanoseconds(Int64(run.config.requestTimeout * 1e9))) { [weak self] in
                self?.fail(context, status: .requestTimeout, code: "request_timeout", message: "HTTP request body timed out.")
            }
        case .body(var buffer):
            guard head != nil, buffer.readableBytes <= run.config.maximumBodyBytes - body.count else {
                fail(context, status: .payloadTooLarge, code: "body_too_large", message: "HTTP request body exceeds the configured limit."); return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes); budget.bodyBytes += bytes.count
            }
        case .end(let trailers):
            guard let head else { fail(context); return }
            let trailerBytes = trailers?.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 } ?? 0
            guard trailerBytes <= run.config.maximumHeaderBytes - budget.initialHeaderBytes,
                  budget.metadataWithinLimit else {
                fail(context, status: .requestHeaderFieldsTooLarge, code: "headers_too_large", message: "HTTP headers, trailers, or chunk framing exceed the configured limits."); return
            }
            complete = true; bodyTimer?.cancel()
            // One request per connection prevents pipelined requests from bypassing generation admission.
            let writer = SocketWriter(channel: context.channel, timeout: run.config.writeTimeout)
            let data = body
            task = run.work { [run] in await serve(head: head, data: data, run: run, writer: writer) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if error is HeaderLimitError { fail(context, status: .requestHeaderFieldsTooLarge, code: "headers_too_large", message: "HTTP headers exceed the configured limit.") }
        else { fail(context) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        headerTimer?.cancel(); bodyTimer?.cancel(); task?.cancel()
        run.remove(context.channel)
        context.fireChannelInactive()
    }
    func fail(_ context: ChannelHandlerContext, status: HTTPResponseStatus = .badRequest,
              code: String = "invalid_http", message: String = "Malformed or incomplete HTTP request.") {
        guard !complete else { context.close(promise: nil); return }
        complete = true; headerTimer?.cancel(); bodyTimer?.cancel()
        let payload = jsonData(errorObject(code, message))
        var headers = HTTPHeaders(); headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(payload.count)); headers.add(name: "connection", value: "close")
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: payload)))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}

final class SocketWriter: @unchecked Sendable {
    let channel: Channel
    let timeout: TimeInterval
    var started = false
    init(channel: Channel, timeout: TimeInterval) { self.channel = channel; self.timeout = timeout }
    func send(_ part: HTTPServerResponsePart) async throws {
        try Task.checkCancellation()
        let deadline = channel.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout * 1e9))) { [channel] in channel.close(promise: nil) }
        defer { deadline.cancel() }
        try await channel.writeAndFlush(part).get()
        try Task.checkCancellation()
    }
    func begin(stream: Bool, status: HTTPResponseStatus = .ok, length: Int? = nil) async throws {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: stream ? "text/event-stream" : "application/json")
        headers.add(name: "cache-control", value: "no-store")
        headers.add(name: "connection", value: "close")
        if let length { headers.add(name: "content-length", value: String(length)) }
        else { headers.add(name: "transfer-encoding", value: "chunked") }
        try await send(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        started = true
    }
    func bytes(_ data: Data) async throws {
        // At most one bounded body write is pending: the backend awaits this sink before producing another delta.
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            let range = offset..<min(offset + 65_536, data.count)
            try await send(.body(.byteBuffer(channel.allocator.buffer(bytes: data[range]))))
        }
    }
    func json(_ object: [String: Any], status: HTTPResponseStatus = .ok) async throws {
        let data = jsonData(object)
        try await begin(stream: false, status: status, length: data.count)
        // Non-stream output is bounded separately and may exceed one delta.
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            try await bytes(data.subdata(in: offset..<min(offset + 65_536, data.count)))
        }
        try await finish()
    }
    func finish() async throws { try await send(.end(nil)); try await channel.close().get() }
}

private func serve(head: HTTPRequestHead, data: Data, run: ServerRun, writer: SocketWriter) async {
    do {
        let path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        if head.method == .GET && path == "/v1/models" {
            try await writer.json(["object": "list", "data": [["id": run.modelID, "resident_model_id": run.residentModelID, "object": "model", "owned_by": "local"]]])
            return
        }
        guard head.method == .POST else {
            try await writer.json(errorObject("method_not_allowed", "Only GET models and POST generation requests are supported."), status: .methodNotAllowed); return
        }
        guard let endpoint = OpenAIEndpoint(rawValue: path) else {
            try await writer.json(errorObject("not_found", "Endpoint not found."), status: .notFound); return
        }
        let parsed = try OpenAIRequest.convert(data: data, endpoint: endpoint, modelID: run.modelID)
        try run.validate(parsed.request)
        let admissionID = UUID()
        try await run.gate.acquire(admissionID)
        do {
            try Task.checkCancellation()
            let output = OpenAIOutput(endpoint: endpoint, modelID: run.modelID, stream: parsed.stream, includeUsage: parsed.includeUsage, writer: writer)
            try await run.generate(parsed.request) { event in try await output.accept(event) }
            try await output.finish()
            await run.gate.release()
        } catch {
            await run.gate.release()
            throw error
        }
    } catch {
        if !writer.started && writer.channel.isActive && !Task.isCancelled {
            let coreError = error as? MlxCoreError
            var status: HTTPResponseStatus = .badRequest
            var code = coreError?.code ?? "invalid_request"
            if case MlxServerError.queueFull = error { status = .tooManyRequests; code = "queue_full" }
            else if coreError?.code == "model_busy" { status = .tooManyRequests }
            else if ["model_unavailable", "model_unloaded"].contains(code) { status = .serviceUnavailable }
            try? await writer.json(errorObject(code, coreError?.message ?? String(describing: error)), status: status)
        } else if writer.started && writer.channel.isActive && !Task.isCancelled {
            try? await writer.bytes(Data("event: error\ndata: \(jsonString(errorObject("generation_failed", String(describing: error))))\n\n".utf8))
            try? await writer.finish()
        }
        try? await writer.channel.close().get()
    }
}

func errorObject(_ code: String, _ message: String) -> [String: Any] { ["error": ["code": code, "message": message, "type": "invalid_request_error"]] }
func jsonData(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8) }
func jsonString(_ object: Any) -> String { String(decoding: jsonData(object), as: UTF8.self) }

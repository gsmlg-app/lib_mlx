import Foundation

public typealias MlxEventSink = @Sendable (MlxGenerationEvent) async throws -> Void

/// Explicit dependency injection. Production loading always constructs the MLX backend.
public struct MlxBackendCapabilities: Sendable, Equatable {
    public let supportsImages: Bool
    public let supportsAudio: Bool
    public let supportsTools: Bool
    public static let textOnly = Self()
    public init(supportsImages: Bool = false, supportsAudio: Bool = false, supportsTools: Bool = false) {
        self.supportsImages = supportsImages; self.supportsAudio = supportsAudio; self.supportsTools = supportsTools
    }
}
public protocol MlxBackend: Sendable {
    var capabilities: MlxBackendCapabilities { get }
    func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws
    func shutdown() async
    func clearCache() async
    func memory() async -> MlxMemorySnapshot
}
public extension MlxBackend {
    var capabilities: MlxBackendCapabilities { .textOnly }
    func shutdown() async {}
    func clearCache() async {}
    func memory() async -> MlxMemorySnapshot { .init(activeBytes: 0, cacheBytes: 0, peakBytes: 0) }
}
public struct MlxMemorySnapshot: Sendable, Equatable {
    public let activeBytes: Int
    public let cacheBytes: Int
    public let peakBytes: Int
    public init(activeBytes: Int, cacheBytes: Int, peakBytes: Int) {
        self.activeBytes = activeBytes; self.cacheBytes = cacheBytes; self.peakBytes = peakBytes
    }
}
public struct MlxModelSnapshot: Sendable {
    public let status: String
    public let modelID: String
    public let revision: String
    public let contextLength: Int
    public let activeGeneration: Bool
    public let memory: MlxMemorySnapshot
    public let cachePolicy = "per_request_no_reuse"
    public let backend: String
}

public actor MlxResidentModel {
    public nonisolated let handle: Int64
    public nonisolated let config: MlxModelConfig
    public nonisolated let loadedAt: Date
    public nonisolated let capabilities: MlxBackendCapabilities
    private var backend: (any MlxBackend)?
    private var active: Task<Void, Error>?
    private enum Admission { case ready, draining, suspended, unloading, unloaded }
    private var admission = Admission.ready
    private var drain: Task<Void, Never>?
    private var suspendAfterDrain = false
    private let backendName: String

    /// For tests and applications deliberately supplying their own backend; never used by load().
    public init(handle: Int64, config: MlxModelConfig, backend: any MlxBackend) {
        self.handle = handle; self.config = config; self.loadedAt = Date()
        self.backend = backend; self.backendName = "injected"; self.capabilities = backend.capabilities
    }
    private init(handle: Int64, config: MlxModelConfig, mlxBackend: any MlxBackend) {
        self.handle = handle; self.config = config; self.loadedAt = Date()
        self.backend = mlxBackend; self.backendName = "mlx-swift-gemma4-text"; self.capabilities = .textOnly
    }
    public static func load(handle: Int64, config: MlxModelConfig) async throws -> MlxResidentModel {
        try validateConfiguration(config)
        let backend = try await AppleMLXBackend.load(config: config)
        return MlxResidentModel(handle: handle, config: config, mlxBackend: backend)
    }
    public nonisolated static func validateConfiguration(_ config: MlxModelConfig) throws {
        guard config.contextLength > 0, config.contextLength <= 131_072,
              config.prefillStepSize > 0, config.prefillStepSize <= 4096,
              config.cacheLimitBytes >= 0, config.memoryLimitBytes.map({ $0 > 0 }) ?? true else {
            throw MlxCoreError("invalid_configuration", "Context must be 1...131072; prefill step must be 1...4096; memory limits must be positive.")
        }
        guard config.modelId == MlxAvailableModel.gemma4E2b.huggingFaceModelId,
              config.revision == nil || config.revision == MlxAvailableModel.pinnedRevision else {
            throw MlxCoreError("unsupported_model", "Only the pinned Gemma 4 E2B 4-bit checkpoint is supported.")
        }
    }
    public nonisolated func validate(request: MlxGenerationRequest) throws {
        guard request.maxTokens > 0, request.maxTokens <= config.contextLength,
              request.temperature.isFinite, request.temperature >= 0, request.temperature <= 2,
              request.topP.isFinite, request.topP > 0, request.topP <= 1, request.topK >= 0 else {
            throw MlxCoreError("invalid_request", "Invalid token limit or sampling parameters.")
        }
        guard request.tools.isEmpty || capabilities.supportsTools else { throw MlxCoreError("unsupported_tools", "This text backend does not execute tools.") }
        guard request.prompt != nil || !request.messages.isEmpty else {
            throw MlxCoreError("invalid_request", "At least one message or prompt is required.")
        }
        for message in request.messages {
            guard ["system", "developer", "user", "assistant", "tool"].contains(message.role) else {
                throw MlxCoreError("invalid_request", "Unknown message role: \(message.role).")
            }
            guard capabilities.supportsTools || (message.role != "tool" && message.toolCalls.isEmpty && message.toolCallID == nil) else {
                throw MlxCoreError("unsupported_tools", "Tool roles, calls, and results are unsupported by this backend.")
            }
            for part in message.content {
                switch part {
                case .text: break
                case .imageURL where capabilities.supportsImages: break
                case .inputAudio where capabilities.supportsAudio: break
                case .audioURL where capabilities.supportsAudio: break
                default:
                    throw MlxCoreError("unsupported_content", "This backend does not support the supplied content type.")
                }
            }
        }
    }
    public func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws {
        try validate(request: request)
        guard admission == .ready else { throw MlxCoreError("model_unavailable", "Model admission is suspended, draining, or unloaded.") }
        guard let backend else { throw MlxCoreError("model_unloaded", "The model has been unloaded.") }
        guard active == nil else { throw MlxCoreError("model_busy", "Another generation is still active.") }
        let task = Task { try await backend.generate(request: request, emit: emit) }
        active = task
        defer { active = nil }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    /// Cancel, await GPU teardown, drop request KV and free allocator cache while keeping weights resident.
    public func handleMemoryPressure(suspend: Bool = false) async {
        guard admission != .unloading && admission != .unloaded else { await drain?.value; return }
        suspendAfterDrain = suspendAfterDrain || suspend || admission == .suspended
        if let drain { await drain.value; return }
        admission = .draining
        let active = self.active
        let backend = self.backend
        let task = Task {
            active?.cancel()
            if let active { _ = await active.result }
            await backend?.clearCache()
        }
        drain = task
        await task.value
        if admission == .draining {
            admission = suspendAfterDrain ? .suspended : .ready
            drain = nil
        }
    }
    public func resume() {
        if admission == .suspended { suspendAfterDrain = false; admission = .ready }
    }
    public func shutdown() async {
        if admission == .unloaded { return }
        if admission == .unloading { await drain?.value; return }
        admission = .unloading
        let previousDrain = drain
        let active = self.active
        let backend = self.backend
        let task = Task {
            active?.cancel()
            if let active { _ = await active.result }
            await previousDrain?.value
            await backend?.shutdown()
        }
        drain = task
        await task.value
        self.backend = nil
        admission = .unloaded
        drain = nil
    }
    public func snapshot() async -> MlxModelSnapshot {
        let memory = await backend?.memory() ?? .init(activeBytes: 0, cacheBytes: 0, peakBytes: 0)
        return .init(status: backend == nil ? "unloaded" : (admission == .ready ? "ready" : admission == .unloading ? "unloading" : admission == .draining ? "draining" : "suspended"),
                     modelID: config.modelId, revision: config.revision ?? MlxAvailableModel.pinnedRevision,
                     contextLength: config.contextLength, activeGeneration: active != nil, memory: memory,
                     backend: backendName)
    }
}

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

actor MLXDeviceLease {
    static let shared = MLXDeviceLease()
    private var owner: UUID?
    func acquire() throws -> UUID {
        guard owner == nil else { throw MlxCoreError("model_busy", "A production MLX model is already resident in this process.") }
        let id = UUID(); owner = id; return id
    }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

actor AppleMLXBackend: MlxBackend {
    private var container: ModelContainer?
    private let config: MlxModelConfig
    private let memoryEstimate: ModelMemoryEstimate
    private let leaseID: UUID
    private let previousMemoryLimit: Int
    private let previousCacheLimit: Int
    private var didShutdown = false
    private init(container: ModelContainer, config: MlxModelConfig, estimate: ModelMemoryEstimate, leaseID: UUID, memoryLimit: Int, cacheLimit: Int) {
        self.container = container; self.config = config; self.memoryEstimate = estimate; self.leaseID = leaseID
        self.previousMemoryLimit = memoryLimit; self.previousCacheLimit = cacheLimit
    }
    deinit {
        if !didShutdown {
            Stream.gpu.synchronize()
            MLX.Memory.memoryLimit = previousMemoryLimit
            MLX.Memory.cacheLimit = previousCacheLimit
            MLX.Memory.clearCache()
            let id = leaseID
            Task { await MLXDeviceLease.shared.release(id) }
        }
    }
    static func load(config: MlxModelConfig) async throws -> AppleMLXBackend {
        // Check Metal before even querying MLX globals: MLX can trap while initializing an unavailable device.
        _ = try DeviceBudgetSnapshot.current()
        let directory = try ModelAssets.validate(config: config)
        try Task.checkCancellation()
        let estimate = try ModelMemoryEstimate.readVerified(directory: directory)
        let leaseID = try await MLXDeviceLease.shared.acquire()
        let memoryLimit = MLX.Memory.memoryLimit
        let cacheLimit = MLX.Memory.cacheLimit
        do {
            MLX.Memory.clearCache()
            try DeviceBudget.admit(snapshot: DeviceBudgetSnapshot.current(),
                additionalBytes: estimate.loadBytes(contextLength: config.contextLength, prefillStep: config.prefillStepSize),
                mlxActiveBytes: UInt64(MLX.Memory.activeMemory), memoryCapBytes: UInt64(config.memoryLimitBytes ?? memoryLimit))
            MLX.Memory.cacheLimit = config.cacheLimitBytes
            if let limit = config.memoryLimitBytes { MLX.Memory.memoryLimit = limit }
            // This factory's Gemma4Model.sanitize drops vision/audio towers before materializing weights.
            try Task.checkCancellation()
            let container = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
            try Task.checkCancellation()
            return AppleMLXBackend(container: container, config: config, estimate: estimate, leaseID: leaseID, memoryLimit: memoryLimit, cacheLimit: cacheLimit)
        } catch {
            Stream.gpu.synchronize()
            MLX.Memory.memoryLimit = memoryLimit; MLX.Memory.cacheLimit = cacheLimit
            MLX.Memory.clearCache()
            await MLXDeviceLease.shared.release(leaseID)
            throw error
        }
    }

    func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws {
        guard let container else { throw MlxCoreError("model_unloaded", "The model has been unloaded.") }
        let config = self.config
        let estimate = self.memoryEstimate
        defer { Stream.gpu.synchronize(); MLX.Memory.clearCache() }
        try await container.perform { context in
            try Task.checkCancellation()
            var messages: [[String: any Sendable]] = []
            if let instructions = request.instructions { messages.append(["role": "system", "content": instructions]) }
            messages += request.messages.map { message in
                var value: [String: any Sendable] = ["role": message.role, "content": message.text]
                if let reasoning = message.reasoningContent { value["reasoning_content"] = reasoning }
                return value
            }
            if let prompt = request.prompt { messages.append(["role": "user", "content": prompt]) }
            let tokens = try context.tokenizer.applyChatTemplate(messages: messages, tools: nil,
                additionalContext: ["enable_thinking": request.thinkingEnabled && config.thinkingEnabled])
            try Self.admit(promptTokens: tokens.count, outputTokens: request.maxTokens, contextLength: config.contextLength)
            // Recheck current app/Metal budgets after tokenization and before any request KV allocation.
            // The process-available value excludes existing weights; never add process footprint to it.
            MLX.Memory.clearCache()
            try DeviceBudget.admit(snapshot: DeviceBudgetSnapshot.current(),
                additionalBytes: estimate.generationBytes(tokens: tokens.count + request.maxTokens, prefillStep: config.prefillStepSize),
                mlxActiveBytes: UInt64(MLX.Memory.activeMemory), memoryCapBytes: UInt64(MLX.Memory.memoryLimit))
            let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: Float(request.temperature),
                topP: Float(request.topP), topK: request.topK, prefill: .init(stepSize: config.prefillStepSize), seed: request.seed)
            let input = LMInput(text: .init(tokens: MLXArray(tokens)))
            defer { Stream.gpu.synchronize(); MLX.Memory.clearCache() }
            let started = Date()
            // A fresh iterator owns fresh KV; no conversation or client can reuse another request's state.
            var iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            Stream.gpu.synchronize()
            let promptSeconds = Date().timeIntervalSince(started)
            let generationStart = Date()
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var splitter = ReasoningSplitter()
            var generated = 0
            var reasoningTokens = 0
            let reasoningEndToken = context.tokenizer.convertTokenToId("<channel|>")
            var reason = MlxGenerationFinishReason.length
            var eos = context.configuration.eosTokenIds
            if let id = context.tokenizer.eosTokenId { eos.insert(id) }
            if let id = context.tokenizer.unknownTokenId { eos.insert(id) }
            eos.formUnion(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
            // synchronize before releasing iterator/KV even if the sink throws or cancellation interrupts prefill/decode.
            while generated < request.maxTokens {
                try Task.checkCancellation()
                guard let token = iterator.next() else { break }
                generated += 1
                if eos.contains(token) { reason = .stop; break }
                let wasReasoning = splitter.reasoning
                detokenizer.append(token: token)
                if let chunk = detokenizer.next() {
                    for event in splitter.append(chunk) { try await emit(event) }
                }
                if Self.countsAsReasoningToken(wasReasoning: wasReasoning, token: token, endToken: reasoningEndToken) { reasoningTokens += 1 }
            }
            try Task.checkCancellation()
            for event in splitter.append("", final: true) { try await emit(event) }
            try await emit(.usage(.init(promptTokens: tokens.count, completionTokens: generated, reasoningTokens: reasoningTokens,
                                       promptSeconds: promptSeconds, generationSeconds: Date().timeIntervalSince(generationStart))))
            try Task.checkCancellation()
            try await emit(.completed(reason))
        }
    }
    nonisolated static func countsAsReasoningToken(wasReasoning: Bool, token: Int, endToken: Int?) -> Bool {
        wasReasoning && token != endToken
    }
    nonisolated static func admit(promptTokens: Int, outputTokens: Int, contextLength: Int) throws {
        guard promptTokens >= 0, outputTokens > 0, outputTokens <= contextLength, promptTokens <= contextLength - outputTokens else {
            throw MlxCoreError("context_length_exceeded", "Prompt (\(promptTokens)) plus output budget (\(outputTokens)) exceeds device context limit (\(contextLength)).")
        }
    }
    func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        container = nil
        Stream.gpu.synchronize()
        MLX.Memory.memoryLimit = previousMemoryLimit
        MLX.Memory.cacheLimit = previousCacheLimit
        MLX.Memory.clearCache()
        await MLXDeviceLease.shared.release(leaseID)
    }
    func clearCache() { Stream.gpu.synchronize(); MLX.Memory.clearCache() }
    func memory() -> MlxMemorySnapshot {
        .init(activeBytes: MLX.Memory.activeMemory, cacheBytes: MLX.Memory.cacheMemory, peakBytes: MLX.Memory.peakMemory)
    }
}

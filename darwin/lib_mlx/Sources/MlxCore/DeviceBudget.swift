import Foundation
import Metal
import Darwin
#if os(iOS) || os(tvOS)
import os
#endif

/// Snapshots have different accounting domains. `processAvailableBytes` already excludes the
/// process footprint; Metal allocated bytes already include MLX. Never add those overlapping totals.
struct DeviceBudgetSnapshot: Sendable {
    let metalAvailable: Bool
    let simulator: Bool
    let recommendedWorkingSetBytes: UInt64
    let metalAllocatedBytes: UInt64
    let processAvailableBytes: UInt64
    let processFootprintBytes: UInt64

    static func current() throws -> Self {
        #if targetEnvironment(simulator)
        throw MlxCoreError("unsupported_device", "Production MLX inference requires a physical Apple GPU; simulator execution is unsupported.")
        #else
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MlxCoreError("metal_unavailable", "No Metal device is available for MLX inference.")
        }
        guard device.hasUnifiedMemory, device.supportsFamily(.apple1) else {
            throw MlxCoreError("unsupported_device", "MLX inference requires a unified-memory Apple GPU.")
        }
        let available: UInt64
        #if os(iOS) || os(tvOS)
        available = UInt64(os_proc_available_memory())
        #else
        // macOS has no per-app jetsam API. Count free/reclaimable inactive pages,
        // excluding compressed memory and swap, as a conservative current physical-memory budget.
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw MlxCoreError("memory_budget_unavailable", "Cannot query available physical memory.") }
        // vm_statistics.h specifies that speculative pages are already included in free_count.
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        available = pages * UInt64(vm_kernel_page_size)
        #endif
        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let footprintResult = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        return .init(metalAvailable: true, simulator: false,
                     recommendedWorkingSetBytes: device.recommendedMaxWorkingSetSize,
                     metalAllocatedBytes: UInt64(device.currentAllocatedSize), processAvailableBytes: available,
                     processFootprintBytes: footprintResult == KERN_SUCCESS ? info.phys_footprint : 0)
        #endif
    }
}

/// Estimates actual pinned quantized tensor bytes from the verified safetensors header. KV is
/// uncompressed BF16 K+V, conservatively counting even layers that share KV in this architecture.
struct ModelMemoryEstimate: Sendable {
    struct Layer: Sendable {
        let heads: UInt64
        let dimension: UInt64
        let window: UInt64? // Architectural sliding attention, not cache compression.
    }
    let checkpointBytes: UInt64
    let textWeightBytes: UInt64
    let layers: [Layer]
    let vocabularySize: UInt64
    let hiddenSize: UInt64

    static func readVerified(directory: URL) throws -> Self {
        let source = try FileHandle(forReadingFrom: directory.appendingPathComponent("model.safetensors"))
        defer { try? source.close() }
        guard let prefix = try source.read(upToCount: 8), prefix.count == 8 else { throw invalidHeader() }
        let headerBytes = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard headerBytes > 0, headerBytes <= 64 * 1024 * 1024,
              let header = try source.read(upToCount: Int(headerBytes)), header.count == Int(headerBytes),
              let entries = try JSONSerialization.jsonObject(with: header) as? [String: Any] else { throw invalidHeader() }
        var checkpoint: UInt64 = 0
        var text: UInt64 = 0
        for (key, value) in entries where key != "__metadata__" {
            guard let tensor = value as? [String: Any], let offsets = tensor["data_offsets"] as? [UInt64],
                  offsets.count == 2, offsets[1] >= offsets[0] else { throw invalidHeader() }
            let bytes = offsets[1] - offsets[0]
            checkpoint = try DeviceBudget.add(checkpoint, bytes)
            if key.hasPrefix("language_model.") || key.hasPrefix("model.language_model.") || key.hasPrefix("lm_head.") {
                text = try DeviceBudget.add(text, bytes)
            }
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        guard let textConfig = config?["text_config"] as? [String: Any],
              let kinds = textConfig["layer_types"] as? [String], kinds.count == 35,
              let heads = textConfig["num_key_value_heads"] as? UInt64,
              let dimension = textConfig["head_dim"] as? UInt64,
              let globalDimension = textConfig["global_head_dim"] as? UInt64,
              let window = textConfig["sliding_window"] as? UInt64,
              let vocabulary = textConfig["vocab_size"] as? UInt64,
              let hidden = textConfig["hidden_size"] as? UInt64, text > 0, checkpoint >= text else { throw invalidHeader() }
        let globalHeads = textConfig["num_global_key_value_heads"] as? UInt64 ?? heads
        let layers = kinds.map { kind in
            Layer(heads: kind == "full_attention" ? globalHeads : heads,
                  dimension: kind == "full_attention" ? globalDimension : dimension,
                  window: kind == "full_attention" ? nil : window)
        }
        return .init(checkpointBytes: checkpoint, textWeightBytes: text, layers: layers, vocabularySize: vocabulary, hiddenSize: hidden)
    }
    private static func invalidHeader() -> MlxCoreError {
        .init("invalid_model_assets", "Cannot derive the pinned model's tensor/KV memory budget from its verified assets.")
    }
    func generationBytes(tokens: Int, prefillStep: Int) throws -> UInt64 {
        guard tokens > 0, tokens <= 131_072, prefillStep > 0, prefillStep <= 4096 else {
            throw MlxCoreError("invalid_configuration", "Invalid context or prefill size for memory estimation.")
        }
        // MLX caches grow in blocks; allow one additional 256-token block per layer.
        let positions = UInt64(tokens) + 256
        var kv: UInt64 = 0
        for layer in layers {
            let retained = min(positions, layer.window.map { $0 + 256 } ?? positions)
            kv = try DeviceBudget.add(kv, DeviceBudget.multiply(retained, layer.heads, layer.dimension, 4))
        }
        // Reserve fixed runtime/tokenizer/transient space plus two float32 logits buffers and
        // several activation buffers for the configured prefill chunk. These are conservative
        // admission estimates, not a guarantee against allocator failures or future OS pressure.
        let chunk = UInt64(min(tokens, prefillStep))
        let logits = try DeviceBudget.multiply(chunk, vocabularySize, 8)
        let activations = try DeviceBudget.multiply(chunk, hiddenSize, 32)
        return try DeviceBudget.add(kv, DeviceBudget.add(256 * 1024 * 1024, DeviceBudget.add(logits, activations)))
    }
    func loadBytes(contextLength: Int, prefillStep: Int) throws -> UInt64 {
        let loading = try DeviceBudget.add(checkpointBytes, 256 * 1024 * 1024)
        let serving = try DeviceBudget.add(textWeightBytes, generationBytes(tokens: contextLength, prefillStep: prefillStep))
        return max(loading, serving)
    }
}

enum DeviceBudget {
    /// All requested values are additional allocations. Process availability is compared directly;
    /// GPU allocation and MLX active bytes are checked separately against their respective ceilings.
    static func admit(snapshot: DeviceBudgetSnapshot, additionalBytes: UInt64,
                      mlxActiveBytes: UInt64, memoryCapBytes: UInt64?) throws {
        guard !snapshot.simulator else { throw MlxCoreError("unsupported_device", "Production MLX inference is unsupported in the simulator.") }
        guard snapshot.metalAvailable else { throw MlxCoreError("metal_unavailable", "No Metal device is available for MLX inference.") }
        let gpuTotal = try add(snapshot.metalAllocatedBytes, additionalBytes)
        let mlxTotal = try add(mlxActiveBytes, additionalBytes)
        guard snapshot.recommendedWorkingSetBytes > 0,
              gpuTotal <= snapshot.recommendedWorkingSetBytes,
              additionalBytes <= snapshot.processAvailableBytes,
              memoryCapBytes.map({ mlxTotal <= $0 }) ?? true else {
            throw MlxCoreError("insufficient_memory", "MLX memory preflight rejected allocation: additional=\(additionalBytes) bytes, process_available=\(snapshot.processAvailableBytes), process_footprint=\(snapshot.processFootprintBytes), metal_allocated=\(snapshot.metalAllocatedBytes), metal_recommended=\(snapshot.recommendedWorkingSetBytes), mlx_active=\(mlxActiveBytes), mlx_cap=\(memoryCapBytes.map(String.init) ?? "default"). Reduce context/prefill size or use a device with a larger app memory budget.")
        }
    }
    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw MlxCoreError("insufficient_memory", "Memory estimate exceeds the supported addressable budget.") }
        return value
    }
    static func multiply(_ values: UInt64...) throws -> UInt64 {
        try values.reduce(1) { partial, value in
            let (result, overflow) = partial.multipliedReportingOverflow(by: value)
            guard !overflow else { throw MlxCoreError("insufficient_memory", "Memory estimate exceeds the supported addressable budget.") }
            return result
        }
    }
}

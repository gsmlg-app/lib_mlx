import XCTest
@testable import MlxCore

final class DeviceBudgetTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024
    private var pinnedEstimate: ModelMemoryEstimate {
        .init(checkpointBytes: 3_550_352_326, textWeightBytes: 2_603_981_382,
              layers: (0..<35).map { .init(heads: 1, dimension: $0 % 5 == 4 ? 512 : 256, window: $0 % 5 == 4 ? nil : 512) },
              vocabularySize: 262_144, hiddenSize: 1536)
    }
    private func snapshot(metal: Bool = true, simulator: Bool = false, recommended: UInt64,
                          allocated: UInt64 = 0, available: UInt64, footprint: UInt64 = 0) -> DeviceBudgetSnapshot {
        .init(metalAvailable: metal, simulator: simulator, recommendedWorkingSetBytes: recommended,
              metalAllocatedBytes: allocated, processAvailableBytes: available, processFootprintBytes: footprint)
    }
    private func assertCode(_ code: String, _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual(($0 as? MlxCoreError)?.code, code, file: file, line: line)
        }
    }
    func testNoMetalAndSimulatorAreRejectedBeforeAllocation() {
        assertCode("metal_unavailable") {
            try DeviceBudget.admit(snapshot: snapshot(metal: false, recommended: 8 * gib, available: 8 * gib),
                                   additionalBytes: 1, mlxActiveBytes: 0, memoryCapBytes: nil)
        }
        assertCode("unsupported_device") {
            try DeviceBudget.admit(snapshot: snapshot(simulator: true, recommended: 8 * gib, available: 8 * gib),
                                   additionalBytes: 1, mlxActiveBytes: 0, memoryCapBytes: nil)
        }
    }
    func testLowAppBudgetAndMetalBudgetRejectPinnedLoad() throws {
        let required = try pinnedEstimate.loadBytes(contextLength: 8192, prefillStep: 256)
        XCTAssertGreaterThan(required, 3 * gib)
        assertCode("insufficient_memory") {
            try DeviceBudget.admit(snapshot: snapshot(recommended: 3 * gib, available: 2 * gib),
                                   additionalBytes: required, mlxActiveBytes: 0, memoryCapBytes: nil)
        }
        assertCode("insufficient_memory") {
            try DeviceBudget.admit(snapshot: snapshot(recommended: 3 * gib, available: 6 * gib),
                                   additionalBytes: required, mlxActiveBytes: 0, memoryCapBytes: nil)
        }
    }
    func testSufficientEightGBDeviceAppBudgetAdmitsAndLongContextRejects() throws {
        let device = snapshot(recommended: 5 * gib, available: 4 * gib)
        XCTAssertNoThrow(try DeviceBudget.admit(snapshot: device,
            additionalBytes: pinnedEstimate.loadBytes(contextLength: 8192, prefillStep: 256), mlxActiveBytes: 0, memoryCapBytes: 4 * gib))
        assertCode("insufficient_memory") {
            try DeviceBudget.admit(snapshot: device,
                additionalBytes: pinnedEstimate.loadBytes(contextLength: 131_072, prefillStep: 256), mlxActiveBytes: 0, memoryCapBytes: 4 * gib)
        }
    }
    func testGenerationChecksOnlyAdditionalProcessMemoryAndSeparateMetalAndMLXCeilings() throws {
        // The large footprint already contributes to available; MLX active is already in Metal allocated.
        let device = snapshot(recommended: 6 * gib, allocated: 3 * gib, available: 2 * gib, footprint: 6 * gib)
        XCTAssertNoThrow(try DeviceBudget.admit(snapshot: device, additionalBytes: gib, mlxActiveBytes: 3 * gib, memoryCapBytes: 5 * gib))
        assertCode("insufficient_memory") {
            try DeviceBudget.admit(snapshot: device, additionalBytes: gib, mlxActiveBytes: 3 * gib, memoryCapBytes: 3 * gib)
        }
        assertCode("insufficient_memory") {
            try DeviceBudget.admit(snapshot: snapshot(recommended: 6 * gib, allocated: 3 * gib, available: gib / 2),
                                   additionalBytes: gib, mlxActiveBytes: 3 * gib, memoryCapBytes: nil)
        }
    }
    func testBiggerContextAndPrefillIncreaseAdmissionBudgetAndOverflowFailsSafely() throws {
        XCTAssertGreaterThan(try pinnedEstimate.generationBytes(tokens: 8192, prefillStep: 256), try pinnedEstimate.generationBytes(tokens: 2048, prefillStep: 64))
        assertCode("insufficient_memory") { _ = try DeviceBudget.add(UInt64.max, 1) }
        assertCode("insufficient_memory") { _ = try DeviceBudget.multiply(UInt64.max, 2) }
        assertCode("invalid_configuration") { _ = try pinnedEstimate.generationBytes(tokens: 131_073, prefillStep: 256) }
    }
    func testHeaderDerivesTextWeightsSeparatelyFromCheckpointAndReadsKVConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tensors: [String: Any] = ["language_model.model.weight": ["data_offsets": [0, 128]], "audio_tower.weight": ["data_offsets": [128, 256]]]
        let header = try JSONSerialization.data(withJSONObject: tensors)
        var size = UInt64(header.count).littleEndian
        var bytes = withUnsafeBytes(of: &size) { Data($0) }
        bytes.append(header)
        try bytes.write(to: directory.appendingPathComponent("model.safetensors"))
        let config: [String: Any] = ["text_config": ["layer_types": Array(repeating: "sliding_attention", count: 35),
            "num_key_value_heads": 1, "head_dim": 256, "global_head_dim": 512,
            "sliding_window": 512, "vocab_size": 262144, "hidden_size": 1536]]
        try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
        let estimate = try ModelMemoryEstimate.readVerified(directory: directory)
        XCTAssertEqual(estimate.checkpointBytes, 256)
        XCTAssertEqual(estimate.textWeightBytes, 128)
        XCTAssertEqual(estimate.layers.count, 35)
        XCTAssertEqual(estimate.layers.first?.window, 512)
    }
    func testReasoningContentCountExcludesBothChannelTransitionTokens() {
        XCTAssertFalse(AppleMLXBackend.countsAsReasoningToken(wasReasoning: false, token: 10, endToken: 20))
        XCTAssertTrue(AppleMLXBackend.countsAsReasoningToken(wasReasoning: true, token: 11, endToken: 20))
        XCTAssertFalse(AppleMLXBackend.countsAsReasoningToken(wasReasoning: true, token: 20, endToken: 20))
    }
}

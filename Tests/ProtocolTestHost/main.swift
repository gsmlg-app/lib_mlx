import Foundation
import MlxCore
import MlxServer

/// Deliberately injected by this test executable; never reachable from FFI load.
private struct ContractBackend: MlxBackend {
    var capabilities: MlxBackendCapabilities { .init(supportsTools: true) }
    func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws {
        let parts = request.messages.flatMap(\.content).map { part in
            if case .text(let text) = part { return text }
            return "unsupported"
        }
        let description: [String: Any] = [
            "messages": request.messages.map { ["role": $0.role, "text": $0.text] },
            "text": parts.joined(), "instructions": request.instructions ?? "",
            "tools": request.tools.map { $0.mapValues(\.anyValue) },
            "max_tokens": request.maxTokens, "thinking": request.thinkingEnabled
        ]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: description, options: [.sortedKeys]), as: UTF8.self)
        // Two deltas with a production interval make premature buffering visible
        // to the real Dart HTTP client in CI.
        try await emit(.textDelta(text))
        try await Task.sleep(for: .milliseconds(300))
        try await emit(.textDelta("\nfinished"))
        try await emit(.usage(.init(promptTokens: 11, completionTokens: 7)))
        try await emit(.completed(.stop))
    }
}

@main
struct ProtocolTestHost {
    static func main() async throws {
        let path = CommandLine.arguments.dropFirst().first
        let model: MlxResidentModel
        if let path {
            model = try await .load(handle: 1, config: .init(modelPath: path))
        } else {
            model = .init(handle: 1, config: .init(modelPath: "explicit-protocol-test-backend"), backend: ContractBackend())
        }
        let server = LocalOpenAIServer(model: model)
        let info = try server.start(config: MlxServerConfig())
        print(info.baseURL)
        fflush(stdout)
        _ = readLine()
        server.stop()
        await model.shutdown()
    }
}

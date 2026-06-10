import Foundation
import MlxCore
import MlxServer
import XCTest

final class LocalOpenAIServerTests: XCTestCase {
    func testAvailableModelsExposeHuggingFacePages() throws {
        XCTAssertEqual(MlxAvailableModel.all.map(\.id), ["gemma-4-e4b", "gemma-4-e2b"])
        XCTAssertEqual(
            MlxAvailableModel.named("gemma-4-e4b")?.huggingFaceModelId,
            "mlx-community/gemma-4-e4b-it-4bit"
        )
        XCTAssertEqual(
            MlxAvailableModel.gemma4E4b.huggingFaceModelPageURL.absoluteString,
            "https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit"
        )
        XCTAssertEqual(
            MlxAvailableModel.named("gemma-4-e2b")?.huggingFaceModelId,
            "mlx-community/gemma-4-e2b-it-4bit"
        )
        XCTAssertEqual(
            MlxAvailableModel.gemma4E2b.huggingFaceModelPageURL.absoluteString,
            "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit"
        )
        XCTAssertNil(MlxAvailableModel.named("gemma-4-e9b"))
    }

    func testModelConfigCanUseAvailableModelAlias() throws {
        let config = MlxModelConfig(modelPath: "/tmp/gemma-4-e4b", model: .gemma4E4b)

        XCTAssertEqual(config.modelPath, "/tmp/gemma-4-e4b")
        XCTAssertEqual(config.modelId, "mlx-community/gemma-4-e4b-it-4bit")
    }

    func testChatCompletionKeepsReasoningSeparateFromContent() throws {
        let server = try makeStartedServer()
        defer { server.instance.stop() }

        let response = try postJSON(
            baseURL: server.info.baseURL,
            path: "/v1/chat/completions",
            body: [
                "model": server.info.modelId,
                "thinking": true,
                "messages": [[
                    "role": "user",
                    "content": "Capital of France? One word."
                ]]
            ]
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try decodeJSONObject(response.body)
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])

        XCTAssertEqual(message["content"] as? String, "Paris")
        XCTAssertNotNil(message["reasoning_content"])
        XCTAssertFalse((message["content"] as? String ?? "").contains("Stub reasoning"))
    }

    func testResponsesStreamIncludesTypedLifecycleEvents() throws {
        let server = try makeStartedServer()
        defer { server.instance.stop() }

        let response = try postJSON(
            baseURL: server.info.baseURL,
            path: "/v1/responses",
            body: [
                "model": server.info.modelId,
                "stream": true,
                "reasoning": [
                    "summary": "auto"
                ],
                "input": "Capital of France? One word."
            ]
        )

        XCTAssertEqual(response.statusCode, 200)
        let events = try decodeSSEEvents(response.body)
        let types = events.compactMap { $0["type"] as? String }

        XCTAssertEqual(types.first, "response.created")
        XCTAssertTrue(types.contains("response.output_item.added"))
        XCTAssertTrue(types.contains("response.reasoning_text.delta"))
        XCTAssertTrue(types.contains("response.reasoning_text.done"))
        XCTAssertTrue(types.contains("response.content_part.added"))
        XCTAssertTrue(types.contains("response.output_text.delta"))
        XCTAssertTrue(types.contains("response.output_text.done"))
        XCTAssertTrue(types.contains("response.content_part.done"))
        XCTAssertTrue(types.contains("response.output_item.done"))
        XCTAssertEqual(types.last, "response.completed")

        let sequenceNumbers = events.compactMap { $0["sequence_number"] as? Int }
        XCTAssertEqual(sequenceNumbers, Array(1...events.count))

        let completed = try XCTUnwrap(events.last)
        let completedResponse = try XCTUnwrap(completed["response"] as? [String: Any])
        XCTAssertEqual(completedResponse["output_text"] as? String, "Paris")
    }

    func testResponsesToolCallStreamEmitsArgumentDeltaAndDone() throws {
        let server = try makeStartedServer()
        defer { server.instance.stop() }

        let response = try postJSON(
            baseURL: server.info.baseURL,
            path: "/v1/responses",
            body: [
                "model": server.info.modelId,
                "stream": true,
                "input": "Weather in Paris?",
                "tools": [[
                    "type": "function",
                    "function": [
                        "name": "get_weather",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "location": [
                                    "type": "string"
                                ]
                            ],
                            "required": ["location"]
                        ]
                    ]
                ]]
            ]
        )

        XCTAssertEqual(response.statusCode, 200)
        let events = try decodeSSEEvents(response.body)
        let types = events.compactMap { $0["type"] as? String }

        XCTAssertTrue(types.contains("response.function_call_arguments.delta"))
        XCTAssertTrue(types.contains("response.function_call_arguments.done"))

        let completed = try XCTUnwrap(events.last)
        let completedResponse = try XCTUnwrap(completed["response"] as? [String: Any])
        let output = try XCTUnwrap(completedResponse["output"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(output.first { $0["type"] as? String == "function_call" })

        XCTAssertEqual(functionCall["name"] as? String, "get_weather")
        XCTAssertEqual(functionCall["status"] as? String, "completed")
        XCTAssertTrue((functionCall["arguments"] as? String ?? "").contains("Paris"))
    }

    private func makeStartedServer() throws -> (instance: LocalOpenAIServer, info: MlxServerRuntimeInfo) {
        let model = MlxResidentModel(
            handle: 1,
            config: MlxModelConfig(modelPath: "/tmp/gemma-4-e2b-it-4bit")
        )
        let server = LocalOpenAIServer(model: model)
        let info = try server.start(config: MlxServerConfig(modelId: model.config.modelId))
        return (server, info)
    }

    private func postJSON(
        baseURL: String,
        path: String,
        body: [String: Any]
    ) throws -> (statusCode: Int, body: String) {
        let url = try XCTUnwrap(URL(string: "\(baseURL)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let expectation = expectation(description: "HTTP \(path)")
        var result: Result<(Int, String), Error>?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { expectation.fulfill() }
            if let error {
                result = .failure(error)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
            result = .success((statusCode, text))
        }.resume()

        wait(for: [expectation], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func decodeJSONObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decodeSSEEvents(_ text: String) throws -> [[String: Any]] {
        var events: [[String: Any]] = []

        for rawEvent in text.components(separatedBy: "\n\n") {
            let dataLines = rawEvent
                .components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { line in
                    String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                }

            guard !dataLines.isEmpty else {
                continue
            }

            let rawData = dataLines.joined(separator: "\n")
            guard rawData != "[DONE]" else {
                continue
            }

            let data = Data(rawData.utf8)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            events.append(object)
        }

        return events
    }
}

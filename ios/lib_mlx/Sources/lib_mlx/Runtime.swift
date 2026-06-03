import Foundation
import MlxCore
import MlxServer

private final class RuntimeEntry {
    let model: MlxResidentModel
    let server: LocalOpenAIServer

    init(model: MlxResidentModel) {
        self.model = model
        self.server = LocalOpenAIServer(model: model)
    }
}

private final class RuntimeRegistry: @unchecked Sendable {
    static let shared = RuntimeRegistry()

    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var entries: [Int64: RuntimeEntry] = [:]

    func load(config: MlxModelConfig) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let handle = nextHandle
        nextHandle += 1
        entries[handle] = RuntimeEntry(model: MlxResidentModel(handle: handle, config: config))
        return [
            "ok": true,
            "handle": handle,
            "status": "ready",
            "model_id": config.modelId
        ]
    }

    func startServer(handle: Int64, config: MlxServerConfig) -> [String: Any] {
        lock.lock()
        let entry = entries[handle]
        lock.unlock()

        guard let entry else {
            return error("invalid_handle", "No model is loaded for handle \(handle).")
        }

        do {
            let info = try entry.server.start(config: config)
            return [
                "ok": true,
                "handle": handle,
                "server": [
                    "host": info.host,
                    "port": Int(info.port),
                    "base_url": info.baseURL,
                    "model_id": info.modelId,
                    "status": "running"
                ]
            ]
        } catch {
            return self.error("server_start_failed", String(describing: error))
        }
    }

    func stopServer(handle: Int64) -> [String: Any] {
        lock.lock()
        let entry = entries[handle]
        lock.unlock()

        guard let entry else {
            return error("invalid_handle", "No model is loaded for handle \(handle).")
        }

        entry.server.stop()
        return ["ok": true, "handle": handle, "status": "stopped"]
    }

    func status(handle: Int64) -> [String: Any] {
        lock.lock()
        let entry = entries[handle]
        lock.unlock()

        guard let entry else {
            return error("invalid_handle", "No model is loaded for handle \(handle).")
        }

        return [
            "ok": true,
            "handle": handle,
            "model": [
                "status": "ready",
                "model_id": entry.model.config.modelId,
                "model_path": entry.model.config.modelPath
            ],
            "server": [
                "status": entry.server.isRunning ? "running" : "stopped"
            ]
        ]
    }

    func unload(handle: Int64) -> [String: Any] {
        lock.lock()
        let entry = entries.removeValue(forKey: handle)
        lock.unlock()

        guard let entry else {
            return error("invalid_handle", "No model is loaded for handle \(handle).")
        }

        entry.server.stop()
        return ["ok": true, "handle": handle, "status": "unloaded"]
    }

    private func error(_ code: String, _ message: String) -> [String: Any] {
        [
            "ok": false,
            "error": [
                "code": code,
                "message": message
            ]
        ]
    }
}

@_cdecl("lib_mlx_load_model")
public func lib_mlx_load_model(_ configJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let object = parseObject(configJson)
    let config = MlxModelConfig(
        modelPath: object["model_path"] as? String ?? object["modelPath"] as? String ?? "",
        modelId: object["model_id"] as? String ?? object["modelId"] as? String ?? "mlx-community/gemma-4-e2b-it-4bit",
        revision: object["revision"] as? String,
        thinkingEnabled: object["thinking_enabled"] as? Bool ?? object["thinkingEnabled"] as? Bool ?? true,
        lazyEncoders: object["lazy_encoders"] as? Bool ?? object["lazyEncoders"] as? Bool ?? true
    )
    return retainedJSONString(RuntimeRegistry.shared.load(config: config))
}

@_cdecl("lib_mlx_start_server")
public func lib_mlx_start_server(_ handle: Int64, _ configJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let object = parseObject(configJson)
    let port = UInt16(clamping: object["port"] as? Int ?? 0)
    let config = MlxServerConfig(
        host: object["host"] as? String ?? "127.0.0.1",
        port: port,
        modelId: object["model_id"] as? String ?? object["modelId"] as? String ?? "mlx-community/gemma-4-e2b-it-4bit",
        queueLimit: object["queue_limit"] as? Int ?? object["queueLimit"] as? Int ?? 1
    )
    return retainedJSONString(RuntimeRegistry.shared.startServer(handle: handle, config: config))
}

@_cdecl("lib_mlx_stop_server")
public func lib_mlx_stop_server(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    retainedJSONString(RuntimeRegistry.shared.stopServer(handle: handle))
}

@_cdecl("lib_mlx_server_status")
public func lib_mlx_server_status(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    retainedJSONString(RuntimeRegistry.shared.status(handle: handle))
}

@_cdecl("lib_mlx_unload_model")
public func lib_mlx_unload_model(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    retainedJSONString(RuntimeRegistry.shared.unload(handle: handle))
}

@_cdecl("lib_mlx_free")
public func lib_mlx_free(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    free(pointer)
}

private func parseObject(_ pointer: UnsafePointer<CChar>?) -> [String: Any] {
    guard let pointer else {
        return [:]
    }
    let string = String(cString: pointer)
    guard let data = string.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return object
}

private func retainedJSONString(_ object: [String: Any]) -> UnsafeMutablePointer<CChar>? {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    let string = String(data: data, encoding: .utf8) ?? "{}"
    return strdup(string)
}

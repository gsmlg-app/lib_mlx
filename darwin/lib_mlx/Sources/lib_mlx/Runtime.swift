import Foundation
import CoreFoundation
import Darwin
import MlxCore
import MlxServer
#if canImport(UIKit)
import UIKit
#endif

private final class RuntimeEntry {
    let model: MlxResidentModel
    let server: LocalOpenAIServer
    init(model: MlxResidentModel) { self.model = model; self.server = LocalOpenAIServer(model: model) }
}

/// One owner serializes complete lifecycle operations, including their async
/// teardown. A handle is removed before draining; no old start can republish it.
/// Model execution and accepted connections have their own asynchronous owners.
private final class RuntimeRegistry: @unchecked Sendable {
    static let shared = RuntimeRegistry()
    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var entries: [Int64: RuntimeEntry] = [:]
    private var suspended = false
    #if canImport(UIKit)
    private let admission = RuntimeLifecycle(initiallyForeground: nil)
    #else
    private let admission = RuntimeLifecycle(initiallyForeground: true)
    #endif
    private let lifecycleEvents = DispatchQueue(label: "app.gsmlg.lib_mlx.app-lifecycle")
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var memoryPressure: DispatchSourceMemoryPressure?
    #endif

    private init() {
        #if os(macOS)
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: lifecycleEvents)
        pressure.setEventHandler { [weak self] in
            self?.admission.cancelLoading()
            self?.handlePressure(suspend: false)
        }
        pressure.resume()
        memoryPressure = pressure
        #endif
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.admission.cancelLoading()
            self?.lifecycleEvents.async { [weak self] in self?.handlePressure(suspend: false) }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.admission.setForeground(false)
            self?.lifecycleEvents.async { [weak self] in self?.handlePressure(suspend: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.admission.setForeground(true)
            self?.lifecycleEvents.async { [weak self] in self?.resume() }
        })
        #endif
    }

    func load(config: MlxModelConfig) throws -> [String: Any] {
        initializeApplicationStateIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard !suspended && admission.isForeground else { throw MlxCoreError("app_suspended", "Load requires a foreground application.") }
        guard nextHandle < Int64.max else { throw MlxCoreError("handle_limit", "Handle space exhausted.") }
        // MLX allocator limits and RNG are process-wide. Keep a single resident
        // production model until independent global-budget ownership is supported.
        guard entries.isEmpty else { throw MlxCoreError("model_already_loaded", "Unload the resident model before loading another.") }
        let handle = nextHandle
        nextHandle += 1
        _ = try blocking { [self] in
            try await admission.load(using: {
                try await MlxResidentModel.load(handle: handle, config: config)
            }, publish: { [self] model in
                // The complete registry operation still owns lock. Publication is also
                // atomic with the lifecycle epoch check inside admission's short lock.
                entries[handle] = RuntimeEntry(model: model)
            })
        }
        return ["ok": true, "handle": handle, "status": "ready", "model_id": config.modelId]
    }

    func startServer(handle: Int64, config: MlxServerConfig) throws -> [String: Any] {
        initializeApplicationStateIfNeeded()
        lock.lock(); defer { lock.unlock() }
        guard !suspended && admission.isForeground else { throw MlxCoreError("app_suspended", "Start requires a foreground application.") }
        let entry = try entry(handle)
        let info = try entry.server.start(config: config)
        return ["ok": true, "handle": handle, "server": [
            "host": info.host, "port": Int(info.port), "base_url": info.baseURL,
            "model_id": info.modelId, "resident_model_id": entry.model.config.modelId, "status": "running"]]
    }

    func stopServer(handle: Int64) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        try entry(handle).server.stop()
        return ["ok": true, "handle": handle, "status": "stopped"]
    }

    func status(handle: Int64) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let entry = try entry(handle)
        let snapshot = try blocking { await entry.model.snapshot() }
        return ["ok": true, "handle": handle, "model": [
            "status": snapshot.status, "model_id": snapshot.modelID, "model_path": entry.model.config.modelPath,
            "revision": snapshot.revision, "context_length": snapshot.contextLength,
            "active_generation": snapshot.activeGeneration, "cache_policy": snapshot.cachePolicy,
            "backend": snapshot.backend,
            "capabilities": ["text": true, "reasoning": true, "tools": false, "images": false, "audio": false],
            "metrics": ["process_physical_footprint_bytes": physicalFootprint(),
                        "mlx_active_bytes": snapshot.memory.activeBytes,
                        "mlx_cache_bytes": snapshot.memory.cacheBytes,
                        "mlx_peak_bytes": snapshot.memory.peakBytes]
        ], "server": ["status": entry.server.isRunning ? "running" : "stopped"]]
    }

    func unload(handle: Int64) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let entry = try entry(handle)
        entries.removeValue(forKey: handle)
        // Stop admission, cancel/drain work, close accepted sockets, then release
        // request KV and finally the resident weights.
        entry.server.stop()
        try blocking { await entry.model.shutdown() }
        return ["ok": true, "handle": handle, "status": "unloaded"]
    }

    private func entry(_ handle: Int64) throws -> RuntimeEntry {
        guard let entry = entries[handle] else {
            throw MlxCoreError("invalid_handle", "No resident model for handle \(handle).")
        }
        return entry
    }

    private func initializeApplicationStateIfNeeded() {
        #if canImport(UIKit)
        guard admission.requiresInitialState else { return }
        // Never query main while holding the registry or admission locks. Initialization
        // of the singleton has completed, so main cannot be waiting on its once token.
        let active: Bool
        if Thread.isMainThread {
            active = MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
        } else {
            active = DispatchQueue.main.sync {
                MainActor.assumeIsolated { UIApplication.shared.applicationState == .active }
            }
        }
        admission.initializeForegroundIfNeeded(active)
        #endif
    }

    private func handlePressure(suspend: Bool) {
        lock.lock(); defer { lock.unlock() }
        suspended = suspended || suspend
        for entry in entries.values {
            entry.server.stop()
            try? blocking { await entry.model.handleMemoryPressure(suspend: self.suspended) }
        }
    }
    private func resume() {
        lock.lock(); defer { lock.unlock() }
        suspended = false
        for entry in entries.values { try? blocking { await entry.model.resume() } }
        // The host deliberately restarts its server after returning to foreground.
    }
}

private final class BlockingResult<T>: @unchecked Sendable { var value: Result<T, Error>? }
private func blocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let result = BlockingResult<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { result.value = .success(try await operation()) }
        catch { result.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result.value!.get()
}

@_cdecl("lib_mlx_load_model")
public func lib_mlx_load_model(_ configJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    lifecycleJSON {
        let object = try parseObject(configJson)
        let config = MlxModelConfig(
            modelPath: try string(object, "model_path", alias: "modelPath"),
            modelId: try string(object, "model_id", alias: "modelId", default: MlxAvailableModel.defaultModel.huggingFaceModelId),
            revision: try optionalString(object, "revision"),
            thinkingEnabled: try boolean(object, "thinking_enabled", alias: "thinkingEnabled", default: true),
            lazyEncoders: try boolean(object, "lazy_encoders", alias: "lazyEncoders", default: true),
            contextLength: try integer(object, "context_length", default: 8192),
            prefillStepSize: try integer(object, "prefill_step_size", default: 256),
            memoryLimitBytes: object["memory_limit_bytes"] == nil ? nil : try integer(object, "memory_limit_bytes"),
            cacheLimitBytes: try integer(object, "cache_limit_bytes", default: 64 * 1024 * 1024))
        return try RuntimeRegistry.shared.load(config: config)
    }
}

@_cdecl("lib_mlx_start_server")
public func lib_mlx_start_server(_ handle: Int64, _ configJson: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    lifecycleJSON {
        let object = try parseObject(configJson)
        let port = try integer(object, "port", default: 0)
        guard (0...65535).contains(port) else { throw MlxCoreError("invalid_configuration", "Port must be 0...65535.") }
        let config = MlxServerConfig(
            host: try string(object, "host", default: "127.0.0.1"), port: UInt16(port),
            modelId: try optionalString(object, "model_id", alias: "modelId"),
            queueLimit: try integer(object, "queue_limit", alias: "queueLimit", default: 1),
            maximumBodyBytes: try integer(object, "max_body_bytes", default: 64 * 1024 * 1024),
            maximumHeaderBytes: try integer(object, "max_header_bytes", default: 32 * 1024),
            headerTimeout: try seconds(object, "header_timeout_seconds", default: 10),
            requestTimeout: try seconds(object, "request_timeout_seconds", default: 120),
            writeTimeout: try seconds(object, "write_timeout_seconds", default: 30),
            maximumConnections: try integer(object, "max_connections", default: 64))
        return try RuntimeRegistry.shared.startServer(handle: handle, config: config)
    }
}
@_cdecl("lib_mlx_stop_server")
public func lib_mlx_stop_server(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    lifecycleJSON { try RuntimeRegistry.shared.stopServer(handle: handle) }
}
@_cdecl("lib_mlx_server_status")
public func lib_mlx_server_status(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    lifecycleJSON { try RuntimeRegistry.shared.status(handle: handle) }
}
@_cdecl("lib_mlx_unload_model")
public func lib_mlx_unload_model(_ handle: Int64) -> UnsafeMutablePointer<CChar>? {
    lifecycleJSON { try RuntimeRegistry.shared.unload(handle: handle) }
}
@_cdecl("lib_mlx_free")
public func lib_mlx_free(_ pointer: UnsafeMutableRawPointer?) { if let pointer { free(pointer) } }

private func parseObject(_ pointer: UnsafePointer<CChar>?) throws -> [String: Any] {
    guard let pointer, let data = String(cString: pointer).data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MlxCoreError("invalid_json", "Lifecycle configuration must be a JSON object.")
    }
    return object
}
private func optionalString(_ object: [String: Any], _ key: String, alias: String? = nil) throws -> String? {
    guard let value = object[key] ?? alias.flatMap({ object[$0] }) else { return nil }
    guard let string = value as? String else { throw MlxCoreError("invalid_configuration", "\(key) must be a string.") }
    return string
}
private func string(_ object: [String: Any], _ key: String, alias: String? = nil, default fallback: String? = nil) throws -> String {
    guard let value = try optionalString(object, key, alias: alias) ?? fallback else {
        throw MlxCoreError("invalid_configuration", "\(key) is required.")
    }
    return value
}
private func integer(_ object: [String: Any], _ key: String, alias: String? = nil, default fallback: Int? = nil) throws -> Int {
    guard let value = object[key] ?? alias.flatMap({ object[$0] }) else {
        if let fallback { return fallback }
        throw MlxCoreError("invalid_configuration", "\(key) is required.")
    }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let result = Int(number.stringValue) else { throw MlxCoreError("invalid_configuration", "\(key) must be a signed integer.") }
    return result
}
private func boolean(_ object: [String: Any], _ key: String, alias: String? = nil, default fallback: Bool) throws -> Bool {
    guard let value = object[key] ?? alias.flatMap({ object[$0] }) else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw MlxCoreError("invalid_configuration", "\(key) must be a boolean.")
    }
    return number.boolValue
}
private func seconds(_ object: [String: Any], _ key: String, default fallback: Double) throws -> Double {
    guard let value = object[key] else { return fallback }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 86400 else {
        throw MlxCoreError("invalid_configuration", "\(key) must be finite and in (0, 86400].")
    }
    return number.doubleValue
}
private func lifecycleJSON(_ operation: () throws -> [String: Any]) -> UnsafeMutablePointer<CChar>? {
    let object: [String: Any]
    do { object = try operation() }
    catch {
        let core = error as? MlxCoreError
        object = ["ok": false, "error": ["code": core?.code ?? "native_error",
                                          "message": core?.message ?? error.localizedDescription]]
    }
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    return strdup(String(decoding: data, as: UTF8.self))
}
private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}

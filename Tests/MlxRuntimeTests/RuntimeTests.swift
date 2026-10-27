import Foundation
import XCTest
@testable import lib_mlx
import MlxCore

final class RuntimeTests: XCTestCase {
    private func json(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let pointer = try XCTUnwrap(pointer)
        defer { lib_mlx_free(pointer) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
    }
    func testMalformedLifecycleJSONIsRejected() throws {
        let response = try "not-json".withCString { try json(lib_mlx_load_model($0)) }
        XCTAssertEqual(response["ok"] as? Bool, false)
    }
    func testNonexistentModelIsNeverReady() throws {
        let response = try #"{"model_path":"/lib-mlx-test-missing-model"}"#.withCString { try json(lib_mlx_load_model($0)) }
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertNil(response["handle"])
    }
    func testLifecycleExportsRejectInvalidHandle() throws {
        for call in [lib_mlx_stop_server, lib_mlx_server_status, lib_mlx_unload_model] {
            let response = try json(call(-1))
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "invalid_handle")
        }
    }
    func testPortAndIntegerValidationCannotClampOrTrap() throws {
        for input in [#"{"port":-1}"#, #"{"port":65536}"#, #"{"port":true}"#,
                      #"{"port":1.5}"#, #"{"port":999999999999999999999999999}"#] {
            let response = try input.withCString { try json(lib_mlx_start_server(-1, $0)) }
            XCTAssertEqual(response["ok"] as? Bool, false)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "invalid_configuration")
        }
    }
}


final class RuntimeLifecycleTests: XCTestCase {
    func testResignGatesAndCancelsLoadBeforeQueuedRegistryDrainCanRun() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let model = makeModel(state)
        let loader = ControlledRuntimeLoader(model: model, state: state, ignoresCancellation: false)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()

        // The queue models a lifecycle drain waiting for the long registry operation.
        // The notification's short gate/cancel phase must finish while draining cannot run.
        let queue = DispatchQueue(label: "lib-mlx-test-blocked-registry")
        let release = DispatchSemaphore(value: 0)
        await withCheckedContinuation { entered in
            queue.async { entered.resume(); release.wait() }
        }
        defer { release.signal(); queue.sync {} }
        lifecycle.setForeground(false)
        queue.async { state.drained() }

        XCTAssertFalse(lifecycle.isForeground)
        XCTAssertTrue(state.wasCancelled, "Cancellation must happen before the registry drain can run")
        XCTAssertFalse(state.wasDrained)
        XCTAssertEqual(state.publishCount, 0)
        await loader.release()
        do { _ = try await task.value; XCTFail("Cancelled loading must not return ready") }
        catch let error as MlxCoreError {
            XCTAssertEqual(error.code, "load_cancelled")
            XCTAssertTrue(error.message.contains("application_inactive"), error.message)
        }
    }

    func testCancellationIgnoringLoaderCannotPublishAfterResignAndResume() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let model = makeModel(state)
        let loader = ControlledRuntimeLoader(model: model, state: state, ignoresCancellation: true)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()
        lifecycle.setForeground(false)
        lifecycle.setForeground(true)
        XCTAssertTrue(state.wasCancelled)
        await loader.release()
        do { _ = try await task.value; XCTFail("A stale load cannot become ready after resume") }
        catch let error as MlxCoreError {
            XCTAssertEqual(error.code, "app_suspended")
            XCTAssertTrue(error.message.contains("application_inactive"), error.message)
        }
        XCTAssertEqual(state.publishCount, 0)
        XCTAssertEqual(state.shutdownCount, 1, "The unpublished model must be shut down before returning")
        let snapshot = await model.snapshot()
        XCTAssertEqual(snapshot.status, "unloaded")
    }

    func testInitiallyInactiveNeverInvokesLoaderOrPublisher() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: false)
        let state = LifecycleProbe()
        do {
            _ = try await lifecycle.load(using: { state.loaded(); return self.makeModel(state) }, publish: { _ in state.published() })
            XCTFail("Loading requires a foreground application")
        } catch let error as MlxCoreError { XCTAssertEqual(error.code, "app_suspended") }
        XCTAssertEqual(state.loadCount, 0)
        XCTAssertEqual(state.publishCount, 0)
    }

    func testNotificationWinsOverStaleInitialApplicationStateSample() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: nil)
        XCTAssertTrue(lifecycle.requiresInitialState)
        lifecycle.setForeground(false)
        lifecycle.initializeForegroundIfNeeded(true)
        XCTAssertFalse(lifecycle.isForeground)
        XCTAssertFalse(lifecycle.requiresInitialState)
        let state = LifecycleProbe()
        do {
            _ = try await lifecycle.load(using: { state.loaded(); return self.makeModel(state) }, publish: { _ in state.published() })
            XCTFail("A stale foreground sample cannot reopen admission")
        } catch let error as MlxCoreError { XCTAssertEqual(error.code, "app_suspended") }
        XCTAssertEqual(state.loadCount, 0)
    }

    func testMemoryWarningCancelsLoadWithoutMarkingForegroundAppInactive() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let loader = ControlledRuntimeLoader(model: makeModel(state), state: state, ignoresCancellation: true)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()
        lifecycle.cancelLoading()
        XCTAssertTrue(lifecycle.isForeground)
        XCTAssertTrue(state.wasCancelled)
        await loader.release()
        do { _ = try await task.value; XCTFail("A pressure-cancelled load cannot publish") }
        catch let error as MlxCoreError { XCTAssertEqual(error.code, "app_suspended") }
        XCTAssertEqual(state.publishCount, 0)
        XCTAssertEqual(state.shutdownCount, 1)
    }

    func testForegroundLoadPublishesExactlyOnce() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let model = makeModel(state)
        let result = try await lifecycle.load(using: { model }, publish: { _ in state.published() })
        XCTAssertEqual(state.publishCount, 1)
        XCTAssertEqual(state.shutdownCount, 0)
        await result.shutdown()
    }

    func testCooperativeMemoryCancellationReportsPressure() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let loader = ControlledRuntimeLoader(model: makeModel(state), state: state, ignoresCancellation: false)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()
        lifecycle.cancelLoading()
        await loader.release()
        do { _ = try await task.value; XCTFail("A pressure-cancelled load cannot publish") }
        catch let error as MlxCoreError {
            XCTAssertEqual(error.code, "load_cancelled")
            XCTAssertTrue(error.message.contains("memory_pressure"), error.message)
        }
        XCTAssertEqual(state.publishCount, 0)
        XCTAssertTrue(lifecycle.isForeground)
    }

    func testFirstLoadCancellationCauseSurvivesLaterNotifications() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let loader = ControlledRuntimeLoader(model: makeModel(state), state: state, ignoresCancellation: true)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()
        lifecycle.cancelLoading()
        lifecycle.setForeground(false)
        lifecycle.setForeground(true)
        await loader.release()
        do { _ = try await task.value; XCTFail("An invalidated load cannot publish") }
        catch let error as MlxCoreError {
            XCTAssertTrue(error.message.contains("memory_pressure"), error.message)
            XCTAssertFalse(error.message.contains("application_inactive"), error.message)
        }
        XCTAssertEqual(state.publishCount, 0)
        XCTAssertEqual(state.shutdownCount, 1)
    }

    func testCallerCancellationReportsCaller() async throws {
        let lifecycle = RuntimeLifecycle(initiallyForeground: true)
        let state = LifecycleProbe()
        let loader = ControlledRuntimeLoader(model: makeModel(state), state: state, ignoresCancellation: false)
        let task = Task { try await lifecycle.load(using: { try await loader.load() }, publish: { _ in state.published() }) }
        await loader.waitStarted()
        task.cancel()
        // Loader startup can precede registration of the caller's cancellation handler.
        // Hold its result until cancellation reaches it, so this exercises its cooperative path.
        while !state.wasCancelled { await Task.yield() }
        await loader.release()
        do { _ = try await task.value; XCTFail("A caller-cancelled load cannot publish") }
        catch let error as MlxCoreError {
            XCTAssertEqual(error.code, "load_cancelled")
            XCTAssertTrue(error.message.contains("caller_cancelled"), error.message)
        }
        XCTAssertEqual(state.publishCount, 0)
        XCTAssertTrue(lifecycle.isForeground)
    }

    private func makeModel(_ state: LifecycleProbe) -> MlxResidentModel {
        MlxResidentModel(handle: 1, config: .init(modelPath: "/unused-explicit-test-backend"), backend: LifecycleBackend(state: state))
    }
}

private struct LifecycleBackend: MlxBackend {
    let state: LifecycleProbe
    func generate(request: MlxGenerationRequest, emit: @escaping MlxEventSink) async throws {}
    func shutdown() async { state.shutdown() }
}
private actor ControlledRuntimeLoader {
    let model: MlxResidentModel
    let state: LifecycleProbe
    let ignoresCancellation: Bool
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(model: MlxResidentModel, state: LifecycleProbe, ignoresCancellation: Bool) {
        self.model = model; self.state = state; self.ignoresCancellation = ignoresCancellation
    }
    func load() async throws -> MlxResidentModel {
        started = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: { [state] in state.cancelled() }
        if !ignoresCancellation { try Task.checkCancellation() }
        return model
    }
    func waitStarted() async { while !started { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class LifecycleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var loads = 0
    private var publishes = 0
    private var shutdowns = 0
    private var cancelledValue = false
    private var drainedValue = false
    var loadCount: Int { read { loads } }
    var publishCount: Int { read { publishes } }
    var shutdownCount: Int { read { shutdowns } }
    var wasCancelled: Bool { read { cancelledValue } }
    var wasDrained: Bool { read { drainedValue } }
    func loaded() { write { loads += 1 } }
    func published() { write { publishes += 1 } }
    func shutdown() { write { shutdowns += 1 } }
    func cancelled() { write { cancelledValue = true } }
    func drained() { write { drainedValue = true } }
    private func read<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func write(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; body() }
}

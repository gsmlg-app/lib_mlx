import Foundation
import MlxCore

/// The registry's operation lock may remain held during loading/draining. This independent,
/// short-lived lock lets a notification close admission and cancel loading immediately.
final class RuntimeLifecycle: @unchecked Sendable {
    private struct Loading {
        let id: UUID
        let epoch: UUID
        let task: Task<MlxResidentModel, Error>
    }
    private let lock = NSLock()
    private var initialized: Bool
    private var foreground: Bool
    private var epoch = UUID()
    private var loading: Loading?

    init(initiallyForeground: Bool?) {
        initialized = initiallyForeground != nil
        foreground = initiallyForeground ?? false
    }
    var requiresInitialState: Bool {
        lock.lock(); defer { lock.unlock() }
        return !initialized
    }
    var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return initialized && foreground
    }
    /// A notification received while the initial main-thread sample is in flight wins over it.
    func initializeForegroundIfNeeded(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !initialized else { return }
        initialized = true
        foreground = active
    }
    func setForeground(_ active: Bool) {
        lock.lock()
        initialized = true
        foreground = active
        if !active { epoch = UUID() }
        let task = !active ? loading?.task : nil
        lock.unlock()
        // Cancellation handlers may re-enter other owners; never invoke them under this lock.
        task?.cancel()
    }
    func cancelLoading() {
        lock.lock()
        epoch = UUID()
        let task = loading?.task
        lock.unlock()
        task?.cancel()
    }
    func load(using loader: @escaping @Sendable () async throws -> MlxResidentModel,
              publish: @escaping @Sendable (MlxResidentModel) -> Void) async throws -> MlxResidentModel {
        let ticket = try begin(loader: loader)
        do {
            let model = try await withTaskCancellationHandler {
                try await ticket.task.value
            } onCancel: { ticket.task.cancel() }
            do {
                // Commit and the final foreground/epoch check share the notification gate.
                // An old loader that ignores cancellation can never publish after resign/resume.
                try commit(ticket, model: model, publish: publish)
                return model
            } catch {
                await model.shutdown()
                throw error
            }
        } catch {
            finish(ticket)
            if error is CancellationError {
                throw MlxCoreError("load_cancelled", "Model loading was cancelled before a resident handle could be published.")
            }
            throw error
        }
    }
    private func begin(loader: @escaping @Sendable () async throws -> MlxResidentModel) throws -> Loading {
        lock.lock(); defer { lock.unlock() }
        guard initialized && foreground else { throw inactive() }
        guard loading == nil else { throw MlxCoreError("model_loading", "A model load is already in progress.") }
        let ticket = Loading(id: UUID(), epoch: epoch, task: Task.detached { try await loader() })
        loading = ticket
        return ticket
    }
    private func commit(_ ticket: Loading, model: MlxResidentModel,
                        publish: @Sendable (MlxResidentModel) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard initialized && foreground, epoch == ticket.epoch,
              loading?.id == ticket.id, !ticket.task.isCancelled else { throw inactive() }
        publish(model)
        loading = nil
    }
    private func finish(_ ticket: Loading) {
        lock.lock(); defer { lock.unlock() }
        if loading?.id == ticket.id { loading = nil }
    }
    private func inactive() -> MlxCoreError {
        MlxCoreError("app_suspended", "Model loading was cancelled or requires a foreground application.")
    }
}

import Foundation
import MlxCore

/// The registry's operation lock may remain held during loading/draining. This independent,
/// short-lived lock lets a notification close admission and cancel loading immediately.
final class RuntimeLifecycle: @unchecked Sendable {
    private enum CancellationCause: String {
        case inactive = "application_inactive"
        case pressure = "memory_pressure"
        case caller = "caller_cancelled"
    }
    private struct Loading {
        let id: UUID
        let epoch: UUID
        let task: Task<MlxResidentModel, Error>
        var cancellationCause: CancellationCause?
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
        if !active {
            epoch = UUID()
            if loading?.cancellationCause == nil { loading?.cancellationCause = .inactive }
        }
        let task = !active ? loading?.task : nil
        lock.unlock()
        // Cancellation handlers may re-enter other owners; never invoke them under this lock.
        task?.cancel()
    }
    func cancelLoading() {
        lock.lock()
        epoch = UUID()
        if loading?.cancellationCause == nil { loading?.cancellationCause = .pressure }
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
            } onCancel: { self.cancelFromCaller(ticket) }
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
            let cause = finish(ticket)
            if error is CancellationError {
                throw MlxCoreError("load_cancelled", "Model loading was cancelled before a resident handle could be published; source=\(cause?.rawValue ?? "backend_cancelled").")
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
              loading?.id == ticket.id, !ticket.task.isCancelled else {
            throw MlxCoreError("app_suspended", "Model loading cannot publish a resident handle; source=\(loading?.cancellationCause?.rawValue ?? "application_inactive").")
        }
        publish(model)
        loading = nil
    }
    private func cancelFromCaller(_ ticket: Loading) {
        lock.lock()
        if loading?.id == ticket.id {
            epoch = UUID()
            if loading?.cancellationCause == nil { loading?.cancellationCause = .caller }
        }
        lock.unlock()
        ticket.task.cancel()
    }
    private func finish(_ ticket: Loading) -> CancellationCause? {
        lock.lock(); defer { lock.unlock() }
        guard loading?.id == ticket.id else { return nil }
        let cause = loading?.cancellationCause
        loading = nil
        return cause
    }
    private func inactive() -> MlxCoreError {
        MlxCoreError("app_suspended", "Model loading was cancelled or requires a foreground application.")
    }
}

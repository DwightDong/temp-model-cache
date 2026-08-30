import Foundation

/// Full refreshes reacquire optional hardware/profiler metadata. Arrangement
/// refreshes reacquire only authoritative runtime topology and retain metadata
/// from the last complete committed inventory.
enum DisplayInventoryRefreshScope: Int, Equatable, Sendable {
    case arrangement
    case full

    static func merged(
        _ lhs: DisplayInventoryRefreshScope,
        _ rhs: DisplayInventoryRefreshScope
    ) -> DisplayInventoryRefreshScope {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}

/// Reasons are deliberately a fixed-size bit set. A burst can therefore merge
/// 100,000 callbacks without retaining a request object (or allocating a set)
/// for every callback.
struct DisplayInventoryRefreshReasons: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let initialization = Self(rawValue: 1 << 0)
    static let viewAppearance = Self(rawValue: 1 << 1)
    static let monitoringStartup = Self(rawValue: 1 << 2)
    static let displayAdded = Self(rawValue: 1 << 3)
    static let displayRemoved = Self(rawValue: 1 << 4)
    static let arrangementChanged = Self(rawValue: 1 << 5)
    static let mainDisplayChanged = Self(rawValue: 1 << 6)
    static let displayModeChanged = Self(rawValue: 1 << 7)
    static let explicitRefresh = Self(rawValue: 1 << 8)
}

struct DisplayInventoryRefreshRequest: Equatable, Sendable {
    let scope: DisplayInventoryRefreshScope
    let reasons: DisplayInventoryRefreshReasons
    let invalidatesInventory: Bool

    static func demand(
        reason: DisplayInventoryRefreshReasons
    ) -> DisplayInventoryRefreshRequest {
        DisplayInventoryRefreshRequest(
            scope: .full,
            reasons: reason,
            invalidatesInventory: false
        )
    }

    static func invalidation(
        scope: DisplayInventoryRefreshScope,
        reasons: DisplayInventoryRefreshReasons
    ) -> DisplayInventoryRefreshRequest {
        DisplayInventoryRefreshRequest(
            scope: scope,
            reasons: reasons,
            invalidatesInventory: true
        )
    }

    func merging(_ other: DisplayInventoryRefreshRequest) -> DisplayInventoryRefreshRequest {
        DisplayInventoryRefreshRequest(
            scope: .merged(scope, other.scope),
            reasons: reasons.union(other.reasons),
            invalidatesInventory: invalidatesInventory || other.invalidatesInventory
        )
    }
}

/// Shared by inventory and process providers. Cancellation is observable
/// without retaining the monitor or requiring a callback onto its queue.
final class DisplayInventoryCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

protocol DisplayInventoryRefreshScheduling: AnyObject {
    func scheduleOperation(_ operation: @escaping () -> Void)
    func scheduleCommit(_ operation: @escaping () -> Void)
}

/// Production operations run on one serial utility queue. The coordinator is
/// independently bounded, while serial execution is an additional guard that
/// makes it impossible for two provider calls to overlap.
final class DispatchDisplayInventoryRefreshScheduler: DisplayInventoryRefreshScheduling {
    private let operationQueue: DispatchQueue
    private let commitQueue: DispatchQueue

    init(
        operationQueue: DispatchQueue = DispatchQueue(
            label: "DockAnchor.DisplayInventory",
            qos: .utility
        ),
        commitQueue: DispatchQueue = .main
    ) {
        self.operationQueue = operationQueue
        self.commitQueue = commitQueue
    }

    func scheduleOperation(_ operation: @escaping () -> Void) {
        operationQueue.async(execute: operation)
    }

    func scheduleCommit(_ operation: @escaping () -> Void) {
        commitQueue.async(execute: operation)
    }
}

struct DisplayInventoryRefreshDiagnostics: Equatable, Sendable {
    let requestCount: UInt64
    let latestGeneration: UInt64
    let committedGeneration: UInt64?
    let providerInvocations: UInt64
    let commitCount: UInt64
    let discardedCompletions: UInt64
    let operationSchedulerRegistrations: UInt64
    let commitSchedulerRegistrations: UInt64
    let activeOperationCount: Int
    let pendingRefreshCount: Int
    let maximumActiveOperationCount: Int
    let maximumPendingRefreshCount: Int
}

/// A small generation state machine. There can be one running/awaiting-commit
/// generation and one merged trailing generation. Requests never enqueue
/// closures, which keeps submission latency and retained memory O(1).
final class DisplayInventoryRefreshCoordinator<Output>: @unchecked Sendable {
    typealias Operation = (
        DisplayInventoryRefreshScope,
        DisplayInventoryCancellationToken
    ) -> Output?
    typealias Commit = (
        Output,
        DisplayInventoryRefreshRequest,
        UInt64
    ) -> Void

    private enum ActivePhase: Equatable {
        case running
        case awaitingCommit
    }

    private struct GenerationWork {
        let generation: UInt64
        var request: DisplayInventoryRefreshRequest
        let cancellation: DisplayInventoryCancellationToken
        var phase: ActivePhase
    }

    private struct PendingWork {
        var generation: UInt64
        var request: DisplayInventoryRefreshRequest
    }

    private let lock = NSLock()
    private let scheduler: DisplayInventoryRefreshScheduling
    private let operation: Operation
    private let commit: Commit

    private var active: GenerationWork?
    private var pending: PendingWork?
    private var cancelled = false
    private var hasCommittedInventory = false

    private var requestCount: UInt64 = 0
    private var latestGeneration: UInt64 = 0
    private var committedGeneration: UInt64?
    private var providerInvocations: UInt64 = 0
    private var commitCount: UInt64 = 0
    private var discardedCompletions: UInt64 = 0
    private var operationRegistrations: UInt64 = 0
    private var commitRegistrations: UInt64 = 0
    private var activeOperationCount = 0
    private var maximumActiveOperationCount = 0
    private var maximumPendingRefreshCount = 0

    init(
        scheduler: DisplayInventoryRefreshScheduling,
        operation: @escaping Operation,
        commit: @escaping Commit
    ) {
        self.scheduler = scheduler
        self.operation = operation
        self.commit = commit
    }

    /// Demand requests (launch, views, monitoring) share a valid cached or
    /// in-flight inventory. Invalidation requests supersede the active
    /// generation and merge into exactly one trailing refresh.
    @discardableResult
    func request(_ request: DisplayInventoryRefreshRequest) -> UInt64 {
        var workToSchedule: GenerationWork?
        var returnedGeneration: UInt64 = 0

        lock.lock()
        requestCount &+= 1
        guard !cancelled else {
            returnedGeneration = latestGeneration
            lock.unlock()
            return returnedGeneration
        }

        if !request.invalidatesInventory {
            if let pending {
                returnedGeneration = pending.generation
            } else if let active {
                returnedGeneration = active.generation
            } else if hasCommittedInventory {
                returnedGeneration = committedGeneration ?? latestGeneration
            } else {
                latestGeneration &+= 1
                let work = makeGenerationWork(
                    generation: latestGeneration,
                    request: request
                )
                active = work
                workToSchedule = work
                returnedGeneration = work.generation
            }
        } else {
            latestGeneration &+= 1
            returnedGeneration = latestGeneration
            if active != nil {
                var pendingRequest = request
                // An arrangement refresh cannot retain metadata until at least
                // one complete inventory has committed. If initialization is
                // superseded, its trailing replacement remains complete.
                if !hasCommittedInventory {
                    pendingRequest = DisplayInventoryRefreshRequest(
                        scope: .full,
                        reasons: pendingRequest.reasons,
                        invalidatesInventory: true
                    )
                }
                if var existing = pending {
                    existing.generation = latestGeneration
                    existing.request = existing.request.merging(pendingRequest)
                    pending = existing
                } else {
                    pending = PendingWork(
                        generation: latestGeneration,
                        request: pendingRequest
                    )
                }
                maximumPendingRefreshCount = max(maximumPendingRefreshCount, 1)
            } else {
                let work = makeGenerationWork(
                    generation: latestGeneration,
                    request: request
                )
                active = work
                workToSchedule = work
            }
        }
        lock.unlock()

        if let workToSchedule {
            scheduleOperation(workToSchedule)
        }
        return returnedGeneration
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        active?.cancellation.cancel()
        active = nil
        pending = nil
        lock.unlock()
    }

    /// Used to invalidate delayed side effects produced by a committed
    /// topology as soon as a newer display request has been submitted.
    func isCurrentGeneration(_ generation: UInt64) -> Bool {
        lock.lock()
        let value = !cancelled &&
            latestGeneration == generation &&
            committedGeneration == generation
        lock.unlock()
        return value
    }

    var diagnostics: DisplayInventoryRefreshDiagnostics {
        lock.lock()
        let value = DisplayInventoryRefreshDiagnostics(
            requestCount: requestCount,
            latestGeneration: latestGeneration,
            committedGeneration: committedGeneration,
            providerInvocations: providerInvocations,
            commitCount: commitCount,
            discardedCompletions: discardedCompletions,
            operationSchedulerRegistrations: operationRegistrations,
            commitSchedulerRegistrations: commitRegistrations,
            activeOperationCount: activeOperationCount,
            pendingRefreshCount: pending == nil ? 0 : 1,
            maximumActiveOperationCount: maximumActiveOperationCount,
            maximumPendingRefreshCount: maximumPendingRefreshCount
        )
        lock.unlock()
        return value
    }

    private func makeGenerationWork(
        generation: UInt64,
        request: DisplayInventoryRefreshRequest
    ) -> GenerationWork {
        GenerationWork(
            generation: generation,
            request: request,
            cancellation: DisplayInventoryCancellationToken(),
            phase: .running
        )
    }

    private func scheduleOperation(_ work: GenerationWork) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        operationRegistrations &+= 1
        lock.unlock()

        scheduler.scheduleOperation { [weak self] in
            self?.runOperation(work)
        }
    }

    private func runOperation(_ work: GenerationWork) {
        lock.lock()
        guard !cancelled,
              let active,
              active.generation == work.generation,
              active.phase == .running else {
            lock.unlock()
            return
        }
        providerInvocations &+= 1
        activeOperationCount += 1
        maximumActiveOperationCount = max(
            maximumActiveOperationCount,
            activeOperationCount
        )
        lock.unlock()

        let output = operation(work.request.scope, work.cancellation)

        lock.lock()
        activeOperationCount -= 1
        let shouldHandle = !cancelled &&
            active?.generation == work.generation &&
            active?.phase == .running
        lock.unlock()
        guard shouldHandle else { return }

        finishOperation(work, output: output)
    }

    private func finishOperation(_ work: GenerationWork, output: Output?) {
        var nextWork: GenerationWork?
        var shouldScheduleCommit = false

        lock.lock()
        guard !cancelled,
              active?.generation == work.generation,
              active?.phase == .running else {
            lock.unlock()
            return
        }

        if let pending {
            discardedCompletions &+= 1
            let next = makeGenerationWork(
                generation: pending.generation,
                request: pending.request
            )
            self.pending = nil
            active = next
            nextWork = next
        } else if let output, work.generation == latestGeneration,
                  !work.cancellation.isCancelled {
            var awaiting = work
            awaiting.phase = .awaitingCommit
            active = awaiting
            shouldScheduleCommit = true
            // Keep output alive only in this single scheduled closure.
            commitRegistrations &+= 1
        } else {
            active = nil
            discardedCompletions &+= 1
        }
        lock.unlock()

        if let nextWork {
            scheduleOperation(nextWork)
        } else if shouldScheduleCommit, let output {
            scheduler.scheduleCommit { [weak self] in
                self?.commitIfCurrent(work: work, output: output)
            }
        }
    }

    private func commitIfCurrent(work: GenerationWork, output: Output) {
        var nextWork: GenerationWork?

        // The commit closure is invoked while holding the generation lock. A
        // concurrent request linearizes either before this check (and makes the
        // result stale) or after the complete commit. It can never interleave
        // halfway through publication.
        lock.lock()
        guard !cancelled,
              active?.generation == work.generation,
              active?.phase == .awaitingCommit else {
            lock.unlock()
            return
        }

        if let pending {
            discardedCompletions &+= 1
            let next = makeGenerationWork(
                generation: pending.generation,
                request: pending.request
            )
            self.pending = nil
            active = next
            nextWork = next
            lock.unlock()
            scheduleOperation(next)
            return
        }

        guard work.generation == latestGeneration,
              !work.cancellation.isCancelled else {
            active = nil
            discardedCompletions &+= 1
            lock.unlock()
            return
        }

        commit(output, work.request, work.generation)
        hasCommittedInventory = true
        committedGeneration = work.generation
        commitCount &+= 1
        active = nil
        lock.unlock()
    }

    deinit {
        cancel()
    }
}

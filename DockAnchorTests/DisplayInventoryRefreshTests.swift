import Foundation
import CoreGraphics
import Darwin
import Testing
import XCTest
@testable import DockAnchor

private final class InventoryManualScheduler: DisplayInventoryRefreshScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [() -> Void] = []
    private var commits: [() -> Void] = []
    private(set) var operationRegistrations = 0
    private(set) var commitRegistrations = 0
    private(set) var maximumQueuedOperations = 0

    func scheduleOperation(_ operation: @escaping () -> Void) {
        lock.lock()
        operationRegistrations += 1
        operations.append(operation)
        maximumQueuedOperations = max(maximumQueuedOperations, operations.count)
        lock.unlock()
    }

    func scheduleCommit(_ operation: @escaping () -> Void) {
        lock.lock()
        commitRegistrations += 1
        commits.append(operation)
        lock.unlock()
    }

    var operationCount: Int {
        lock.lock()
        let count = operations.count
        lock.unlock()
        return count
    }

    var commitCount: Int {
        lock.lock()
        let count = commits.count
        lock.unlock()
        return count
    }

    func takeOperation() -> (() -> Void)? {
        lock.lock()
        let value = operations.isEmpty ? nil : operations.removeFirst()
        lock.unlock()
        return value
    }

    func runNextOperation() {
        takeOperation()?()
    }

    func runNextCommit() {
        lock.lock()
        let value = commits.isEmpty ? nil : commits.removeFirst()
        lock.unlock()
        value?()
    }
}

private final class LockedInventoryValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

private final class BlockingInventoryOperation: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = true
    private(set) var invocations = 0
    private(set) var maximumActive = 0
    private var active = 0

    func run(
        scope: DisplayInventoryRefreshScope,
        cancellation: DisplayInventoryCancellationToken
    ) -> Int? {
        condition.lock()
        invocations += 1
        let invocation = invocations
        active += 1
        maximumActive = max(maximumActive, active)
        condition.broadcast()
        while invocation == 1 && blocked && !cancellation.isCancelled {
            condition.wait()
        }
        active -= 1
        condition.unlock()
        return cancellation.isCancelled ? nil : invocation
    }

    func waitForInvocation(_ target: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while invocations < target {
            if !condition.wait(until: deadline) {
                condition.unlock()
                return false
            }
        }
        condition.unlock()
        return true
    }

    func releaseFirst() {
        condition.lock()
        blocked = false
        condition.broadcast()
        condition.unlock()
    }
}

private final class FakeDisplayInventorySource: DisplayInventorySourceProviding, @unchecked Sendable {
    private let lock = NSLock()
    var runtimes: [RuntimeDisplayInventory?]
    var iokitResults: [[DisplayMetadataObservation]?]
    var profilerResults: [[DisplayMetadataObservation]?]
    private(set) var runtimeInvocations = 0
    private(set) var iokitInvocations = 0
    private(set) var profilerInvocations = 0

    init(
        runtimes: [RuntimeDisplayInventory?],
        iokit: [[DisplayMetadataObservation]?],
        profiler: [[DisplayMetadataObservation]?]
    ) {
        self.runtimes = runtimes
        iokitResults = iokit
        profilerResults = profiler
    }

    func acquireRuntimeInventory(
        cancellation: DisplayInventoryCancellationToken
    ) -> RuntimeDisplayInventory? {
        lock.lock()
        defer { lock.unlock() }
        runtimeInvocations += 1
        guard !runtimes.isEmpty else { return nil }
        return runtimes.removeFirst()
    }

    func acquireIOKitMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]? {
        lock.lock()
        defer { lock.unlock() }
        iokitInvocations += 1
        guard !iokitResults.isEmpty else { return nil }
        return iokitResults.removeFirst()
    }

    func acquireProfilerMetadata(
        cancellation: DisplayInventoryCancellationToken
    ) -> [DisplayMetadataObservation]? {
        lock.lock()
        defer { lock.unlock() }
        profilerInvocations += 1
        guard !profilerResults.isEmpty else { return nil }
        return profilerResults.removeFirst()
    }

    var counts: (runtime: Int, iokit: Int, profiler: Int) {
        lock.lock()
        let value = (runtimeInvocations, iokitInvocations, profilerInvocations)
        lock.unlock()
        return value
    }
}

private let inventoryUUIDA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
private let inventoryUUIDB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"

private func inventoryRuntime(
    _ observations: [DisplayRuntimeObservation],
    frames: [UInt64: CGRect]? = nil,
    main: UInt64? = nil
) -> RuntimeDisplayInventory {
    let defaultFrames = Dictionary(uniqueKeysWithValues: observations.enumerated().map {
        ($0.element.runtimeID, CGRect(x: $0.offset * 100, y: 0, width: 100, height: 100))
    })
    return RuntimeDisplayInventory(
        observations: observations,
        framesByRuntimeID: frames ?? defaultFrames,
        mainRuntimeID: main ?? observations.first?.runtimeID ?? 0
    )
}

private func inventoryObservation(
    runtimeID: UInt64,
    uuid: String,
    serial: UInt32
) -> DisplayRuntimeObservation {
    DisplayRuntimeObservation(
        runtimeID: runtimeID,
        uuidAlias: uuid,
        vendorID: 100,
        productID: 10,
        serialNumber: serial
    )
}

private func inventoryMetadata(
    source: String,
    sourceID: String,
    uuid: String?,
    serial: UInt32,
    name: String
) -> DisplayMetadataObservation {
    DisplayMetadataObservation(
        source: source,
        sourceID: sourceID,
        uuidAlias: uuid,
        vendorID: 100,
        productID: 10,
        serialNumber: serial,
        name: name,
        presentationPriority: source == "system_profiler" ? 100 : 50
    )
}

struct DisplayInventoryCoordinatorTests {
    @Test("initialization, view appearance, and monitoring startup share one inventory")
    func launchDemandsShareInventory() {
        let scheduler = InventoryManualScheduler()
        var invocations = 0
        var commits = 0
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { _, _ in
                invocations += 1
                return invocations
            },
            commit: { _, _, _ in commits += 1 }
        )

        coordinator.request(.demand(reason: .initialization))
        coordinator.request(.demand(reason: .viewAppearance))
        coordinator.request(.demand(reason: .monitoringStartup))

        #expect(scheduler.operationCount == 1)
        scheduler.runNextOperation()
        #expect(scheduler.commitCount == 1)
        scheduler.runNextCommit()

        #expect(invocations == 1)
        #expect(commits == 1)
        #expect(coordinator.diagnostics.requestCount == 3)

        // All later appearances/start requests reuse the accepted cache.
        coordinator.request(.demand(reason: .viewAppearance))
        coordinator.request(.demand(reason: .monitoringStartup))
        #expect(scheduler.operationRegistrations == 1)
        #expect(invocations == 1)
    }

    @Test("10,000 invalidations keep one active, one pending, and commit only newest")
    func tenThousandRequestsAreBounded() {
        let scheduler = InventoryManualScheduler()
        let operation = BlockingInventoryOperation()
        let commits = LockedInventoryValues<(Int, UInt64, DisplayInventoryRefreshReasons)>()
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: operation.run,
            commit: { value, request, generation in
                commits.append((value, generation, request.reasons))
            }
        )

        coordinator.request(.demand(reason: .initialization))
        let first = scheduler.takeOperation()
        #expect(first != nil)
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            first?()
            firstFinished.signal()
        }
        #expect(operation.waitForInvocation(1))

        for index in 0..<10_000 {
            let reason: DisplayInventoryRefreshReasons = index.isMultiple(of: 2)
                ? .displayAdded : .displayModeChanged
            coordinator.request(
                .invalidation(scope: .full, reasons: reason)
            )
        }

        var diagnostics = coordinator.diagnostics
        #expect(diagnostics.activeOperationCount == 1)
        #expect(diagnostics.pendingRefreshCount == 1)
        #expect(diagnostics.maximumActiveOperationCount == 1)
        #expect(diagnostics.maximumPendingRefreshCount == 1)
        #expect(scheduler.operationRegistrations == 1)
        #expect(scheduler.commitRegistrations == 0)

        operation.releaseFirst()
        #expect(firstFinished.wait(timeout: .now() + 2) == .success)
        #expect(scheduler.operationCount == 1)
        scheduler.runNextOperation()
        #expect(scheduler.commitCount == 1)
        scheduler.runNextCommit()

        diagnostics = coordinator.diagnostics
        #expect(operation.invocations == 2)
        #expect(operation.maximumActive == 1)
        #expect(diagnostics.providerInvocations == 2)
        #expect(diagnostics.commitCount == 1)
        #expect(diagnostics.discardedCompletions == 1)
        #expect(diagnostics.pendingRefreshCount == 0)
        #expect(diagnostics.operationSchedulerRegistrations == 2)
        #expect(diagnostics.commitSchedulerRegistrations == 1)
        #expect(scheduler.operationRegistrations + scheduler.commitRegistrations <= 4)
        #expect(commits.values.count == 1)
        #expect(commits.values.first?.0 == 2)
        #expect(commits.values.first?.1 == diagnostics.latestGeneration)
        #expect(commits.values.first?.2.contains(.displayAdded) == true)
        #expect(commits.values.first?.2.contains(.displayModeChanged) == true)

        // One accepted commit models one notification, persistence write, and
        // identity-dependent side-effect pass at the production boundary.
        let notificationCount = commits.values.count
        let persistenceCount = commits.values.count
        let identitySideEffectPassCount = commits.values.count
        #expect(notificationCount == 1)
        #expect(persistenceCount == 1)
        #expect(identitySideEffectPassCount == 1)
    }

    @Test("a completion awaiting publication is discarded when B is requested")
    func awaitingCommitCannotPublishAfterNewRequest() {
        let scheduler = InventoryManualScheduler()
        var nextValue = 0
        var committed: [Int] = []
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { _, _ in
                nextValue += 1
                return nextValue
            },
            commit: { output, _, _ in committed.append(output) }
        )

        coordinator.request(.demand(reason: .initialization))
        scheduler.runNextOperation()
        #expect(scheduler.commitCount == 1)

        coordinator.request(
            .invalidation(scope: .full, reasons: .displayAdded)
        )
        scheduler.runNextCommit()
        #expect(committed.isEmpty)
        #expect(scheduler.operationCount == 1)

        scheduler.runNextOperation()
        scheduler.runNextCommit()
        #expect(committed == [2])
        #expect(coordinator.diagnostics.commitCount == 1)
    }

    @Test("failure and cancellation retain the last accepted inventory")
    func failureAndCancellationDoNotPublish() {
        let scheduler = InventoryManualScheduler()
        var outputs: [Int?] = [1, nil, 3]
        var committed: [Int] = []
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { _, token in
                if token.isCancelled { return nil }
                return outputs.removeFirst()
            },
            commit: { output, _, _ in committed.append(output) }
        )

        coordinator.request(.demand(reason: .initialization))
        scheduler.runNextOperation()
        scheduler.runNextCommit()
        #expect(committed == [1])

        coordinator.request(
            .invalidation(scope: .full, reasons: .displayRemoved)
        )
        scheduler.runNextOperation()
        #expect(scheduler.commitCount == 0)
        #expect(committed == [1])

        coordinator.request(
            .invalidation(scope: .full, reasons: .displayAdded)
        )
        scheduler.runNextOperation()
        #expect(scheduler.commitCount == 1)
        coordinator.cancel()
        scheduler.runNextCommit()
        #expect(committed == [1])
    }
}

struct DisplayReconfigurationMappingTests {
    @Test("add, remove, move, main, mode, and combined callbacks map to one request")
    func callbackFlagMatrix() {
        let cases: [(CGDisplayChangeSummaryFlags, DisplayInventoryRefreshScope, DisplayInventoryRefreshReasons)] = [
            (.addFlag, .full, .displayAdded),
            (.removeFlag, .full, .displayRemoved),
            (.movedFlag, .arrangement, .arrangementChanged),
            (.desktopShapeChangedFlag, .arrangement, .arrangementChanged),
            (.setMainFlag, .arrangement, .mainDisplayChanged),
            (.setModeFlag, .full, .displayModeChanged),
            (.enabledFlag, .full, .displayModeChanged),
            (.disabledFlag, .full, .displayModeChanged)
        ]
        for item in cases {
            let request = DisplayReconfigurationRefreshMapper.request(for: item.0)
            #expect(request?.scope == item.1)
            #expect(request?.reasons.contains(item.2) == true)
            #expect(request?.invalidatesInventory == true)
        }

        let combined: CGDisplayChangeSummaryFlags = [
            .addFlag,
            .movedFlag,
            .setMainFlag,
            .setModeFlag
        ]
        let request = DisplayReconfigurationRefreshMapper.request(for: combined)
        #expect(request?.scope == .full)
        #expect(request?.reasons.contains(.displayAdded) == true)
        #expect(request?.reasons.contains(.arrangementChanged) == true)
        #expect(request?.reasons.contains(.mainDisplayChanged) == true)
        #expect(request?.reasons.contains(.displayModeChanged) == true)
    }
}

struct ReconciledDisplayInventoryProviderTests {
    @Test("arrangement bursts retain metadata and never invoke profiler")
    func arrangementRetainsMetadataAndUpdatesFrames() {
        let runtime = inventoryObservation(
            runtimeID: 1,
            uuid: inventoryUUIDA,
            serial: 111
        )
        let firstFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let changedFrame = CGRect(x: -240.5, y: 15.25, width: 120, height: 90)
        let source = FakeDisplayInventorySource(
            runtimes: [
                inventoryRuntime([runtime], frames: [1: firstFrame]),
                inventoryRuntime([runtime], frames: [1: changedFrame]),
                inventoryRuntime([runtime], frames: [1: changedFrame])
            ],
            iokit: [[inventoryMetadata(
                source: "iokit",
                sourceID: "io-a",
                uuid: inventoryUUIDA,
                serial: 111,
                name: "IO Name"
            )]],
            profiler: [[inventoryMetadata(
                source: "system_profiler",
                sourceID: "profiler-a",
                uuid: inventoryUUIDA,
                serial: 111,
                name: "Profiler Name"
            )]]
        )
        let provider = ReconciledDisplayInventoryProvider(
            source: source,
            initialRegistry: DisplayIdentityRegistry()
        )
        let token = DisplayInventoryCancellationToken()

        let initial = provider.prepare(scope: .full, cancellation: token)
        #expect(initial != nil)
        provider.recordCommittedInventory(
            initial!.acquisition,
            registry: initial!.reconciliation.registry
        )
        let profilerCountAfterFull = source.counts.profiler

        let moved = provider.prepare(scope: .arrangement, cancellation: token)
        #expect(moved?.acquisition.runtime.framesByRuntimeID[1] == changedFrame)
        #expect(moved?.reconciliation.display(runtimeID: 1)?.friendlyName == "Profiler Name")
        #expect(source.counts.profiler == profilerCountAfterFull)
        #expect(source.counts.iokit == 1)

        if let moved {
            provider.recordCommittedInventory(
                moved.acquisition,
                registry: moved.reconciliation.registry
            )
        }
        _ = provider.prepare(scope: .arrangement, cancellation: token)
        #expect(source.counts.profiler == profilerCountAfterFull)
        #expect(source.counts.iokit == 1)
    }

    @Test("temporary profiler failure retains established optional metadata")
    func profilerFailureRetainsMetadata() {
        let runtime = inventoryObservation(runtimeID: 1, uuid: inventoryUUIDA, serial: 111)
        let profile = inventoryMetadata(
            source: "system_profiler",
            sourceID: "profiler-a",
            uuid: inventoryUUIDA,
            serial: 111,
            name: "Stable Friendly Name"
        )
        let source = FakeDisplayInventorySource(
            runtimes: [inventoryRuntime([runtime]), inventoryRuntime([runtime])],
            iokit: [[], []],
            profiler: [[profile], nil]
        )
        let provider = ReconciledDisplayInventoryProvider(
            source: source,
            initialRegistry: DisplayIdentityRegistry()
        )
        let token = DisplayInventoryCancellationToken()
        let first = provider.prepare(scope: .full, cancellation: token)!
        provider.recordCommittedInventory(
            first.acquisition,
            registry: first.reconciliation.registry
        )
        let second = provider.prepare(scope: .full, cancellation: token)

        #expect(second?.reconciliation.display(runtimeID: 1)?.friendlyName == "Stable Friendly Name")
        #expect(second?.acquisition.profilerMetadata == [profile])
        #expect(source.counts.profiler == 2)
    }

    @Test("asynchronous provider reconciliation equals the synchronous fixture")
    func asynchronousResultMatchesSynchronousReconciliation() {
        let runtimes = [
            inventoryObservation(runtimeID: 4, uuid: inventoryUUIDA, serial: 111),
            inventoryObservation(runtimeID: 9, uuid: inventoryUUIDB, serial: 222)
        ]
        let metadata = [
            inventoryMetadata(
                source: "system_profiler",
                sourceID: "profiler-b",
                uuid: inventoryUUIDB,
                serial: 222,
                name: "Display B"
            ),
            inventoryMetadata(
                source: "system_profiler",
                sourceID: "profiler-a",
                uuid: inventoryUUIDA,
                serial: 111,
                name: "Display A"
            )
        ]
        let source = FakeDisplayInventorySource(
            runtimes: [inventoryRuntime(runtimes)],
            iokit: [[]],
            profiler: [metadata]
        )
        let registry = DisplayIdentityRegistry()
        let expected = DisplayReconciler.reconcile(
            runtimes: runtimes,
            metadata: metadata,
            priorRegistry: registry
        )
        let prepared = ReconciledDisplayInventoryProvider(
            source: source,
            initialRegistry: registry
        ).prepare(
            scope: .full,
            cancellation: DisplayInventoryCancellationToken()
        )

        let expectedValues = expected.displays.map {
            ($0.runtime.runtimeID, $0.persistentReference, $0.friendlyName, $0.resolution)
        }
        let actualValues = prepared?.reconciliation.displays.map {
            ($0.runtime.runtimeID, $0.persistentReference, $0.friendlyName, $0.resolution)
        }
        #expect(actualValues?.count == expectedValues.count)
        for index in expectedValues.indices {
            #expect(actualValues?[index].0 == expectedValues[index].0)
            #expect(actualValues?[index].1 == expectedValues[index].1)
            #expect(actualValues?[index].2 == expectedValues[index].2)
            #expect(actualValues?[index].3 == expectedValues[index].3)
        }
    }
}

final class DisplayInventoryRefreshXCTests: XCTestCase {
    func testFiveSecondProviderDoesNotBlockMainQueueAndCommitsPromptly() {
        let providerStarted = expectation(description: "provider started")
        let commitFinished = expectation(description: "commit finished")
        let sentinelRan = expectation(description: "main sentinel")
        let scheduler = DispatchDisplayInventoryRefreshScheduler()
        let finishTime = LockedInventoryValues<TimeInterval>()
        let commitDelay = LockedInventoryValues<TimeInterval>()
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { _, _ in
                providerStarted.fulfill()
                Thread.sleep(forTimeInterval: 5)
                finishTime.append(ProcessInfo.processInfo.systemUptime)
                return 1
            },
            commit: { _, _, _ in
                if let finished = finishTime.values.first {
                    commitDelay.append(
                        ProcessInfo.processInfo.systemUptime - finished
                    )
                }
                commitFinished.fulfill()
            }
        )

        coordinator.request(.demand(reason: .initialization))
        wait(for: [providerStarted], timeout: 1)
        let sentAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async {
            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime - sentAt,
                0.1
            )
            sentinelRan.fulfill()
        }
        wait(for: [sentinelRan], timeout: 0.1)
        wait(for: [commitFinished], timeout: 6)
        XCTAssertLessThan(commitDelay.values.first ?? 1, 0.1)
    }

    /// Run through DockAnchor-Release-Performance. Custom mean/p99 and resident
    /// growth checks supplement XCTest's clock, CPU, and memory metrics.
    func testReleaseRefreshSubmissionLatencyAndMemory() {
#if !DEBUG
        let scheduler = InventoryManualScheduler()
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { _, _ in 1 },
            commit: { _, _, _ in }
        )
        coordinator.request(.demand(reason: .initialization))
        for _ in 0..<10_000 {
            coordinator.request(
                .invalidation(scope: .full, reasons: .displayModeChanged)
            )
        }

        let sampleCount = 100_000
        var samples = [UInt64]()
        samples.reserveCapacity(sampleCount)
        let residentBefore = Self.residentMemoryBytes()
        for _ in 0..<sampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            coordinator.request(
                .invalidation(scope: .full, reasons: .displayModeChanged)
            )
            samples.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        let residentAfter = Self.residentMemoryBytes()
        let mean = Double(samples.reduce(0, &+)) / Double(sampleCount)
        samples.sort()
        let p99 = samples[Int(Double(sampleCount) * 0.99) - 1]

        XCTAssertLessThan(mean, 20_000)
        XCTAssertLessThan(p99, 100_000)
        XCTAssertLessThanOrEqual(
            residentAfter,
            residentBefore + UInt64(2 * 1_024 * 1_024)
        )
        XCTAssertEqual(coordinator.diagnostics.pendingRefreshCount, 1)
        XCTAssertEqual(scheduler.operationRegistrations, 1)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            for _ in 0..<sampleCount {
                coordinator.request(
                    .invalidation(scope: .arrangement, reasons: .arrangementChanged)
                )
            }
        }
#endif
    }

    /// The Thread Sanitizer scheme runs this while operation completion,
    /// launch/view/monitoring demand, display invalidation, diagnostics reads,
    /// and cancellation race through the production coordinator.
    func testRefreshCoordinatorThreadSanitizerStress() {
        let scheduler = DispatchDisplayInventoryRefreshScheduler(
            operationQueue: DispatchQueue(
                label: "DockAnchor.InventoryTSan.operations"
            ),
            commitQueue: DispatchQueue(
                label: "DockAnchor.InventoryTSan.commits"
            )
        )
        let commits = LockedInventoryValues<UInt64>()
        let coordinator = DisplayInventoryRefreshCoordinator<Int>(
            scheduler: scheduler,
            operation: { scope, token in
                if token.isCancelled { return nil }
                return scope.rawValue
            },
            commit: { _, _, generation in commits.append(generation) }
        )
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "DockAnchor.InventoryTSan.requests",
            attributes: .concurrent
        )

        for writer in 0..<4 {
            group.enter()
            queue.async {
                for index in 0..<25_000 {
                    if index.isMultiple(of: 17) {
                        coordinator.request(
                            .demand(reason: writer.isMultiple(of: 2)
                                ? .viewAppearance : .monitoringStartup)
                        )
                    } else {
                        coordinator.request(
                            .invalidation(
                                scope: index.isMultiple(of: 3) ? .full : .arrangement,
                                reasons: index.isMultiple(of: 5)
                                    ? .displayAdded : .arrangementChanged
                            )
                        )
                    }
                    if index.isMultiple(of: 101) {
                        _ = coordinator.diagnostics
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let settled = expectation(description: "settled refresh")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            coordinator.cancel()
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
        XCTAssertLessThanOrEqual(
            coordinator.diagnostics.maximumActiveOperationCount,
            1
        )
        XCTAssertLessThanOrEqual(
            coordinator.diagnostics.maximumPendingRefreshCount,
            1
        )
        _ = commits.values
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size /
                MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private final class FakeBoundedProcessRunner: BoundedProcessRunning {
    var result: BoundedProcessResult
    private(set) var invocations = 0
    private(set) var configurations: [BoundedProcessConfiguration] = []

    init(result: BoundedProcessResult) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        configuration: BoundedProcessConfiguration,
        cancellation: DisplayInventoryCancellationToken
    ) -> BoundedProcessResult {
        invocations += 1
        configurations.append(configuration)
        return result
    }
}

struct SystemDisplayInventoryProcessProviderTests {
    @Test("injected process failure is optional missing profiler metadata")
    func failingProcessProviderReturnsMissingMetadata() {
        let runner = FakeBoundedProcessRunner(result: BoundedProcessResult(
            output: Data("not json".utf8),
            terminationStatus: nil,
            termination: .timedOut
        ))
        let source = SystemDisplayInventorySource(
            processRunner: runner,
            profilerTimeout: 50,
            profilerOutputLimit: 20 * 1_024 * 1_024
        )
        let metadata = source.acquireProfilerMetadata(
            cancellation: DisplayInventoryCancellationToken()
        )

        #expect(metadata == nil)
        #expect(runner.invocations == 1)
        #expect(runner.configurations.first?.timeout == 10)
        #expect(runner.configurations.first?.maximumOutputBytes == 4 * 1_024 * 1_024)
    }

    @Test("injected process output is parsed into deterministic profiler metadata")
    func successfulProcessProviderParsesOutput() throws {
        let object: [String: Any] = [
            "SPDisplaysDataType": [[
                "spdisplays_ndrvs": [[
                    "_name": "Fixture Display",
                    "_spdisplays_display-vendor-id": "0x64",
                    "_spdisplays_display-product-id": "0x0a",
                    "_spdisplays_display-serial-number": "111",
                    "_spdisplays_display-uuid": inventoryUUIDA
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let runner = FakeBoundedProcessRunner(result: BoundedProcessResult(
            output: data,
            terminationStatus: 0,
            termination: .exited
        ))
        let source = SystemDisplayInventorySource(processRunner: runner)
        let metadata = source.acquireProfilerMetadata(
            cancellation: DisplayInventoryCancellationToken()
        )

        #expect(metadata?.count == 1)
        #expect(metadata?.first?.vendorID == 100)
        #expect(metadata?.first?.productID == 10)
        #expect(metadata?.first?.serialNumber == 111)
        #expect(metadata?.first?.name == "Fixture Display")
    }
}

struct DisplayInventoryNewestSideEffectTests {
    @Test("fallback, profile activation, and relocation permission use only newest generation")
    func identitySideEffectsUseNewestSnapshot() {
        let runtimeA = inventoryObservation(
            runtimeID: 1,
            uuid: inventoryUUIDA,
            serial: 111
        )
        let runtimeB = inventoryObservation(
            runtimeID: 2,
            uuid: inventoryUUIDB,
            serial: 222
        )
        let snapshotA = DisplayReconciler.reconcile(
            runtimes: [runtimeA],
            metadata: [],
            priorRegistry: DisplayIdentityRegistry()
        )
        let snapshotB = DisplayReconciler.reconcile(
            runtimes: [runtimeB],
            metadata: [],
            priorRegistry: snapshotA.registry
        )
        let scheduler = InventoryManualScheduler()
        var invocation = 0
        let decisions = LockedInventoryValues<(
            DisplayAnchorDecision,
            Int?,
            Bool
        )>()
        let preferredB = "\(inventoryUUIDB)-SN222"
        let coordinator = DisplayInventoryRefreshCoordinator<DisplayReconciliationSnapshot>(
            scheduler: scheduler,
            operation: { _, _ in
                invocation += 1
                return invocation == 1 ? snapshotA : snapshotB
            },
            commit: { snapshot, _, _ in
                let anchor = DisplayAnchorResolver.resolve(
                    preferredReference: preferredB,
                    fallbackRuntimeID: snapshot.displays.first?.runtime.runtimeID,
                    snapshot: snapshot,
                    intent: .persistedPreference
                )
                let profile = DisplayProfileMatcher.uniqueMatch(
                    for: 2,
                    references: [preferredB],
                    enabled: [true],
                    snapshot: snapshot
                )
                let hotPlug = DisplayHotPlugResolver.displayAdded(
                    runtimeID: 2,
                    preferredReference: preferredB,
                    profileReferences: [preferredB],
                    profileAutoActivation: [true],
                    currentAnchorIsUnique: true,
                    autoRelocate: true,
                    snapshot: snapshot
                )
                decisions.append((
                    anchor,
                    profile,
                    hotPlug.permitsAutomaticRelocation
                ))
            }
        )

        coordinator.request(.demand(reason: .initialization))
        scheduler.runNextOperation()
        coordinator.request(
            .invalidation(scope: .full, reasons: .displayAdded)
        )
        scheduler.runNextCommit()
        scheduler.runNextOperation()
        scheduler.runNextCommit()

        #expect(decisions.values.count == 1)
        #expect(decisions.values.first?.0.effectiveRuntimeID == 2)
        #expect(decisions.values.first?.0.usesFallback == false)
        #expect(decisions.values.first?.1 == 0)
        #expect(decisions.values.first?.2 == true)
    }
}

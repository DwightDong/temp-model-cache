import Foundation
import Darwin

struct BoundedProcessConfiguration: Equatable, Sendable {
    static let absoluteMaximumTimeout: TimeInterval = 10
    static let absoluteMaximumOutputBytes = 4 * 1_024 * 1_024

    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let terminationGracePeriod: TimeInterval

    init(
        timeout: TimeInterval = 8,
        maximumOutputBytes: Int = BoundedProcessConfiguration.absoluteMaximumOutputBytes,
        terminationGracePeriod: TimeInterval = 0.25
    ) {
        let finiteTimeout = timeout.isFinite
            ? timeout
            : Self.absoluteMaximumTimeout
        self.timeout = min(
            max(finiteTimeout, 0.001),
            Self.absoluteMaximumTimeout
        )
        self.maximumOutputBytes = min(
            max(maximumOutputBytes, 0),
            Self.absoluteMaximumOutputBytes
        )
        let finiteGracePeriod = terminationGracePeriod.isFinite
            ? terminationGracePeriod
            : 0.25
        self.terminationGracePeriod = max(finiteGracePeriod, 0.01)
    }
}

enum BoundedProcessTermination: Equatable, Sendable {
    case exited
    case timedOut
    case cancelled
    case outputLimitExceeded
    case launchFailed
}

struct BoundedProcessResult: Equatable, Sendable {
    let output: Data
    let terminationStatus: Int32?
    let termination: BoundedProcessTermination

    var succeeded: Bool {
        termination == .exited && terminationStatus == 0
    }
}

protocol BoundedProcessRunning: AnyObject {
    func run(
        executableURL: URL,
        arguments: [String],
        configuration: BoundedProcessConfiguration,
        cancellation: DisplayInventoryCancellationToken
    ) -> BoundedProcessResult
}

private final class BoundedProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 64 * 1_024))
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let remaining = max(0, limit - storage.count)
        if remaining > 0 {
            storage.append(contentsOf: data.prefix(remaining))
        }
        if data.count > remaining {
            exceeded = true
        }
        lock.unlock()
    }

    var didExceedLimit: Bool {
        lock.lock()
        let value = exceeded
        lock.unlock()
        return value
    }

    var data: Data {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}

/// Executes one child while a dedicated reader drains stdout concurrently.
/// The caller may block, so production invokes this only on the inventory
/// operation queue. Timeout/cancellation always terminate and wait for Process
/// to reap the direct child before returning.
final class BoundedProcessRunner: BoundedProcessRunning, @unchecked Sendable {
    private let stateLock = NSLock()
    private var activeProcessIdentifiers = Set<Int32>()

    var activeProcessCount: Int {
        stateLock.lock()
        let count = activeProcessIdentifiers.count
        stateLock.unlock()
        return count
    }

    func run(
        executableURL: URL,
        arguments: [String],
        configuration: BoundedProcessConfiguration,
        cancellation: DisplayInventoryCancellationToken
    ) -> BoundedProcessResult {
        guard !cancellation.isCancelled else {
            return BoundedProcessResult(
                output: Data(),
                terminationStatus: nil,
                termination: .cancelled
            )
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let collector = BoundedProcessOutputCollector(
            limit: configuration.maximumOutputBytes
        )
        let drainGroup = DispatchGroup()
        let terminationSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSignal.signal()
        }

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            return BoundedProcessResult(
                output: Data(),
                terminationStatus: nil,
                termination: .launchFailed
            )
        }

        let processIdentifier = process.processIdentifier
        stateLock.lock()
        activeProcessIdentifiers.insert(processIdentifier)
        stateLock.unlock()

        // The parent must not retain the pipe's write endpoint. Otherwise the
        // reader cannot observe EOF after the child exits.
        try? outputPipe.fileHandleForWriting.close()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drainGroup.leave() }
            while true {
                do {
                    guard let chunk = try outputPipe.fileHandleForReading.read(
                        upToCount: 64 * 1_024
                    ), !chunk.isEmpty else {
                        return
                    }
                    collector.append(chunk)
                } catch {
                    return
                }
            }
        }

        let start = ProcessInfo.processInfo.systemUptime
        var termination: BoundedProcessTermination = .exited
        var observedExit = false

        while !observedExit {
            if terminationSignal.wait(timeout: .now() + .milliseconds(5)) == .success {
                observedExit = true
                break
            }
            if cancellation.isCancelled {
                termination = .cancelled
                break
            }
            if collector.didExceedLimit {
                termination = .outputLimitExceeded
                break
            }
            if ProcessInfo.processInfo.systemUptime - start >= configuration.timeout {
                termination = .timedOut
                break
            }
        }

        if !observedExit {
            if process.isRunning {
                process.terminate()
            }
            if terminationSignal.wait(
                timeout: .now() + configuration.terminationGracePeriod
            ) == .timedOut,
               process.isRunning {
                Darwin.kill(processIdentifier, SIGKILL)
            }
        }

        // Foundation's Process owns waitpid bookkeeping. Waiting even after its
        // termination handler fired guarantees that a terminated child is
        // reaped before descriptors and diagnostics are released.
        process.waitUntilExit()
        drainGroup.wait()
        try? outputPipe.fileHandleForReading.close()

        stateLock.lock()
        activeProcessIdentifiers.remove(processIdentifier)
        stateLock.unlock()

        // Output may cross the limit between polling iterations. Preserve the
        // stronger limit result for an otherwise normal exit.
        if collector.didExceedLimit && termination == .exited {
            termination = .outputLimitExceeded
        }

        return BoundedProcessResult(
            output: collector.data,
            terminationStatus: process.terminationStatus,
            termination: termination
        )
    }
}

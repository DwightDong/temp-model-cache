import Foundation
import Darwin
import XCTest
@testable import DockAnchor

final class BoundedProcessRunnerTests: XCTestCase {
    func testDrainsOutputBeyondPipeCapacityWithoutDeadlock() {
        let runner = BoundedProcessRunner()
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "262144", "/dev/zero"],
            configuration: BoundedProcessConfiguration(
                timeout: 2,
                maximumOutputBytes: 512 * 1_024
            ),
            cancellation: DisplayInventoryCancellationToken()
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.output.count, 262_144)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    func testOversizedOutputIsBoundedAndChildIsReaped() {
        let runner = BoundedProcessRunner()
        let limit = 96 * 1_024
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: ["display metadata"],
            configuration: BoundedProcessConfiguration(
                timeout: 3,
                maximumOutputBytes: limit
            ),
            cancellation: DisplayInventoryCancellationToken()
        )

        XCTAssertEqual(result.termination, .outputLimitExceeded)
        XCTAssertEqual(result.output.count, limit)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    func testTimeoutIsClampedToTenSecondsAndReapsChild() {
        XCTAssertEqual(
            BoundedProcessConfiguration(timeout: 100).timeout,
            BoundedProcessConfiguration.absoluteMaximumTimeout
        )
        let runner = BoundedProcessRunner()
        let started = ProcessInfo.processInfo.systemUptime
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            configuration: BoundedProcessConfiguration(timeout: 0.05),
            cancellation: DisplayInventoryCancellationToken()
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    func testCancellationTerminatesAndReapsChild() {
        let runner = BoundedProcessRunner()
        let token = DisplayInventoryCancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            token.cancel()
        }
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            configuration: BoundedProcessConfiguration(timeout: 5),
            cancellation: token
        )

        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    func testOneHundredTimeoutAndCancellationCyclesDoNotLeakDescriptorsOrChildren() {
        let runner = BoundedProcessRunner()
        let descriptorsBefore = Self.openDescriptorCount()

        for cycle in 0..<100 {
            autoreleasepool {
                let token = DisplayInventoryCancellationToken()
                if cycle.isMultiple(of: 2) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) {
                        token.cancel()
                    }
                }
                let result = runner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["2"],
                    configuration: BoundedProcessConfiguration(
                        timeout: cycle.isMultiple(of: 2) ? 1 : 0.002,
                        maximumOutputBytes: 1_024,
                        terminationGracePeriod: 0.05
                    ),
                    cancellation: token
                )
                if cycle.isMultiple(of: 2) {
                    XCTAssertEqual(result.termination, .cancelled)
                } else {
                    XCTAssertEqual(result.termination, .timedOut)
                }
                XCTAssertEqual(runner.activeProcessCount, 0)
            }
        }

        // Give Foundation's internal dispatch sources one turn to release
        // before inspecting the process descriptor table.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let descriptorsAfter = Self.openDescriptorCount()
        XCTAssertLessThanOrEqual(descriptorsAfter, descriptorsBefore + 2)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    func testLaunchFailureIsReportedWithoutDescriptorsOrActiveChild() {
        let runner = BoundedProcessRunner()
        let result = runner.run(
            executableURL: URL(fileURLWithPath: "/definitely/missing/DockAnchor"),
            arguments: [],
            configuration: BoundedProcessConfiguration(),
            cancellation: DisplayInventoryCancellationToken()
        )
        XCTAssertEqual(result.termination, .launchFailed)
        XCTAssertEqual(result.output.count, 0)
        XCTAssertEqual(runner.activeProcessCount, 0)
    }

    private static func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count)
            ?? -1
    }
}

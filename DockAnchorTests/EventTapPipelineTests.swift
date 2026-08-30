import Foundation
import CoreGraphics
import Testing
import XCTest
@testable import DockAnchor

private let testSyntheticMarker: Int64 = 0xD0C4A5C4

private func testZone(
    _ displayID: UInt64,
    name: String? = nil,
    x: CGFloat? = nil
) -> EventTapTriggerZone {
    let originX = x ?? CGFloat(displayID - 1) * 120
    return EventTapTriggerZone(
        displayID: displayID,
        displayName: name ?? "Display \(displayID)",
        bounds: CGRect(x: originX, y: 90, width: 100, height: 10)
    )
}

private func testSnapshot(
    zones: [EventTapTriggerZone] = [testZone(1), testZone(2)],
    anchor: UInt64? = 1,
    relocating: Bool = false
) -> EventTapClassifierSnapshot {
    EventTapClassifierSnapshot(
        triggerZones: zones,
        anchorDisplayID: anchor,
        isRelocating: relocating,
        syntheticEventMarker: testSyntheticMarker
    )
}

private final class FakeFeedbackScheduledAction: EventFeedbackScheduledAction {
    private weak var scheduler: FakeFeedbackScheduler?
    private let identifier: Int

    init(scheduler: FakeFeedbackScheduler, identifier: Int) {
        self.scheduler = scheduler
        self.identifier = identifier
    }

    func cancel() {
        scheduler?.cancel(identifier: identifier)
    }
}

private final class FakeFeedbackScheduler: EventFeedbackScheduler {
    private struct Scheduled {
        let identifier: Int
        let deadline: TimeInterval
        let action: () -> Void
    }

    private var nextIdentifier = 0
    private var scheduled: [Int: Scheduled] = [:]

    private(set) var now: TimeInterval = 0
    private(set) var registrationCount = 0
    private(set) var maximumPendingCount = 0

    var pendingCount: Int { scheduled.count }

    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> EventFeedbackScheduledAction {
        nextIdentifier += 1
        registrationCount += 1
        let item = Scheduled(
            identifier: nextIdentifier,
            deadline: now + max(0, delay),
            action: action
        )
        scheduled[item.identifier] = item
        maximumPendingCount = max(maximumPendingCount, scheduled.count)
        return FakeFeedbackScheduledAction(
            scheduler: self,
            identifier: item.identifier
        )
    }

    func cancel(identifier: Int) {
        scheduled.removeValue(forKey: identifier)
    }

    func runDueActions() {
        advance(to: now)
    }

    func advance(to target: TimeInterval) {
        precondition(target >= now)
        while let next = scheduled.values
            .filter({ $0.deadline <= target })
            .min(by: {
                if $0.deadline != $1.deadline {
                    return $0.deadline < $1.deadline
                }
                return $0.identifier < $1.identifier
            }) {
            scheduled.removeValue(forKey: next.identifier)
            now = next.deadline
            next.action()
        }
        now = target
    }
}

private struct TimedStatus: Equatable {
    let time: TimeInterval
    let message: String
}

private final class FeedbackFixture {
    let scheduler = FakeFeedbackScheduler()
    private(set) var statuses: [TimedStatus] = []
    lazy var statusMessages = StatusMessageCoordinator(
        initialMessage: "Dock Anchor Active - Monitoring mouse movement"
    ) { [weak self] message in
        guard let self else { return }
        self.statuses.append(TimedStatus(time: self.scheduler.now, message: message))
    }
    lazy var feedback = BlockedEventFeedbackController(
        scheduler: scheduler,
        statusMessages: statusMessages
    ) {
        "Dock Anchor Active - Monitoring mouse movement"
    }

    func block(_ displayID: UInt64, _ name: String) {
        feedback.recordBlocked(displayID: displayID, displayName: name)
    }
}

struct EventTapDecisionMatrixTests {
    @Test("production classifier decision matrix")
    func productionDecisionMatrix() {
        let anchorZone = testZone(1, name: "Anchor", x: 0)
        let blockedZone = testZone(2, name: "Blocked", x: 120)
        let normal = testSnapshot(zones: [anchorZone, blockedZone], anchor: 1)

        let cases: [(
            name: String,
            snapshot: EventTapClassifierSnapshot,
            type: EventTapInputType,
            point: CGPoint,
            marker: Int64,
            expected: EventTapClassificationDecision
        )] = [
            (
                "anchor boundary minimum",
                normal,
                .mouseMoved,
                CGPoint(x: 0, y: 90),
                0,
                .passThrough
            ),
            (
                "anchor boundary maximum interior",
                normal,
                .mouseMoved,
                CGPoint(x: 99.999, y: 99.999),
                0,
                .passThrough
            ),
            (
                "non-anchor boundary minimum",
                normal,
                .mouseMoved,
                CGPoint(x: 120, y: 90),
                0,
                .suppressBlockedMovement(blockedZone)
            ),
            (
                "non-anchor boundary maximum interior",
                normal,
                .mouseMoved,
                CGPoint(x: 219.999, y: 99.999),
                0,
                .suppressBlockedMovement(blockedZone)
            ),
            (
                "CGRect maximum boundary is outside",
                normal,
                .mouseMoved,
                CGPoint(x: 220, y: 100),
                0,
                .passThrough
            ),
            (
                "outside every display zone",
                normal,
                .mouseMoved,
                CGPoint(x: 170, y: 50),
                0,
                .passThrough
            ),
            (
                "marked event outside relocation stays physical",
                normal,
                .mouseMoved,
                CGPoint(x: 170, y: 95),
                testSyntheticMarker,
                .suppressBlockedMovement(blockedZone)
            ),
            (
                "relocation synthetic event passes",
                testSnapshot(zones: [anchorZone, blockedZone], anchor: 1, relocating: true),
                .mouseMoved,
                CGPoint(x: 170, y: 95),
                testSyntheticMarker,
                .passThrough
            ),
            (
                "relocation matching physical event is suppressed",
                testSnapshot(zones: [anchorZone, blockedZone], anchor: 1, relocating: true),
                .mouseMoved,
                CGPoint(x: 170, y: 95),
                0,
                .suppressPhysicalDuringRelocation
            ),
            (
                "relocation physical event outside zones is suppressed",
                testSnapshot(zones: [anchorZone, blockedZone], anchor: 1, relocating: true),
                .mouseMoved,
                CGPoint(x: 170, y: 50),
                0,
                .suppressPhysicalDuringRelocation
            ),
            (
                "non-mouse input passes even during relocation",
                testSnapshot(zones: [anchorZone, blockedZone], anchor: 1, relocating: true),
                .other,
                CGPoint(x: 170, y: 95),
                0,
                .passThrough
            )
        ]

        for item in cases {
            let result = item.snapshot.classify(
                inputType: item.type,
                location: item.point,
                eventSourceUserData: item.marker
            )
            #expect(result.decision == item.expected)
        }
    }

    @Test("only applicable zones are examined once for 1, 2, 8, and 16 displays",
          arguments: [1, 2, 8, 16])
    func zoneExaminationsAreLinear(displayCount: Int) {
        let zones = (1...displayCount).map {
            testZone(UInt64($0), x: CGFloat($0) * 150)
        }

        // Anchor position in the discovery array cannot alter the amount of
        // event-time work. Exercise every possible anchor ordering.
        for anchorIndex in zones.indices {
            var reordered = zones
            let anchorZone = reordered.remove(at: anchorIndex)
            reordered.insert(anchorZone, at: anchorIndex % 2 == 0 ? 0 : reordered.count)
            let snapshot = testSnapshot(
                zones: reordered,
                anchor: anchorZone.displayID
            )
            var examined: [UInt64] = []
            let result = snapshot.classify(
                inputType: .mouseMoved,
                location: CGPoint(x: -10_000, y: -10_000),
                eventSourceUserData: 0,
                onZoneExamined: { examined.append($0) }
            )

            #expect(result.decision == .passThrough)
            #expect(result.zoneExaminations == displayCount - 1)
            #expect(examined.count == displayCount - 1)
            #expect(Set(examined).count == examined.count)
            #expect(!examined.contains(anchorZone.displayID))
        }
    }
}

struct BlockedEventFeedbackBackpressureTests {
    @Test("10,000 blocked events retain one reset and bounded scheduler work")
    func sustainedLoadIsBounded() {
        let fixture = FeedbackFixture()
        let classifier = testSnapshot()
        var suppressionCount = 0

        for eventIndex in 0..<10_000 {
            let eventTime = TimeInterval(eventIndex) / 1_000
            fixture.scheduler.advance(to: eventTime)
            let result = classifier.classify(
                inputType: .mouseMoved,
                location: CGPoint(x: 130, y: 95),
                eventSourceUserData: 0
            )
            if case let .suppressBlockedMovement(zone) = result.decision {
                suppressionCount += 1
                fixture.block(zone.displayID, zone.displayName)
            }
            fixture.scheduler.runDueActions()
            #expect(fixture.feedback.diagnostics.pendingResetActions == 1)
        }

        let finalEventTime = TimeInterval(9_999) / 1_000
        let resetTime = finalEventTime + 2.0
        fixture.scheduler.advance(to: resetTime - 0.000_001)

        #expect(suppressionCount == 10_000)
        #expect(fixture.statuses.count == 1)
        #expect(fixture.statuses[0].time <= 0.1)
        #expect(fixture.statuses[0].message ==
            "Blocked dock movement attempt to Display 2")
        #expect(fixture.feedback.diagnostics.pendingResetActions == 1)

        fixture.scheduler.advance(to: resetTime)

        let diagnostics = fixture.feedback.diagnostics
        #expect(fixture.statuses.map(\.message) == [
            "Blocked dock movement attempt to Display 2",
            "Dock Anchor Active - Monitoring mouse movement"
        ])
        #expect(abs(fixture.statuses[0].time) < 0.000_001)
        #expect(abs(fixture.statuses[1].time - resetTime) < 0.000_001)
        #expect(diagnostics.blockedStatusPublications == 1)
        #expect(diagnostics.statusResets == 1)
        #expect(diagnostics.pendingResetActions == 0)
        #expect(diagnostics.schedulerRegistrations <= 8)
        #expect(diagnostics.schedulerRegistrations == fixture.scheduler.registrationCount)
        #expect(diagnostics.maximumPendingActions <= 2)
        #expect(fixture.scheduler.maximumPendingCount <= 2)
        #expect(fixture.scheduler.pendingCount == 0)
    }

    @Test("pass-through input schedules no feedback work")
    func passThroughSchedulesNothing() {
        let fixture = FeedbackFixture()
        let classifier = testSnapshot()
        let passThroughInputs: [(EventTapInputType, CGPoint)] = [
            (.mouseMoved, CGPoint(x: 20, y: 95)),
            (.mouseMoved, CGPoint(x: 130, y: 50)),
            (.other, CGPoint(x: 130, y: 95))
        ]

        for input in passThroughInputs {
            let decision = classifier.classify(
                inputType: input.0,
                location: input.1,
                eventSourceUserData: 0
            ).decision
            #expect(decision == .passThrough)
        }

        #expect(fixture.feedback.diagnostics.schedulerRegistrations == 0)
        #expect(fixture.scheduler.registrationCount == 0)
        #expect(fixture.statuses.isEmpty)
    }

    @Test("bursts separated by idle periods publish and reset independently")
    func idleSeparatesBursts() {
        let fixture = FeedbackFixture()

        fixture.block(2, "Display 2")
        fixture.scheduler.runDueActions()
        fixture.scheduler.advance(to: 2.0)

        fixture.scheduler.advance(to: 3.0)
        fixture.block(2, "Display 2")
        fixture.scheduler.runDueActions()
        fixture.scheduler.advance(to: 5.0)

        #expect(fixture.statuses.map(\.message) == [
            "Blocked dock movement attempt to Display 2",
            "Dock Anchor Active - Monitoring mouse movement",
            "Blocked dock movement attempt to Display 2",
            "Dock Anchor Active - Monitoring mouse movement"
        ])
        #expect(fixture.feedback.diagnostics.blockedStatusPublications == 2)
        #expect(fixture.feedback.diagnostics.statusResets == 2)
        #expect(fixture.feedback.diagnostics.maximumPendingActions <= 2)
    }

    @Test("switching blocked displays coalesces and updates feedback")
    func switchingBlockedDisplays() {
        let fixture = FeedbackFixture()

        fixture.block(2, "Left Display")
        fixture.scheduler.runDueActions()

        fixture.scheduler.advance(to: 0.05)
        fixture.block(3, "Right Display")
        fixture.scheduler.runDueActions()
        #expect(fixture.statuses.count == 1)

        fixture.scheduler.advance(to: 0.1)
        #expect(fixture.statuses.last?.message ==
            "Blocked dock movement attempt to Right Display")

        fixture.scheduler.advance(to: 0.15)
        fixture.block(2, "Left Display")
        fixture.scheduler.advance(to: 0.2)
        #expect(fixture.statuses.last?.message ==
            "Blocked dock movement attempt to Left Display")

        fixture.scheduler.advance(to: 2.149_999)
        #expect(!fixture.statuses.contains {
            $0.message == "Dock Anchor Active - Monitoring mouse movement"
        })
        fixture.scheduler.advance(to: 2.15)

        #expect(fixture.statuses.map(\.message) == [
            "Blocked dock movement attempt to Left Display",
            "Blocked dock movement attempt to Right Display",
            "Blocked dock movement attempt to Left Display",
            "Dock Anchor Active - Monitoring mouse movement"
        ])
        #expect(fixture.feedback.diagnostics.maximumPendingActions <= 2)
        #expect(fixture.feedback.diagnostics.pendingResetActions == 0)
    }

    @Test("a blocked reset cannot overwrite any newer status")
    func staleResetCannotOverwriteNewerStatus() {
        let fixture = FeedbackFixture()
        fixture.block(2, "Display 2")
        fixture.scheduler.runDueActions()

        let newerMessages = [
            "Accessibility permissions revoked - stopping monitoring",
            "Relocating dock to Display 1...",
            "New display detected - reconciling display identities",
            "Dock Anchor Stopped"
        ]
        for (index, message) in newerMessages.enumerated() {
            fixture.scheduler.advance(to: 0.2 + TimeInterval(index) * 0.2)
            fixture.statusMessages.publish(message)
        }

        fixture.scheduler.advance(to: 2.0)

        #expect(fixture.statuses.last?.message == "Dock Anchor Stopped")
        #expect(!fixture.statuses.dropFirst().contains {
            $0.message == "Dock Anchor Active - Monitoring mouse movement"
        })
        #expect(fixture.feedback.diagnostics.statusResets == 0)
        #expect(fixture.feedback.diagnostics.pendingResetActions == 0)
    }
}

private final class LockedFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func recordFailure() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        let result = value
        lock.unlock()
        return result
    }
}

final class EventTapPipelineXCTests: XCTestCase {
    /// Run this test through the DockAnchor-ThreadSanitizer scheme. It also runs
    /// in ordinary suites so the concurrent snapshot behavior is never dormant.
    func testClassifierSnapshotThreadSanitizerStress() {
        let store = EventTapClassifierStore(
            syntheticEventMarker: testSyntheticMarker
        )
        let firstZones = (1...16).map {
            testZone(UInt64($0), x: CGFloat($0) * 120)
        }
        let secondZones = Array(firstZones.reversed()).map {
            EventTapTriggerZone(
                displayID: $0.displayID + 100,
                displayName: "Changed \($0.displayName)",
                bounds: $0.bounds.offsetBy(dx: 10_000, dy: 0)
            )
        }
        let failures = LockedFailureCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "DockAnchor.EventTapPipelineStress",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            for iteration in 0..<20_000 {
                if iteration.isMultiple(of: 2) {
                    store.updateConfiguration(
                        triggerZones: firstZones,
                        anchorDisplayID: 1
                    )
                } else {
                    store.updateConfiguration(
                        triggerZones: secondZones,
                        anchorDisplayID: 116
                    )
                }
                store.setRelocating(iteration.isMultiple(of: 7))
            }
            store.setRelocating(false)
            group.leave()
        }

        for reader in 0..<4 {
            group.enter()
            queue.async {
                for iteration in 0..<50_000 {
                    var examined: [UInt64] = []
                    let result = store.classify(
                        inputType: .mouseMoved,
                        location: CGPoint(
                            x: CGFloat((iteration + reader) % 16 + 1) * 120 + 5,
                            y: 95
                        ),
                        eventSourceUserData: iteration.isMultiple(of: 11)
                            ? testSyntheticMarker
                            : 0,
                        onZoneExamined: { examined.append($0) }
                    )
                    if result.zoneExaminations != examined.count ||
                        Set(examined).count != examined.count ||
                        result.zoneExaminations > 15 {
                        failures.recordFailure()
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.count, 0)
    }

    /// Execute with the DockAnchor-Release-Performance scheme. The custom
    /// 100,000-event sample enforces mean/p99 limits; XCTest simultaneously
    /// records wall-clock, CPU, and retained-memory metrics.
    func testReleaseClassificationLatencyAndMemory() {
#if !DEBUG
        let zones = (1...16).map {
            testZone(UInt64($0), x: CGFloat($0) * 120)
        }
        let store = EventTapClassifierStore(
            syntheticEventMarker: testSyntheticMarker
        )
        store.updateConfiguration(triggerZones: zones, anchorDisplayID: 8)

        let sampleCount = 100_000
        var latencies = [UInt64]()
        latencies.reserveCapacity(sampleCount)
        var checksum = 0

        for _ in 0..<sampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = store.classify(
                inputType: .mouseMoved,
                location: CGPoint(x: -1, y: -1),
                eventSourceUserData: 0
            )
            let end = DispatchTime.now().uptimeNanoseconds
            latencies.append(end - start)
            checksum &+= result.zoneExaminations
        }

        let total = latencies.reduce(UInt64(0), &+)
        let meanNanoseconds = Double(total) / Double(sampleCount)
        latencies.sort()
        let p99Nanoseconds = latencies[Int(ceil(Double(sampleCount) * 0.99)) - 1]

        XCTAssertEqual(checksum, sampleCount * 15)
        XCTAssertLessThan(
            meanNanoseconds,
            50_000,
            "Mean classification latency must stay below 50 microseconds"
        )
        XCTAssertLessThan(
            p99Nanoseconds,
            200_000,
            "p99 classification latency must stay below 200 microseconds"
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var measuredChecksum = 0
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            var iterationChecksum = 0
            for _ in 0..<sampleCount {
                iterationChecksum &+= store.classify(
                    inputType: .mouseMoved,
                    location: CGPoint(x: -1, y: -1),
                    eventSourceUserData: 0
                ).zoneExaminations
            }
            measuredChecksum = iterationChecksum
        }
        XCTAssertEqual(measuredChecksum, sampleCount * 15)
#endif
    }
}

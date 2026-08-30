import Foundation
import CoreGraphics
import Testing
import XCTest
@testable import DockAnchor

private let dockEdgeSyntheticMarker: Int64 = 0xD0C4A5C4

private enum OrientationProviderStep {
    case value(String?)
    case failure
}

private struct OrientationProviderFailure: Error {}

private final class ScriptedOrientationProvider: DockOrientationProviding {
    private let lock = NSLock()
    private var steps: [OrientationProviderStep]

    init(_ steps: [OrientationProviderStep]) {
        self.steps = steps
    }

    func readDockOrientationPreference() throws -> String? {
        lock.lock()
        let step = steps.isEmpty ? .failure : steps.removeFirst()
        lock.unlock()
        switch step {
        case let .value(value): return value
        case .failure: throw OrientationProviderFailure()
        }
    }
}

private func edgeDisplay(
    _ id: UInt64,
    _ x: CGFloat,
    _ y: CGFloat,
    _ width: CGFloat,
    _ height: CGFloat
) -> DockEdgeDisplay {
    DockEdgeDisplay(
        displayID: id,
        frame: CGRect(x: x, y: y, width: width, height: height)
    )
}

private func edgeSpan(
    of frame: CGRect,
    orientation: DockPosition
) -> DockEdgeInterval {
    switch orientation {
    case .bottom:
        return DockEdgeInterval(start: frame.minX, end: frame.maxX)
    case .left, .right:
        return DockEdgeInterval(start: frame.minY, end: frame.maxY)
    }
}

private func outwardNeighbor(
    _ id: UInt64,
    source: DockEdgeDisplay,
    orientation: DockPosition,
    start: CGFloat,
    length: CGFloat,
    depth: CGFloat = 60,
    gap: CGFloat = 0
) -> DockEdgeDisplay {
    switch orientation {
    case .bottom:
        return edgeDisplay(
            id,
            start,
            source.frame.maxY + gap,
            length,
            depth
        )
    case .left:
        return edgeDisplay(
            id,
            source.frame.minX - depth - gap,
            start,
            depth,
            length
        )
    case .right:
        return edgeDisplay(
            id,
            source.frame.maxX + gap,
            start,
            depth,
            length
        )
    }
}

private func allPermutations<T>(_ values: [T]) -> [[T]] {
    guard values.count > 1 else { return [values] }
    var result: [[T]] = []
    for index in values.indices {
        var remainder = values
        let first = remainder.remove(at: index)
        for suffix in allPermutations(remainder) {
            result.append([first] + suffix)
        }
    }
    return result
}

private func approximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.000_000_1
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func assertPlanGeometryProperties(
    _ plan: DockEdgePlan
) {
    for display in plan.displays {
        let source = edgeSpan(
            of: display.sourceFrame,
            orientation: plan.orientation
        )
        for intervals in [display.coveredSegments, display.exposedSegments] {
            for (index, interval) in intervals.enumerated() {
                #expect(interval.length > 0)
                #expect(interval.start >= source.start)
                #expect(interval.end <= source.end)
                if index > 0 {
                    #expect(intervals[index - 1].end < interval.start)
                }
            }
        }

        let partition = (display.coveredSegments.map { (interval: $0, covered: true) }
            + display.exposedSegments.map { (interval: $0, covered: false) })
            .sorted {
                if $0.interval.start != $1.interval.start {
                    return $0.interval.start < $1.interval.start
                }
                return $0.covered && !$1.covered
            }
        var cursor = source.start
        for item in partition {
            #expect(approximatelyEqual(item.interval.start, cursor))
            cursor = item.interval.end
        }
        #expect(approximatelyEqual(cursor, source.end))

        let totalLength = display.coveredSegments.reduce(CGFloat(0)) {
            $0 + $1.length
        } + display.exposedSegments.reduce(CGFloat(0)) {
            $0 + $1.length
        }
        #expect(approximatelyEqual(totalLength, source.length))

        #expect(display.triggerZones.count == display.exposedSegments.count)
        for (segment, zone) in zip(
            display.exposedSegments,
            display.triggerZones
        ) {
            #expect(zone.width > 0)
            #expect(zone.height > 0)
            #expect(display.sourceFrame.contains(
                CGPoint(x: zone.midX, y: zone.midY)
            ))
            switch plan.orientation {
            case .bottom:
                #expect(zone.minX == segment.start)
                #expect(zone.maxX == segment.end)
                #expect(zone.maxY == display.sourceFrame.maxY)
            case .left:
                #expect(zone.minY == segment.start)
                #expect(zone.maxY == segment.end)
                #expect(zone.minX == display.sourceFrame.minX)
            case .right:
                #expect(zone.minY == segment.start)
                #expect(zone.maxY == segment.end)
                #expect(zone.maxX == display.sourceFrame.maxX)
            }
        }

        if case let .eligible(geometry) = display.relocation {
            #expect(display.exposedSegments.contains(geometry.segment))
            let approachSpanCoordinate: CGFloat
            let targetSpanCoordinate: CGFloat
            switch plan.orientation {
            case .bottom:
                approachSpanCoordinate = geometry.approachPoint.x
                targetSpanCoordinate = geometry.targetPoint.x
            case .left, .right:
                approachSpanCoordinate = geometry.approachPoint.y
                targetSpanCoordinate = geometry.targetPoint.y
            }
            #expect(approachSpanCoordinate > geometry.segment.start)
            #expect(approachSpanCoordinate < geometry.segment.end)
            #expect(targetSpanCoordinate > geometry.segment.start)
            #expect(targetSpanCoordinate < geometry.segment.end)
            #expect(display.sourceFrame.contains(geometry.approachPoint))
            #expect(display.sourceFrame.contains(geometry.targetPoint))
        } else {
            #expect(display.exposedSegments.isEmpty)
        }
    }
}

private func referenceSegments(
    for source: DockEdgeDisplay,
    orientation: DockPosition,
    displays: [DockEdgeDisplay]
) -> (covered: [DockEdgeInterval], exposed: [DockEdgeInterval]) {
    let sourceSpan = edgeSpan(of: source.frame, orientation: orientation)
    var candidates: [DockEdgeInterval] = []
    for neighbor in displays where neighbor.displayID != source.displayID {
        let sharesBoundary: Bool
        switch orientation {
        case .bottom:
            sharesBoundary = neighbor.frame.minY == source.frame.maxY
        case .left:
            sharesBoundary = neighbor.frame.maxX == source.frame.minX
        case .right:
            sharesBoundary = neighbor.frame.minX == source.frame.maxX
        }
        guard sharesBoundary else { continue }
        let neighborSpan = edgeSpan(of: neighbor.frame, orientation: orientation)
        let start = max(sourceSpan.start, neighborSpan.start)
        let end = min(sourceSpan.end, neighborSpan.end)
        if end > start {
            candidates.append(DockEdgeInterval(start: start, end: end))
        }
    }

    // Independent reference: subdivide at every endpoint, classify each cell
    // by its midpoint, then combine adjacent cells with the same state.
    let boundaries = Array(Set(
        [sourceSpan.start, sourceSpan.end]
            + candidates.flatMap { [$0.start, $0.end] }
    )).sorted()
    var classified: [(DockEdgeInterval, Bool)] = []
    for index in 0..<(max(0, boundaries.count - 1)) {
        let interval = DockEdgeInterval(
            start: boundaries[index],
            end: boundaries[index + 1]
        )
        guard interval.length > 0 else { continue }
        let midpoint = interval.start + interval.length / 2
        let isCovered = candidates.contains {
            midpoint >= $0.start && midpoint < $0.end
        }
        if let previous = classified.last,
           previous.1 == isCovered,
           previous.0.end == interval.start {
            classified[classified.count - 1] = (
                DockEdgeInterval(
                    start: previous.0.start,
                    end: interval.end
                ),
                isCovered
            )
        } else {
            classified.append((interval, isCovered))
        }
    }
    return (
        covered: classified.filter { $0.1 }.map { $0.0 },
        exposed: classified.filter { !$0.1 }.map { $0.0 }
    )
}

struct DockOrientationPreferenceTests {
    @Test("orientation parser recognizes only supported values")
    func parsing() {
        #expect(DockOrientationParser.parse("bottom") == .bottom)
        #expect(DockOrientationParser.parse("  left\n") == .left)
        #expect(DockOrientationParser.parse("\tRIGHT  ") == .right)
        #expect(DockOrientationParser.parse(nil) == nil)
        #expect(DockOrientationParser.parse("") == nil)
        #expect(DockOrientationParser.parse("floating") == nil)
        #expect(DockOrientationParser.parse("left extra") == nil)
    }

    @Test("live preference transitions retain the last valid orientation")
    func transitionsAndTransientFailures() {
        let provider = ScriptedOrientationProvider([
            .value(" bottom "),
            .value("left\n"),
            .failure,
            .value(nil),
            .value("malformed"),
            .value(" right ")
        ])
        let controller = DockOrientationPreferenceController(provider: provider)

        #expect(controller.refresh() == .unchanged(.bottom))
        #expect(controller.refresh() == .changed(from: .bottom, to: .left))
        #expect(controller.refresh() == .retainedAfterFailure(.left))
        #expect(controller.refresh() == .retainedAfterInvalidValue(.left))
        #expect(controller.refresh() == .retainedAfterInvalidValue(.left))
        #expect(controller.currentOrientation == .left)
        #expect(controller.refresh() == .changed(from: .left, to: .right))
        #expect(controller.currentOrientation == .right)
    }

    @Test("live orientation reads replace complete classifier geometry")
    func liveGeometryTransitions() {
        let provider = ScriptedOrientationProvider([
            .value("bottom"),
            .value(" left "),
            .failure,
            .value("bad-value"),
            .value("right")
        ])
        let controller = DockOrientationPreferenceController(provider: provider)
        let store = EventTapClassifierStore(
            syntheticEventMarker: dockEdgeSyntheticMarker
        )
        let displays = [
            edgeDisplay(1, 0, 0, 100, 100),
            edgeDisplay(2, 25, 100, 50, 60)
        ]
        func publishCurrentPlan() -> EventTapGeometrySnapshot {
            let plan = DockEdgePlanner.makePlan(
                orientation: controller.currentOrientation,
                displays: displays
            )
            store.updateDockEdgePlan(
                plan,
                displayNames: [1: "One", 2: "Two"],
                anchorDisplayID: 2
            )
            return store.currentGeometrySnapshot()
        }

        #expect(controller.refresh() == .unchanged(.bottom))
        let bottom = publishCurrentPlan()
        #expect(bottom.dockPosition == .bottom)
        #expect(controller.refresh() == .changed(from: .bottom, to: .left))
        let left = publishCurrentPlan()
        #expect(left.dockPosition == .left)
        #expect(left != bottom)

        #expect(controller.refresh() == .retainedAfterFailure(.left))
        #expect(publishCurrentPlan() == left)
        #expect(controller.refresh() == .retainedAfterInvalidValue(.left))
        #expect(publishCurrentPlan() == left)

        #expect(controller.refresh() == .changed(from: .left, to: .right))
        let right = publishCurrentPlan()
        #expect(right.dockPosition == .right)
        #expect(right != left)
    }
}

struct DockEdgePlannerFixtureTests {
    @Test(
        "bottom, left, and right topology fixtures are order invariant",
        arguments: [DockPosition.bottom, .left, .right]
    )
    func layoutMatrix(orientation: DockPosition) {
        let source = edgeDisplay(1, -100.5, -40.25, 100.5, 80.75)
        let span = edgeSpan(of: source.frame, orientation: orientation)
        let physicalHorizontal = [
            edgeDisplay(1, 0, 0, 100, 100),
            edgeDisplay(2, 100, -20, 83, 140)
        ]
        let physicalVertical = [
            edgeDisplay(1, 0, 0, 100, 100),
            edgeDisplay(2, -15, 100, 130, 70)
        ]
        let partial = [
            source,
            outwardNeighbor(
                2,
                source: source,
                orientation: orientation,
                start: span.start + 20.25,
                length: 40.5
            )
        ]
        let overlappingCoverage = [
            source,
            outwardNeighbor(
                2,
                source: source,
                orientation: orientation,
                start: span.start + 5.25,
                length: 50.25
            ),
            outwardNeighbor(
                3,
                source: source,
                orientation: orientation,
                start: span.start + 35.5,
                length: 50.25
            ),
            outwardNeighbor(
                4,
                source: source,
                orientation: orientation,
                start: span.start + 70.25,
                length: 20
            )
        ]
        let fullyCovered = [
            source,
            outwardNeighbor(
                2,
                source: source,
                orientation: orientation,
                start: span.start - 10,
                length: span.length / 2 + 20
            ),
            outwardNeighbor(
                3,
                source: source,
                orientation: orientation,
                start: span.start + span.length / 2,
                length: span.length / 2 + 10
            )
        ]
        let cornerTouch = [
            source,
            outwardNeighbor(
                2,
                source: source,
                orientation: orientation,
                start: span.end,
                length: 50
            )
        ]
        let onePixelGap = [
            source,
            outwardNeighbor(
                2,
                source: source,
                orientation: orientation,
                start: span.start,
                length: span.length,
                gap: 1
            )
        ]
        let fixtures = [
            [source],
            physicalHorizontal,
            physicalVertical,
            partial,
            overlappingCoverage,
            fullyCovered,
            cornerTouch,
            onePixelGap
        ]

        for fixture in fixtures {
            let expected = DockEdgePlanner.makePlan(
                orientation: orientation,
                displays: fixture
            )
            assertPlanGeometryProperties(expected)
            for permutation in allPermutations(fixture) {
                #expect(DockEdgePlanner.makePlan(
                    orientation: orientation,
                    displays: permutation
                ) == expected)
            }
        }

        #expect(
            DockEdgePlanner.makePlan(
                orientation: orientation,
                displays: cornerTouch
            ).displayPlan(for: 1)?.exposedSegments == [span]
        )
        #expect(
            DockEdgePlanner.makePlan(
                orientation: orientation,
                displays: onePixelGap
            ).displayPlan(for: 1)?.exposedSegments == [span]
        )
        #expect(
            DockEdgePlanner.makePlan(
                orientation: orientation,
                displays: fullyCovered
            ).displayPlan(for: 1)?.relocation == .noEligibleEdge
        )
    }

    @Test(
        "T coverage creates the exact two exposed edge segments",
        arguments: [DockPosition.bottom, .left, .right]
    )
    func tShape(orientation: DockPosition) {
        let source = edgeDisplay(10, 10.5, -20.25, 100, 80)
        let span = edgeSpan(of: source.frame, orientation: orientation)
        let neighbor = outwardNeighbor(
            20,
            source: source,
            orientation: orientation,
            start: span.start + 25,
            length: 50
        )
        let sourcePlan = DockEdgePlanner.makePlan(
            orientation: orientation,
            displays: [source, neighbor]
        ).displayPlan(for: source.displayID)

        #expect(sourcePlan?.coveredSegments == [
            DockEdgeInterval(start: span.start + 25, end: span.start + 75)
        ])
        #expect(sourcePlan?.exposedSegments == [
            DockEdgeInterval(start: span.start, end: span.start + 25),
            DockEdgeInterval(start: span.start + 75, end: span.end)
        ])
    }

    @Test("translation preserves plans for every orientation")
    func translationInvariance() {
        let source = edgeDisplay(1, -40.5, 20.25, 120, 90)
        let translations: [(CGFloat, CGFloat)] = [
            (1_000.25, -700.5),
            (-333.75, 812.25)
        ]

        for orientation in DockPosition.allCases {
            let span = edgeSpan(of: source.frame, orientation: orientation)
            let displays = [
                source,
                outwardNeighbor(
                    2,
                    source: source,
                    orientation: orientation,
                    start: span.start + 15.5,
                    length: 27.25
                ),
                outwardNeighbor(
                    3,
                    source: source,
                    orientation: orientation,
                    start: span.start + 65.25,
                    length: 40.5
                )
            ]
            let original = DockEdgePlanner.makePlan(
                orientation: orientation,
                displays: displays
            )
            for translation in translations {
                let movedDisplays = displays.map {
                    DockEdgeDisplay(
                        displayID: $0.displayID,
                        frame: $0.frame.offsetBy(
                            dx: translation.0,
                            dy: translation.1
                        )
                    )
                }
                let moved = DockEdgePlanner.makePlan(
                    orientation: orientation,
                    displays: movedDisplays
                )
                for originalDisplay in original.displays {
                    let movedDisplay = moved.displayPlan(
                        for: originalDisplay.displayID
                    )
                    let spanDelta = orientation == .bottom
                        ? translation.0
                        : translation.1
                    #expect(movedDisplay?.coveredSegments ==
                        originalDisplay.coveredSegments.map {
                            DockEdgeInterval(
                                start: $0.start + spanDelta,
                                end: $0.end + spanDelta
                            )
                        })
                    #expect(movedDisplay?.exposedSegments ==
                        originalDisplay.exposedSegments.map {
                            DockEdgeInterval(
                                start: $0.start + spanDelta,
                                end: $0.end + spanDelta
                            )
                        })
                    #expect(movedDisplay?.triggerZones ==
                        originalDisplay.triggerZones.map {
                            $0.offsetBy(dx: translation.0, dy: translation.1)
                        })
                    if let originalGeometry = originalDisplay.relocation.geometry,
                       let movedGeometry = movedDisplay?.relocation.geometry {
                        #expect(movedGeometry.approachPoint == CGPoint(
                            x: originalGeometry.approachPoint.x + translation.0,
                            y: originalGeometry.approachPoint.y + translation.1
                        ))
                        #expect(movedGeometry.targetPoint == CGPoint(
                            x: originalGeometry.targetPoint.x + translation.0,
                            y: originalGeometry.targetPoint.y + translation.1
                        ))
                    }
                }
            }
        }
    }

    @Test("horizontal reflection maps left plans to right plans")
    func leftRightReflectionInvariance() {
        let displays = [
            edgeDisplay(1, -20.5, -100.25, 80, 160.5),
            edgeDisplay(2, -70.5, -70, 50, 30.25),
            edgeDisplay(3, -90.5, -55, 70, 80)
        ]
        let reflected = displays.map {
            DockEdgeDisplay(
                displayID: $0.displayID,
                frame: CGRect(
                    x: -$0.frame.maxX,
                    y: $0.frame.minY,
                    width: $0.frame.width,
                    height: $0.frame.height
                )
            )
        }
        let left = DockEdgePlanner.makePlan(
            orientation: .left,
            displays: displays
        )
        let right = DockEdgePlanner.makePlan(
            orientation: .right,
            displays: reflected
        )

        for leftDisplay in left.displays {
            let rightDisplay = right.displayPlan(for: leftDisplay.displayID)
            #expect(rightDisplay?.coveredSegments == leftDisplay.coveredSegments)
            #expect(rightDisplay?.exposedSegments == leftDisplay.exposedSegments)
            #expect(rightDisplay?.triggerZones == leftDisplay.triggerZones.map {
                CGRect(
                    x: -$0.maxX,
                    y: $0.minY,
                    width: $0.width,
                    height: $0.height
                )
            })
            if let leftGeometry = leftDisplay.relocation.geometry,
               let rightGeometry = rightDisplay?.relocation.geometry {
                #expect(rightGeometry.approachPoint == CGPoint(
                    x: -leftGeometry.approachPoint.x,
                    y: leftGeometry.approachPoint.y
                ))
                #expect(rightGeometry.targetPoint == CGPoint(
                    x: -leftGeometry.targetPoint.x,
                    y: leftGeometry.targetPoint.y
                ))
            }
        }
    }
}

private func pointInTriggerBand(
    frame: CGRect,
    orientation: DockPosition,
    spanCoordinate: CGFloat
) -> CGPoint {
    switch orientation {
    case .bottom:
        return CGPoint(x: spanCoordinate, y: frame.maxY - 1)
    case .left:
        return CGPoint(x: frame.minX + 1, y: spanCoordinate)
    case .right:
        return CGPoint(x: frame.maxX - 1, y: spanCoordinate)
    }
}

private func pointOutsideOutwardEdge(
    frame: CGRect,
    orientation: DockPosition,
    spanCoordinate: CGFloat
) -> CGPoint {
    switch orientation {
    case .bottom:
        return CGPoint(x: spanCoordinate, y: frame.maxY)
    case .left:
        return CGPoint(x: frame.minX - 0.001, y: spanCoordinate)
    case .right:
        return CGPoint(x: frame.maxX, y: spanCoordinate)
    }
}

struct DockEdgeProductionIntegrationTests {
    @Test(
        "production classifier protects exposed cells and passes covered boundaries",
        arguments: [DockPosition.bottom, .left, .right]
    )
    func productionClassification(orientation: DockPosition) {
        let source = edgeDisplay(1, 0, 0, 100, 100)
        let span = edgeSpan(of: source.frame, orientation: orientation)
        let covering = outwardNeighbor(
            2,
            source: source,
            orientation: orientation,
            start: span.start + 25,
            length: 50
        )
        let plan = DockEdgePlanner.makePlan(
            orientation: orientation,
            displays: [source, covering]
        )
        let store = EventTapClassifierStore(
            syntheticEventMarker: dockEdgeSyntheticMarker
        )
        store.updateDockEdgePlan(
            plan,
            displayNames: [1: "Source", 2: "Neighbor"],
            anchorDisplayID: 2
        )

        func decision(at point: CGPoint) -> EventTapClassificationDecision {
            store.classify(
                inputType: .mouseMoved,
                location: point,
                eventSourceUserData: 0
            ).decision
        }

        let firstInterior = pointInTriggerBand(
            frame: source.frame,
            orientation: orientation,
            spanCoordinate: span.start + 10
        )
        let coveredInterior = pointInTriggerBand(
            frame: source.frame,
            orientation: orientation,
            spanCoordinate: span.start + 50
        )
        let firstMaximumBoundary = pointInTriggerBand(
            frame: source.frame,
            orientation: orientation,
            spanCoordinate: span.start + 25
        )
        let secondMinimumBoundary = pointInTriggerBand(
            frame: source.frame,
            orientation: orientation,
            spanCoordinate: span.start + 75
        )

        if case let .suppressBlockedMovement(zone) = decision(at: firstInterior) {
            #expect(zone.displayID == 1)
        } else {
            Issue.record("Expected exposed segment movement to be suppressed")
        }
        #expect(decision(at: coveredInterior) == .passThrough)
        // CGRect half-open boundaries make the start of covered coverage pass,
        // while the start of the following exposed segment is protected.
        #expect(decision(at: firstMaximumBoundary) == .passThrough)
        if case .suppressBlockedMovement = decision(at: secondMinimumBoundary) {
            // Expected.
        } else {
            Issue.record("Expected the exposed minimum boundary to be suppressed")
        }
        #expect(decision(at: pointOutsideOutwardEdge(
            frame: source.frame,
            orientation: orientation,
            spanCoordinate: span.start + 10
        )) == .passThrough)

        // Replacing the same plan with source as anchor removes every one of
        // its disjoint trigger zones in one configuration update.
        store.updateDockEdgePlan(
            plan,
            displayNames: [1: "Source", 2: "Neighbor"],
            anchorDisplayID: 1
        )
        #expect(decision(at: firstInterior) == .passThrough)
    }

    @Test(
        "relocation uses strict exposed interiors and refuses fully covered edges",
        arguments: [DockPosition.bottom, .left, .right]
    )
    func relocationEligibility(orientation: DockPosition) {
        let source = edgeDisplay(1, -20.5, 10.25, 100, 100)
        let span = edgeSpan(of: source.frame, orientation: orientation)
        let partial = outwardNeighbor(
            2,
            source: source,
            orientation: orientation,
            start: span.start + 35,
            length: 30
        )
        let eligiblePlan = DockEdgePlanner.makePlan(
            orientation: orientation,
            displays: [source, partial]
        )
        guard let geometry = eligiblePlan.displayPlan(
            for: source.displayID
        )?.relocation.geometry else {
            Issue.record("Expected an eligible relocation")
            return
        }
        let targetSpan = orientation == .bottom
            ? geometry.targetPoint.x
            : geometry.targetPoint.y
        #expect(targetSpan > geometry.segment.start)
        #expect(targetSpan < geometry.segment.end)

        let full = outwardNeighbor(
            2,
            source: source,
            orientation: orientation,
            start: span.start,
            length: span.length
        )
        let ineligiblePlan = DockEdgePlanner.makePlan(
            orientation: orientation,
            displays: [source, full]
        )
        let store = EventTapClassifierStore(
            syntheticEventMarker: dockEdgeSyntheticMarker
        )
        store.updateDockEdgePlan(
            ineligiblePlan,
            displayNames: [1: "Anchor", 2: "Neighbor"],
            anchorDisplayID: 1
        )

        var cursorMovementCount = 0
        if let relocation = store.beginRelocation(for: 1)?.geometry {
            cursorMovementCount += 1
            _ = relocation.targetPoint
        }
        #expect(cursorMovementCount == 0)
        #expect(store.relocationResult(for: 1) == .noEligibleEdge)
        // beginRelocation must not even enter relocation suppression when there
        // is no usable edge, so an unrelated physical event still passes.
        #expect(store.classify(
            inputType: .mouseMoved,
            location: CGPoint(x: -50_000, y: -50_000),
            eventSourceUserData: 0
        ).decision == .passThrough)
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func integer(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func quarter(_ lower: Int, _ upper: Int) -> CGFloat {
        let count = (upper - lower) * 4 + 1
        return CGFloat(lower * 4 + integer(count)) / 4
    }

    mutating func shuffled<T>(_ input: [T]) -> [T] {
        guard input.count > 1 else { return input }
        var result = input
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            let other = integer(index + 1)
            result.swapAt(index, other)
        }
        return result
    }
}

private func randomizedLayout(
    orientation: DockPosition,
    count: Int,
    random: inout DeterministicRandom
) -> [DockEdgeDisplay] {
    var displays: [DockEdgeDisplay] = []
    for index in 0..<count {
        let width = random.quarter(20, 180)
        let height = random.quarter(20, 180)
        let display: DockEdgeDisplay
        if index > 0, random.integer(4) != 0 {
            let base = displays[random.integer(displays.count)]
            let baseSpan = edgeSpan(of: base.frame, orientation: orientation)
            let spanStart = baseSpan.start + random.quarter(-60, 160)
            switch orientation {
            case .bottom:
                display = edgeDisplay(
                    UInt64(index + 1),
                    spanStart,
                    base.frame.maxY,
                    width,
                    height
                )
            case .left:
                display = edgeDisplay(
                    UInt64(index + 1),
                    base.frame.minX - width,
                    spanStart,
                    width,
                    height
                )
            case .right:
                display = edgeDisplay(
                    UInt64(index + 1),
                    base.frame.maxX,
                    spanStart,
                    width,
                    height
                )
            }
        } else {
            display = edgeDisplay(
                UInt64(index + 1),
                random.quarter(-500, 500),
                random.quarter(-500, 500),
                width,
                height
            )
        }
        displays.append(display)
    }
    return displays
}

struct DockEdgeRandomizedOracleTests {
    @Test("random layouts up to 16 displays match an independent interval oracle")
    func randomizedReferenceComparison() {
        var random = DeterministicRandom(seed: 0xD0C4_A5C4_77)
        for orientation in DockPosition.allCases {
            for _ in 0..<64 {
                let displayCount = 1 + random.integer(16)
                let displays = randomizedLayout(
                    orientation: orientation,
                    count: displayCount,
                    random: &random
                )
                let plan = DockEdgePlanner.makePlan(
                    orientation: orientation,
                    displays: displays
                )
                assertPlanGeometryProperties(plan)
                for source in displays {
                    let reference = referenceSegments(
                        for: source,
                        orientation: orientation,
                        displays: displays
                    )
                    let actual = plan.displayPlan(for: source.displayID)
                    #expect(actual?.coveredSegments == reference.covered)
                    #expect(actual?.exposedSegments == reference.exposed)
                }

                let reordered = random.shuffled(displays)
                #expect(DockEdgePlanner.makePlan(
                    orientation: orientation,
                    displays: reordered
                ) == plan)

                let dx = random.quarter(-1_000, 1_000)
                let dy = random.quarter(-1_000, 1_000)
                let translated = displays.map {
                    DockEdgeDisplay(
                        displayID: $0.displayID,
                        frame: $0.frame.offsetBy(dx: dx, dy: dy)
                    )
                }
                let translatedPlan = DockEdgePlanner.makePlan(
                    orientation: orientation,
                    displays: random.shuffled(translated)
                )
                for source in translated {
                    let reference = referenceSegments(
                        for: source,
                        orientation: orientation,
                        displays: translated
                    )
                    #expect(translatedPlan.displayPlan(
                        for: source.displayID
                    )?.coveredSegments == reference.covered)
                    #expect(translatedPlan.displayPlan(
                        for: source.displayID
                    )?.exposedSegments == reference.exposed)
                }
            }
        }
    }
}

private final class DockGeometryFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func fail() {
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

final class DockEdgePlanningConcurrencyTests: XCTestCase {
    /// Run through DockAnchor-ThreadSanitizer. Orientation and layout are
    /// intentionally changed together while classifier and relocation readers
    /// verify that only complete old/new snapshots are observable.
    func testConcurrentOrientationAndLayoutUpdatesAreCoherent() {
        let store = EventTapClassifierStore(
            syntheticEventMarker: dockEdgeSyntheticMarker
        )
        let bottomDisplays = [
            edgeDisplay(1, 0, 0, 100, 100),
            edgeDisplay(2, 25, 100, 50, 80),
            edgeDisplay(3, 100, 0, 100, 100)
        ]
        let rightDisplays = [
            edgeDisplay(1, -400, -200, 120, 160),
            edgeDisplay(2, -280, -160, 90, 70),
            edgeDisplay(3, 50, -30, 150, 130)
        ]
        let bottom = DockEdgePlanner.makePlan(
            orientation: .bottom,
            displays: bottomDisplays
        )
        let right = DockEdgePlanner.makePlan(
            orientation: .right,
            displays: rightDisplays
        )
        let names: [UInt64: String] = [1: "One", 2: "Two", 3: "Three"]
        store.updateDockEdgePlan(
            bottom,
            displayNames: names,
            anchorDisplayID: 3
        )
        let expectedBottom = store.currentGeometrySnapshot()
        store.updateDockEdgePlan(
            right,
            displayNames: names,
            anchorDisplayID: 2
        )
        let expectedRight = store.currentGeometrySnapshot()
        store.updateDockEdgePlan(
            bottom,
            displayNames: names,
            anchorDisplayID: 3
        )

        let failures = DockGeometryFailureCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "DockAnchor.DockEdgePlanningStress",
            attributes: .concurrent
        )

        group.enter()
        queue.async {
            for iteration in 0..<20_000 {
                if iteration.isMultiple(of: 2) {
                    store.updateDockEdgePlan(
                        bottom,
                        displayNames: names,
                        anchorDisplayID: 3
                    )
                } else {
                    store.updateDockEdgePlan(
                        right,
                        displayNames: names,
                        anchorDisplayID: 2
                    )
                }
            }
            group.leave()
        }

        for reader in 0..<4 {
            group.enter()
            queue.async {
                for iteration in 0..<40_000 {
                    let snapshot = store.currentGeometrySnapshot()
                    if snapshot != expectedBottom && snapshot != expectedRight {
                        failures.fail()
                    }
                    _ = store.classify(
                        inputType: .mouseMoved,
                        location: CGPoint(
                            x: CGFloat(iteration + reader),
                            y: CGFloat(reader)
                        ),
                        eventSourceUserData: 0
                    )
                    _ = store.relocationResult(for: UInt64((iteration % 3) + 1))
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.count, 0)
    }
}

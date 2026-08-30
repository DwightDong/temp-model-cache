import Foundation
import CoreGraphics

/// The physical edge on which macOS is configured to place the Dock.
enum DockPosition: String, CaseIterable, Equatable, Sendable {
    case bottom
    case left
    case right
}

/// Parsing is deliberately closed: an unavailable or malformed preference is
/// not the same as the system's default. Runtime code retains its last valid
/// value in either case.
enum DockOrientationParser {
    static func parse(_ rawValue: String?) -> DockPosition? {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty else {
            return nil
        }
        return DockPosition(rawValue: value)
    }
}

protocol DockOrientationProviding {
    func readDockOrientationPreference() throws -> String?
}

enum SystemDockOrientationProviderError: Error {
    case commandFailed(Int32)
    case unreadableOutput
}

/// Uses the same user preference domain as the Dock. The provider is injected
/// behind a protocol so transient command failures and malformed values can be
/// exercised without altering the retained orientation.
final class SystemDockOrientationProvider: DockOrientationProviding {
    func readDockOrientationPreference() throws -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", "com.apple.dock", "orientation"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw SystemDockOrientationProviderError.commandFailed(
                task.terminationStatus
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let value = String(data: data, encoding: .utf8) else {
            throw SystemDockOrientationProviderError.unreadableOutput
        }
        return value
    }
}

enum DockOrientationRefreshResult: Equatable {
    case changed(from: DockPosition, to: DockPosition)
    case unchanged(DockPosition)
    case retainedAfterInvalidValue(DockPosition)
    case retainedAfterFailure(DockPosition)

    var currentOrientation: DockPosition {
        switch self {
        case let .changed(_, to): return to
        case let .unchanged(value),
             let .retainedAfterInvalidValue(value),
             let .retainedAfterFailure(value):
            return value
        }
    }

    var didChange: Bool {
        if case .changed = self { return true }
        return false
    }
}

/// Thread-safe retained preference state. A failed or malformed read can never
/// silently move a left/right configuration back to bottom.
final class DockOrientationPreferenceController: @unchecked Sendable {
    private let lock = NSLock()
    private let refreshLock = NSLock()
    private let provider: DockOrientationProviding
    private var orientation: DockPosition

    init(
        provider: DockOrientationProviding,
        initialOrientation: DockPosition = .bottom
    ) {
        self.provider = provider
        orientation = initialOrientation
    }

    var currentOrientation: DockPosition {
        lock.lock()
        let current = orientation
        lock.unlock()
        return current
    }

    @discardableResult
    func refresh() -> DockOrientationRefreshResult {
        refreshLock.lock()
        defer { refreshLock.unlock() }

        let rawValue: String?
        do {
            rawValue = try provider.readDockOrientationPreference()
        } catch {
            lock.lock()
            let current = orientation
            lock.unlock()
            return .retainedAfterFailure(current)
        }

        guard let parsed = DockOrientationParser.parse(rawValue) else {
            lock.lock()
            let current = orientation
            lock.unlock()
            return .retainedAfterInvalidValue(current)
        }

        lock.lock()
        let previous = orientation
        orientation = parsed
        lock.unlock()
        if previous == parsed {
            return .unchanged(parsed)
        }
        return .changed(from: previous, to: parsed)
    }
}

struct DockEdgeDisplay: Equatable, Sendable {
    let displayID: UInt64
    let frame: CGRect
}

/// Half-open interval [start, end). This matches Core Graphics rectangle
/// containment: the minimum boundary is included and the maximum is excluded.
struct DockEdgeInterval: Equatable, Sendable {
    let start: CGFloat
    let end: CGFloat

    var length: CGFloat { end - start }
}

struct DockEdgeRelocationGeometry: Equatable, Sendable {
    let displayID: UInt64
    let orientation: DockPosition
    let segment: DockEdgeInterval
    let approachPoint: CGPoint
    let targetPoint: CGPoint
}

enum DockEdgeRelocationResult: Equatable, Sendable {
    case eligible(DockEdgeRelocationGeometry)
    case noEligibleEdge

    var geometry: DockEdgeRelocationGeometry? {
        guard case let .eligible(value) = self else { return nil }
        return value
    }
}

struct DockEdgeDisplayPlan: Equatable, Sendable {
    let displayID: UInt64
    let sourceFrame: CGRect
    let coveredSegments: [DockEdgeInterval]
    let exposedSegments: [DockEdgeInterval]
    let triggerZones: [CGRect]
    let relocation: DockEdgeRelocationResult
}

struct DockEdgePlan: Equatable, Sendable {
    let orientation: DockPosition
    let displays: [DockEdgeDisplayPlan]

    func displayPlan(for displayID: UInt64) -> DockEdgeDisplayPlan? {
        displays.first { $0.displayID == displayID }
    }
}

enum DockEdgePlanner {
    struct Configuration: Equatable, Sendable {
        var triggerDepth: CGFloat = 10
        var approachDistance: CGFloat = 50
        var targetInset: CGFloat = 1
    }

    static func makePlan(
        orientation: DockPosition,
        displays: [DockEdgeDisplay],
        configuration: Configuration = Configuration()
    ) -> DockEdgePlan {
        let normalized = normalizedDisplays(displays)
        let displayPlans = normalized.map { display in
            makeDisplayPlan(
                for: display,
                orientation: orientation,
                allDisplays: normalized,
                configuration: configuration
            )
        }
        return DockEdgePlan(
            orientation: orientation,
            displays: displayPlans
        )
    }

    private static func normalizedDisplays(
        _ displays: [DockEdgeDisplay]
    ) -> [DockEdgeDisplay] {
        let valid = displays.compactMap { display -> DockEdgeDisplay? in
            let frame = display.frame.standardized
            guard frame.minX.isFinite,
                  frame.minY.isFinite,
                  frame.maxX.isFinite,
                  frame.maxY.isFinite,
                  frame.width > 0,
                  frame.height > 0 else {
                return nil
            }
            return DockEdgeDisplay(
                displayID: display.displayID,
                frame: frame
            )
        }.sorted(by: displayOrdering)

        // Runtime display IDs are unique in production. Deterministically
        // retaining one frame also keeps malformed duplicate input from making
        // the result depend on discovery order.
        var seen = Set<UInt64>()
        return valid.filter { seen.insert($0.displayID).inserted }
    }

    private static func displayOrdering(
        _ lhs: DockEdgeDisplay,
        _ rhs: DockEdgeDisplay
    ) -> Bool {
        if lhs.displayID != rhs.displayID {
            return lhs.displayID < rhs.displayID
        }
        if lhs.frame.minX != rhs.frame.minX {
            return lhs.frame.minX < rhs.frame.minX
        }
        if lhs.frame.minY != rhs.frame.minY {
            return lhs.frame.minY < rhs.frame.minY
        }
        if lhs.frame.width != rhs.frame.width {
            return lhs.frame.width < rhs.frame.width
        }
        return lhs.frame.height < rhs.frame.height
    }

    private static func makeDisplayPlan(
        for display: DockEdgeDisplay,
        orientation: DockPosition,
        allDisplays: [DockEdgeDisplay],
        configuration: Configuration
    ) -> DockEdgeDisplayPlan {
        let sourceInterval = edgeInterval(
            for: display.frame,
            orientation: orientation
        )
        let coverage = allDisplays.compactMap { neighbor -> DockEdgeInterval? in
            guard neighbor.displayID != display.displayID,
                  sharesOutwardBoundary(
                    source: display.frame,
                    neighbor: neighbor.frame,
                    orientation: orientation
                  ) else {
                return nil
            }
            let candidate = edgeInterval(
                for: neighbor.frame,
                orientation: orientation
            )
            let start = max(sourceInterval.start, candidate.start)
            let end = min(sourceInterval.end, candidate.end)
            // Corner-only contact has zero length and is intentionally ignored.
            guard end > start else { return nil }
            return DockEdgeInterval(start: start, end: end)
        }
        let covered = union(coverage)
        let exposed = complement(of: covered, within: sourceInterval)
        let triggerZones = exposed.compactMap {
            triggerZone(
                for: $0,
                frame: display.frame,
                orientation: orientation,
                depth: configuration.triggerDepth
            )
        }
        let relocation = relocationResult(
            displayID: display.displayID,
            frame: display.frame,
            orientation: orientation,
            exposedSegments: exposed,
            configuration: configuration
        )

        return DockEdgeDisplayPlan(
            displayID: display.displayID,
            sourceFrame: display.frame,
            coveredSegments: covered,
            exposedSegments: exposed,
            triggerZones: triggerZones,
            relocation: relocation
        )
    }

    private static func edgeInterval(
        for frame: CGRect,
        orientation: DockPosition
    ) -> DockEdgeInterval {
        switch orientation {
        case .bottom:
            return DockEdgeInterval(start: frame.minX, end: frame.maxX)
        case .left, .right:
            return DockEdgeInterval(start: frame.minY, end: frame.maxY)
        }
    }

    private static func sharesOutwardBoundary(
        source: CGRect,
        neighbor: CGRect,
        orientation: DockPosition
    ) -> Bool {
        switch orientation {
        case .bottom:
            return neighbor.minY == source.maxY
        case .left:
            return neighbor.maxX == source.minX
        case .right:
            return neighbor.minX == source.maxX
        }
    }

    private static func union(
        _ intervals: [DockEdgeInterval]
    ) -> [DockEdgeInterval] {
        let sorted = intervals
            .filter { $0.end > $0.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        guard var current = sorted.first else { return [] }

        var result: [DockEdgeInterval] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current = DockEdgeInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                result.append(current)
                current = interval
            }
        }
        result.append(current)
        return result
    }

    private static func complement(
        of covered: [DockEdgeInterval],
        within source: DockEdgeInterval
    ) -> [DockEdgeInterval] {
        var cursor = source.start
        var exposed: [DockEdgeInterval] = []
        for interval in covered {
            if interval.start > cursor {
                exposed.append(DockEdgeInterval(
                    start: cursor,
                    end: interval.start
                ))
            }
            cursor = max(cursor, interval.end)
        }
        if cursor < source.end {
            exposed.append(DockEdgeInterval(start: cursor, end: source.end))
        }
        return exposed
    }

    private static func triggerZone(
        for segment: DockEdgeInterval,
        frame: CGRect,
        orientation: DockPosition,
        depth requestedDepth: CGFloat
    ) -> CGRect? {
        guard segment.length > 0, requestedDepth > 0 else { return nil }
        switch orientation {
        case .bottom:
            let depth = min(requestedDepth, frame.height)
            guard depth > 0 else { return nil }
            return CGRect(
                x: segment.start,
                y: frame.maxY - depth,
                width: segment.length,
                height: depth
            )
        case .left:
            let depth = min(requestedDepth, frame.width)
            guard depth > 0 else { return nil }
            return CGRect(
                x: frame.minX,
                y: segment.start,
                width: depth,
                height: segment.length
            )
        case .right:
            let depth = min(requestedDepth, frame.width)
            guard depth > 0 else { return nil }
            return CGRect(
                x: frame.maxX - depth,
                y: segment.start,
                width: depth,
                height: segment.length
            )
        }
    }

    private static func relocationResult(
        displayID: UInt64,
        frame: CGRect,
        orientation: DockPosition,
        exposedSegments: [DockEdgeInterval],
        configuration: Configuration
    ) -> DockEdgeRelocationResult {
        let candidates = exposedSegments.compactMap { segment -> (
            segment: DockEdgeInterval,
            coordinate: CGFloat
        )? in
            guard let coordinate = strictInteriorCoordinate(of: segment) else {
                return nil
            }
            return (segment, coordinate)
        }.sorted { lhs, rhs in
            if lhs.segment.length != rhs.segment.length {
                return lhs.segment.length > rhs.segment.length
            }
            let sourceCenter: CGFloat
            switch orientation {
            case .bottom: sourceCenter = frame.midX
            case .left, .right: sourceCenter = frame.midY
            }
            let lhsDistance = abs(lhs.coordinate - sourceCenter)
            let rhsDistance = abs(rhs.coordinate - sourceCenter)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.segment.start < rhs.segment.start
        }
        guard let selected = candidates.first else {
            return .noEligibleEdge
        }

        let targetNormal = inwardCoordinate(
            frame: frame,
            orientation: orientation,
            distance: configuration.targetInset
        )
        let approachNormal = inwardCoordinate(
            frame: frame,
            orientation: orientation,
            distance: configuration.approachDistance
        )
        let approach: CGPoint
        let target: CGPoint
        switch orientation {
        case .bottom:
            approach = CGPoint(x: selected.coordinate, y: approachNormal)
            target = CGPoint(x: selected.coordinate, y: targetNormal)
        case .left, .right:
            approach = CGPoint(x: approachNormal, y: selected.coordinate)
            target = CGPoint(x: targetNormal, y: selected.coordinate)
        }

        return .eligible(DockEdgeRelocationGeometry(
            displayID: displayID,
            orientation: orientation,
            segment: selected.segment,
            approachPoint: approach,
            targetPoint: target
        ))
    }

    private static func strictInteriorCoordinate(
        of interval: DockEdgeInterval
    ) -> CGFloat? {
        guard interval.end > interval.start else { return nil }
        let midpoint = interval.start + interval.length / 2
        if midpoint > interval.start && midpoint < interval.end {
            return midpoint
        }
        let next = interval.start.nextUp
        if next < interval.end { return next }
        let previous = interval.end.nextDown
        if previous > interval.start { return previous }
        return nil
    }

    private static func inwardCoordinate(
        frame: CGRect,
        orientation: DockPosition,
        distance requestedDistance: CGFloat
    ) -> CGFloat {
        let length: CGFloat
        let outwardEdge: CGFloat
        let inwardSign: CGFloat
        switch orientation {
        case .bottom:
            length = frame.height
            outwardEdge = frame.maxY
            inwardSign = -1
        case .left:
            length = frame.width
            outwardEdge = frame.minX
            inwardSign = 1
        case .right:
            length = frame.width
            outwardEdge = frame.maxX
            inwardSign = -1
        }

        // Half the display depth is always strictly inward for a valid frame.
        let fallbackDistance = length / 2
        let positiveDistance = requestedDistance > 0
            ? requestedDistance
            : fallbackDistance
        let distance = min(positiveDistance, fallbackDistance)
        return outwardEdge + inwardSign * distance
    }
}

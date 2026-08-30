import Foundation
import CoreGraphics

/// The small, immutable value used by the event-tap hot path. Trigger zones
/// are built when display/anchor state changes rather than for every event.
struct EventTapTriggerZone: Equatable {
    let displayID: UInt64
    let displayName: String
    let bounds: CGRect
}

enum EventTapInputType: Equatable {
    case mouseMoved
    case other
}

enum EventTapClassificationDecision: Equatable {
    case passThrough
    case suppressPhysicalDuringRelocation
    case suppressBlockedMovement(EventTapTriggerZone)
}

struct EventTapClassificationResult: Equatable {
    let decision: EventTapClassificationDecision
    let zoneExaminations: Int
}

/// A classifier snapshot contains only zones that are applicable to blocking.
/// In particular, the anchor zone is removed once while constructing the
/// snapshot, so anchor ordering can never add a nested lookup to the hot path.
struct EventTapClassifierSnapshot {
    let applicableTriggerZones: [EventTapTriggerZone]
    let isRelocating: Bool
    let syntheticEventMarker: Int64

    init(
        triggerZones: [EventTapTriggerZone],
        anchorDisplayID: UInt64?,
        isRelocating: Bool,
        syntheticEventMarker: Int64
    ) {
        if let anchorDisplayID {
            applicableTriggerZones = triggerZones.filter {
                $0.displayID != anchorDisplayID
            }
        } else {
            applicableTriggerZones = triggerZones
        }
        self.isRelocating = isRelocating
        self.syntheticEventMarker = syntheticEventMarker
    }

    private init(
        applicableTriggerZones: [EventTapTriggerZone],
        isRelocating: Bool,
        syntheticEventMarker: Int64
    ) {
        self.applicableTriggerZones = applicableTriggerZones
        self.isRelocating = isRelocating
        self.syntheticEventMarker = syntheticEventMarker
    }

    func replacingRelocationState(_ isRelocating: Bool) -> EventTapClassifierSnapshot {
        EventTapClassifierSnapshot(
            applicableTriggerZones: applicableTriggerZones,
            isRelocating: isRelocating,
            syntheticEventMarker: syntheticEventMarker
        )
    }

    /// This is the production decision function. Tests may supply an observer
    /// to prove which zones were examined; production passes nil and allocates
    /// no instrumentation state.
    @inline(__always)
    func classify(
        inputType: EventTapInputType,
        location: CGPoint,
        eventSourceUserData: Int64,
        onZoneExamined: ((UInt64) -> Void)? = nil
    ) -> EventTapClassificationResult {
        guard inputType == .mouseMoved else {
            return EventTapClassificationResult(
                decision: .passThrough,
                zoneExaminations: 0
            )
        }

        if isRelocating {
            let decision: EventTapClassificationDecision =
                eventSourceUserData == syntheticEventMarker
                ? .passThrough
                : .suppressPhysicalDuringRelocation
            return EventTapClassificationResult(
                decision: decision,
                zoneExaminations: 0
            )
        }

        var examinationCount = 0
        for zone in applicableTriggerZones {
            examinationCount += 1
            onZoneExamined?(zone.displayID)
            if zone.bounds.contains(location) {
                return EventTapClassificationResult(
                    decision: .suppressBlockedMovement(zone),
                    zoneExaminations: examinationCount
                )
            }
        }

        return EventTapClassificationResult(
            decision: .passThrough,
            zoneExaminations: examinationCount
        )
    }
}

/// Serializes complete classifier snapshots. Event callbacks copy one immutable
/// value while holding the lock, then classify without holding it. Configuration
/// and relocation updates cannot expose partially updated display/anchor state.
final class EventTapClassifierStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: EventTapClassifierSnapshot

    init(syntheticEventMarker: Int64) {
        snapshot = EventTapClassifierSnapshot(
            triggerZones: [],
            anchorDisplayID: nil,
            isRelocating: false,
            syntheticEventMarker: syntheticEventMarker
        )
    }

    func updateConfiguration(
        triggerZones: [EventTapTriggerZone],
        anchorDisplayID: UInt64?
    ) {
        lock.lock()
        snapshot = EventTapClassifierSnapshot(
            triggerZones: triggerZones,
            anchorDisplayID: anchorDisplayID,
            isRelocating: snapshot.isRelocating,
            syntheticEventMarker: snapshot.syntheticEventMarker
        )
        lock.unlock()
    }

    func setRelocating(_ isRelocating: Bool) {
        lock.lock()
        snapshot = snapshot.replacingRelocationState(isRelocating)
        lock.unlock()
    }

    @inline(__always)
    func classify(
        inputType: EventTapInputType,
        location: CGPoint,
        eventSourceUserData: Int64,
        onZoneExamined: ((UInt64) -> Void)? = nil
    ) -> EventTapClassificationResult {
        lock.lock()
        let current = snapshot
        lock.unlock()
        return current.classify(
            inputType: inputType,
            location: location,
            eventSourceUserData: eventSourceUserData,
            onZoneExamined: onZoneExamined
        )
    }
}

struct StatusMessageRevision: Equatable {
    fileprivate let value: UInt64
}

/// Gives every status publication a monotonic revision. Delayed work may update
/// the status only while the revision it was created for is still current.
final class StatusMessageCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: (String) -> Void
    private var revisionValue: UInt64 = 0
    private var message: String

    init(initialMessage: String, sink: @escaping (String) -> Void) {
        message = initialMessage
        self.sink = sink
    }

    var currentRevision: StatusMessageRevision {
        lock.lock()
        let revision = StatusMessageRevision(value: revisionValue)
        lock.unlock()
        return revision
    }

    var currentMessage: String {
        lock.lock()
        let current = message
        lock.unlock()
        return current
    }

    @discardableResult
    func publish(_ newMessage: String) -> StatusMessageRevision {
        lock.lock()
        revisionValue &+= 1
        let revision = StatusMessageRevision(value: revisionValue)
        message = newMessage
        lock.unlock()
        sink(newMessage)
        return revision
    }

    /// Returns the new revision when the conditional publication succeeds.
    /// A nil result means a newer status already superseded this work.
    @discardableResult
    func publish(
        _ newMessage: String,
        ifCurrent expectedRevision: StatusMessageRevision
    ) -> StatusMessageRevision? {
        lock.lock()
        guard revisionValue == expectedRevision.value else {
            lock.unlock()
            return nil
        }
        revisionValue &+= 1
        let revision = StatusMessageRevision(value: revisionValue)
        message = newMessage
        lock.unlock()
        sink(newMessage)
        return revision
    }
}

protocol EventFeedbackScheduledAction: AnyObject {
    func cancel()
}

protocol EventFeedbackScheduler: AnyObject {
    var now: TimeInterval { get }

    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> EventFeedbackScheduledAction
}

private final class DispatchEventFeedbackScheduledAction: EventFeedbackScheduledAction {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

final class DispatchEventFeedbackScheduler: EventFeedbackScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> EventFeedbackScheduledAction {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: workItem
        )
        return DispatchEventFeedbackScheduledAction(workItem: workItem)
    }
}

struct BlockedEventFeedbackDiagnostics: Equatable {
    let schedulerRegistrations: Int
    let blockedStatusPublications: Int
    let statusResets: Int
    let pendingResetActions: Int
    let pendingPublicationActions: Int
    let maximumPendingActions: Int
}

/// Coalesces a blocked-event burst into bounded status work. One reset wake-up
/// follows the moving deadline instead of canceling and enqueuing one delayed
/// closure for every event. A long continuous burst therefore registers at
/// most roughly one wake-up per reset interval, independent of event rate.
final class BlockedEventFeedbackController: @unchecked Sendable {
    struct Configuration {
        var resetDelay: TimeInterval = 2.0
        var minimumZoneUpdateInterval: TimeInterval = 0.1
    }

    private struct Target: Equatable {
        let displayID: UInt64
        let displayName: String
    }

    private let lock = NSLock()
    private let scheduler: EventFeedbackScheduler
    private let statusMessages: StatusMessageCoordinator
    private let defaultMessage: () -> String
    private let configuration: Configuration

    private var burstGeneration: UInt64 = 0
    private var desiredTargetVersion: UInt64 = 0
    private var publicationGeneration: UInt64 = 0
    private var resetGeneration: UInt64 = 0

    private var isBurstActive = false
    private var desiredTarget: Target?
    private var lastPublishedTarget: Target?
    private var lastBlockedTime: TimeInterval = 0
    private var lastPublicationTime: TimeInterval?
    private var feedbackStatusRevision: StatusMessageRevision?
    private var initialExpectedRevision: StatusMessageRevision?
    private var feedbackWasSuperseded = false

    private var publicationPending = false
    private var resetPending = false
    private var publicationAction: EventFeedbackScheduledAction?
    private var resetAction: EventFeedbackScheduledAction?

    private var schedulerRegistrationCount = 0
    private var blockedPublicationCount = 0
    private var statusResetCount = 0
    private var maximumPendingActionCount = 0

    init(
        scheduler: EventFeedbackScheduler,
        statusMessages: StatusMessageCoordinator,
        configuration: Configuration = Configuration(),
        defaultMessage: @escaping () -> String
    ) {
        self.scheduler = scheduler
        self.statusMessages = statusMessages
        self.configuration = configuration
        self.defaultMessage = defaultMessage
    }

    func recordBlocked(displayID: UInt64, displayName: String) {
        let now = scheduler.now
        let target = Target(displayID: displayID, displayName: displayName)
        var publicationRequest: (generation: UInt64, delay: TimeInterval)?
        var resetRequest: (generation: UInt64, delay: TimeInterval)?

        lock.lock()
        lastBlockedTime = now

        if !isBurstActive {
            isBurstActive = true
            burstGeneration &+= 1
            desiredTarget = target
            desiredTargetVersion &+= 1
            lastPublishedTarget = nil
            lastPublicationTime = nil
            feedbackStatusRevision = nil
            initialExpectedRevision = statusMessages.currentRevision
            feedbackWasSuperseded = false
        } else if desiredTarget != target {
            desiredTarget = target
            desiredTargetVersion &+= 1
        }

        if !publicationPending,
           !feedbackWasSuperseded,
           desiredTarget != lastPublishedTarget {
            let earliest = (lastPublicationTime ?? now)
                + (lastPublicationTime == nil
                    ? 0
                    : configuration.minimumZoneUpdateInterval)
            publicationRequest = markPublicationPendingLocked(
                delay: max(0, earliest - now)
            )
        }

        if !resetPending {
            resetRequest = markResetPendingLocked(delay: configuration.resetDelay)
        }
        lock.unlock()

        if let request = publicationRequest {
            registerPublication(request)
        }
        if let request = resetRequest {
            registerReset(request)
        }
    }

    func cancelPendingFeedback() {
        lock.lock()
        burstGeneration &+= 1
        isBurstActive = false
        desiredTarget = nil
        lastPublishedTarget = nil
        feedbackStatusRevision = nil
        initialExpectedRevision = nil
        feedbackWasSuperseded = false

        let publicationToCancel = publicationAction
        let resetToCancel = resetAction
        publicationAction = nil
        resetAction = nil
        publicationPending = false
        resetPending = false
        lock.unlock()

        publicationToCancel?.cancel()
        resetToCancel?.cancel()
    }

    var diagnostics: BlockedEventFeedbackDiagnostics {
        lock.lock()
        let result = BlockedEventFeedbackDiagnostics(
            schedulerRegistrations: schedulerRegistrationCount,
            blockedStatusPublications: blockedPublicationCount,
            statusResets: statusResetCount,
            pendingResetActions: resetPending ? 1 : 0,
            pendingPublicationActions: publicationPending ? 1 : 0,
            maximumPendingActions: maximumPendingActionCount
        )
        lock.unlock()
        return result
    }

    private func markPublicationPendingLocked(
        delay: TimeInterval
    ) -> (generation: UInt64, delay: TimeInterval) {
        publicationPending = true
        publicationGeneration &+= 1
        schedulerRegistrationCount += 1
        updateMaximumPendingActionsLocked()
        return (publicationGeneration, delay)
    }

    private func markResetPendingLocked(
        delay: TimeInterval
    ) -> (generation: UInt64, delay: TimeInterval) {
        resetPending = true
        resetGeneration &+= 1
        schedulerRegistrationCount += 1
        updateMaximumPendingActionsLocked()
        return (resetGeneration, max(0, delay))
    }

    private func updateMaximumPendingActionsLocked() {
        let current = (publicationPending ? 1 : 0) + (resetPending ? 1 : 0)
        maximumPendingActionCount = max(maximumPendingActionCount, current)
    }

    private func registerPublication(
        _ request: (generation: UInt64, delay: TimeInterval)
    ) {
        let action = scheduler.schedule(after: request.delay) { [weak self] in
            self?.runPublication(generation: request.generation)
        }

        lock.lock()
        if publicationPending, publicationGeneration == request.generation {
            publicationAction = action
            lock.unlock()
        } else {
            lock.unlock()
            action.cancel()
        }
    }

    private func registerReset(
        _ request: (generation: UInt64, delay: TimeInterval)
    ) {
        let action = scheduler.schedule(after: request.delay) { [weak self] in
            self?.runReset(generation: request.generation)
        }

        lock.lock()
        if resetPending, resetGeneration == request.generation {
            resetAction = action
            lock.unlock()
        } else {
            lock.unlock()
            action.cancel()
        }
    }

    private func runPublication(generation: UInt64) {
        let publicationTime = scheduler.now
        let target: Target
        let targetVersion: UInt64
        let activeGeneration: UInt64
        let expectedRevision: StatusMessageRevision

        lock.lock()
        guard publicationPending,
              publicationGeneration == generation,
              isBurstActive,
              !feedbackWasSuperseded,
              let currentTarget = desiredTarget,
              let expected = feedbackStatusRevision ?? initialExpectedRevision else {
            if publicationGeneration == generation {
                publicationPending = false
                publicationAction = nil
            }
            lock.unlock()
            return
        }
        if currentTarget == lastPublishedTarget {
            publicationPending = false
            publicationAction = nil
            lock.unlock()
            return
        }
        target = currentTarget
        targetVersion = desiredTargetVersion
        activeGeneration = burstGeneration
        expectedRevision = expected
        lock.unlock()

        let newRevision = statusMessages.publish(
            "Blocked dock movement attempt to \(target.displayName)",
            ifCurrent: expectedRevision
        )

        var nextRequest: (generation: UInt64, delay: TimeInterval)?
        lock.lock()
        guard publicationGeneration == generation else {
            lock.unlock()
            return
        }
        publicationPending = false
        publicationAction = nil

        if isBurstActive, burstGeneration == activeGeneration {
            if let newRevision {
                blockedPublicationCount += 1
                feedbackStatusRevision = newRevision
                lastPublishedTarget = target
                lastPublicationTime = publicationTime

                if desiredTargetVersion != targetVersion,
                   desiredTarget != lastPublishedTarget {
                    let earliest = publicationTime
                        + configuration.minimumZoneUpdateInterval
                    nextRequest = markPublicationPendingLocked(
                        delay: max(0, earliest - scheduler.now)
                    )
                }
            } else {
                // A permission, relocation, hot-plug, lifecycle, or other
                // status won the revision race. Feedback from this old burst
                // must not overwrite it later.
                feedbackWasSuperseded = true
            }
        }
        lock.unlock()

        if let request = nextRequest {
            registerPublication(request)
        }
    }

    private func runReset(generation: UInt64) {
        let now = scheduler.now
        var nextRequest: (generation: UInt64, delay: TimeInterval)?
        var revisionToReset: StatusMessageRevision?

        lock.lock()
        guard resetPending, resetGeneration == generation else {
            lock.unlock()
            return
        }
        resetPending = false
        resetAction = nil

        guard isBurstActive else {
            lock.unlock()
            return
        }

        let resetDeadline = lastBlockedTime + configuration.resetDelay
        if now < resetDeadline {
            nextRequest = markResetPendingLocked(delay: resetDeadline - now)
        } else {
            isBurstActive = false
            desiredTarget = nil
            lastPublishedTarget = nil
            initialExpectedRevision = nil
            feedbackWasSuperseded = false
            revisionToReset = feedbackStatusRevision
            feedbackStatusRevision = nil
        }
        lock.unlock()

        if let request = nextRequest {
            registerReset(request)
            return
        }

        if let revision = revisionToReset,
           statusMessages.publish(
                defaultMessage(),
                ifCurrent: revision
           ) != nil {
            lock.lock()
            statusResetCount += 1
            lock.unlock()
        }
    }
}

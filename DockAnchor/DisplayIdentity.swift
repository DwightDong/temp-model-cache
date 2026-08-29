//
//  DisplayIdentity.swift
//  DockAnchor
//
//  Snapshot-level physical display reconciliation.  This file intentionally
//  depends only on Foundation so the identity rules remain independent of
//  CoreGraphics, IOKit, UI ordering, and display layout.
//

import Foundation

struct DisplayHardwareKey: Hashable, Codable, Comparable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32

    static func < (lhs: DisplayHardwareKey, rhs: DisplayHardwareKey) -> Bool {
        if lhs.vendorID != rhs.vendorID { return lhs.vendorID < rhs.vendorID }
        if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
        return lhs.serialNumber < rhs.serialNumber
    }
}

struct DisplayRuntimeObservation: Hashable, Codable {
    let runtimeID: UInt64
    let uuidAlias: String?
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32?
    let isBuiltIn: Bool

    init(
        runtimeID: UInt64,
        uuidAlias: String?,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32?,
        isBuiltIn: Bool = false
    ) {
        self.runtimeID = runtimeID
        self.uuidAlias = uuidAlias
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.isBuiltIn = isBuiltIn
    }
}

/// A record obtained from one metadata source (for example IOKit or
/// system_profiler). Records are one-to-one within a source. Different sources
/// may each describe the same runtime display.
struct DisplayMetadataObservation: Hashable, Codable {
    let source: String
    let sourceID: String
    let uuidAlias: String?
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32?
    let name: String?
    let isBuiltIn: Bool?
    let presentationPriority: Int

    init(
        source: String,
        sourceID: String,
        uuidAlias: String? = nil,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32? = nil,
        name: String? = nil,
        isBuiltIn: Bool? = nil,
        presentationPriority: Int = 0
    ) {
        self.source = source
        self.sourceID = sourceID
        self.uuidAlias = uuidAlias
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.presentationPriority = presentationPriority
    }
}

struct DisplayIdentityRecord: Hashable, Codable {
    var canonicalID: String
    var vendorID: UInt32
    var productID: UInt32
    var serialNumber: UInt32?
    var uuidAliases: Set<String>
    var legacyReferences: Set<String>

    init(
        canonicalID: String,
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32? = nil,
        uuidAliases: Set<String> = [],
        legacyReferences: Set<String> = []
    ) {
        self.canonicalID = canonicalID
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber.flatMap { $0 == 0 ? nil : $0 }
        self.uuidAliases = Set(uuidAliases.compactMap(DisplayReference.normalizedUUIDAlias))
        self.legacyReferences = Set(legacyReferences.filter(DisplayReference.canPersistAsLegacyReference))
    }

    var hardwareKey: DisplayHardwareKey? {
        guard let serialNumber, serialNumber != 0 else { return nil }
        return DisplayHardwareKey(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    private enum CodingKeys: String, CodingKey {
        case canonicalID, vendorID, productID, serialNumber, uuidAliases, legacyReferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalID = try container.decode(String.self, forKey: .canonicalID)
        vendorID = try container.decode(UInt32.self, forKey: .vendorID)
        productID = try container.decode(UInt32.self, forKey: .productID)
        serialNumber = try container.decodeIfPresent(UInt32.self, forKey: .serialNumber)
            .flatMap { $0 == 0 ? nil : $0 }
        uuidAliases = Set(
            (try container.decodeIfPresent([String].self, forKey: .uuidAliases) ?? [])
                .compactMap(DisplayReference.normalizedUUIDAlias)
        )
        legacyReferences = Set(
            (try container.decodeIfPresent([String].self, forKey: .legacyReferences) ?? [])
                .filter(DisplayReference.canPersistAsLegacyReference)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(canonicalID, forKey: .canonicalID)
        try container.encode(vendorID, forKey: .vendorID)
        try container.encode(productID, forKey: .productID)
        try container.encodeIfPresent(serialNumber, forKey: .serialNumber)
        try container.encode(uuidAliases.sorted(), forKey: .uuidAliases)
        try container.encode(legacyReferences.sorted(), forKey: .legacyReferences)
    }
}

struct DisplayIdentityRegistry: Equatable, Codable {
    var records: [DisplayIdentityRecord]

    init(records: [DisplayIdentityRecord] = []) {
        var seen = Set<String>()
        self.records = records
            .compactMap { record in
                var normalized = record
                normalized.serialNumber = normalized.serialNumber.flatMap { $0 == 0 ? nil : $0 }
                normalized.uuidAliases = Set(
                    normalized.uuidAliases.compactMap(DisplayReference.normalizedUUIDAlias)
                )
                normalized.legacyReferences = Set(
                    normalized.legacyReferences.filter(DisplayReference.canPersistAsLegacyReference)
                )

                // Remove identity records generated by the buggy path which
                // embedded a runtime fallback where a UUID should have been.
                // A scoped serial can safely repair such a record; without one
                // there is no persistent evidence and the record must be dropped.
                if DisplayReference.isRuntimeDerivedCanonicalID(normalized.canonicalID) {
                    guard let serial = normalized.serialNumber,
                          serial != 0,
                          normalized.vendorID != 0 || normalized.productID != 0 else {
                        return nil
                    }
                    normalized.canonicalID = "DockAnchorDisplay-V\(normalized.vendorID)M\(normalized.productID)-SN\(serial)"
                }

                // Canonical IDs are internal data, not an open-ended namespace.
                // Discard records emitted by buggy development builds rather
                // than allowing an arbitrary `DockAnchorDisplay-*` value to
                // become identity evidence through an exact string match.
                guard DisplayReference.isValidCanonicalID(normalized.canonicalID) else {
                    return nil
                }
                return normalized
            }
            .sorted { lhs, rhs in
                if lhs.canonicalID != rhs.canonicalID { return lhs.canonicalID < rhs.canonicalID }
                if lhs.vendorID != rhs.vendorID { return lhs.vendorID < rhs.vendorID }
                if lhs.productID != rhs.productID { return lhs.productID < rhs.productID }
                return (lhs.serialNumber ?? 0) < (rhs.serialNumber ?? 0)
            }
            .filter { seen.insert($0.canonicalID).inserted }
    }

    func recordingLegacyReferences(_ migrations: [String: String]) -> DisplayIdentityRegistry {
        guard !migrations.isEmpty else { return self }
        var updated = records
        for (oldReference, canonicalID) in migrations {
            guard let index = updated.firstIndex(where: { $0.canonicalID == canonicalID }) else { continue }
            let parsed = DisplayReference.parse(oldReference)
            // A runtime ID is proof only in the snapshot where migration took
            // place. Persisting it as an alias would incorrectly resurrect that
            // association after the operating system reuses the ID.
            guard DisplayReference.canPersistAsLegacyReference(oldReference) else { continue }
            updated[index].legacyReferences.insert(oldReference)
            if let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) {
                updated[index].uuidAliases.insert(alias)
            }
        }
        return DisplayIdentityRegistry(records: updated)
    }

    private enum CodingKeys: String, CodingKey { case records }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(records: try container.decode([DisplayIdentityRecord].self, forKey: .records))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records, forKey: .records)
    }
}

enum DisplayPhysicalResolution: String, Codable, Hashable {
    case unique
    case ambiguous
}

struct ReconciledDisplay {
    let runtime: DisplayRuntimeObservation
    let identity: DisplayIdentityRecord?
    let resolution: DisplayPhysicalResolution
    let metadataAssignments: [String: String]
    let friendlyName: String?
    let isBuiltIn: Bool
    let ambiguityCandidateRuntimeIDs: Set<UInt64>

    var persistentReference: String? {
        guard resolution == .unique else { return nil }
        return identity?.canonicalID
    }
}

enum DisplayReferenceResolution: Equatable {
    case resolved(runtimeID: UInt64, canonicalReference: String)
    case unavailable
    case ambiguous(candidateRuntimeIDs: Set<UInt64>)
    case unresolved

    var isUniquelyResolved: Bool {
        if case .resolved = self { return true }
        return false
    }
}

private struct IdentityAvailability {
    var runtimeIDs: Set<UInt64>
    var canBeUnavailable: Bool
}

/// Raw serial observations retained only to classify legacy `UUID-SN*`
/// references. Invalid evidence never creates an identity, but it must remain
/// visible as ambiguity instead of being mistaken for a disconnected display.
private struct SerialReferenceEvidence {
    var hardwareScopes: Set<DisplayHardwareKey>
    var candidateRuntimeIDs: Set<UInt64>
    var containsInvalidEvidence: Bool
}

struct DisplayReconciliationSnapshot {
    let displays: [ReconciledDisplay]
    let registry: DisplayIdentityRegistry

    private let availabilityByCanonicalID: [String: IdentityAvailability]
    private let serialReferenceEvidence: [UInt32: SerialReferenceEvidence]

    fileprivate init(
        displays: [ReconciledDisplay],
        registry: DisplayIdentityRegistry,
        availabilityByCanonicalID: [String: IdentityAvailability],
        serialReferenceEvidence: [UInt32: SerialReferenceEvidence]
    ) {
        self.displays = displays.sorted { $0.runtime.runtimeID < $1.runtime.runtimeID }
        self.registry = registry
        self.availabilityByCanonicalID = availabilityByCanonicalID
        self.serialReferenceEvidence = serialReferenceEvidence
    }

    static let empty = DisplayReconciliationSnapshot(
        displays: [],
        registry: DisplayIdentityRegistry(),
        availabilityByCanonicalID: [:],
        serialReferenceEvidence: [:]
    )

    func withRegistry(_ registry: DisplayIdentityRegistry) -> DisplayReconciliationSnapshot {
        DisplayReconciliationSnapshot(
            displays: displays,
            registry: registry,
            availabilityByCanonicalID: availabilityByCanonicalID,
            serialReferenceEvidence: serialReferenceEvidence
        )
    }

    func display(runtimeID: UInt64) -> ReconciledDisplay? {
        displays.first { $0.runtime.runtimeID == runtimeID }
    }

    func resolve(
        _ rawReference: String,
        excludingInferredReferences: Set<String> = []
    ) -> DisplayReferenceResolution {
        let parsed = DisplayReference.parse(rawReference)

        // Unknown and malformed input is never identity evidence, even if an
        // earlier application version accidentally stored a normalized variant
        // in the alias registry.
        guard parsed.kind != .malformed else { return .unresolved }

        // An explicit choice made while identity was ambiguous is a selector for
        // that snapshot, not a newly discovered UUID alias. Keep that provenance
        // across refreshes so one-to-one model elimination after a port/topology
        // change cannot silently promote the choice to a physical identity.
        if excludingInferredReferences.contains(rawReference) {
            return quarantinedResolution(for: parsed)
        }

        // A canonical reference can use exact registry context immediately.
        // Serial legacy references deliberately skip exact alias history: their
        // old UUID prefix is port-derived and cannot scope a decimal serial that
        // is known in more than one vendor/product namespace.
        let exactRecords = registry.records.filter { record in
            record.canonicalID == rawReference ||
                (parsed.kind != .serial && parsed.kind != .vendorModel &&
                    record.legacyReferences.contains(rawReference))
        }
        if !exactRecords.isEmpty {
            return resolution(for: exactRecords)
        }

        // Only a syntactically valid bare UUID may resolve directly through an
        // alias. Serial evidence is evaluated in its own branch so a stale
        // UUID prefix can never outrank the serial encoded in that reference.
        if parsed.kind == .bareUUID,
           let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) {
            let aliasRecords = registry.records.filter { $0.uuidAliases.contains(alias) }
            if !aliasRecords.isEmpty {
                return resolution(for: aliasRecords)
            }
        }

        switch parsed.kind {
        case .canonical:
            return .unavailable

        case .serial:
            guard let serial = parsed.serialNumber else { return .unresolved }
            let records = registry.records.filter { $0.serialNumber == serial }
            let evidence = serialReferenceEvidence[serial]
            var hardwareScopes = Set(records.compactMap(\.hardwareKey))
            hardwareScopes.formUnion(evidence?.hardwareScopes ?? [])

            var candidateRuntimeIDs = evidence?.candidateRuntimeIDs ?? []
            for record in records {
                candidateRuntimeIDs.formUnion(
                    availabilityByCanonicalID[record.canonicalID]?.runtimeIDs ?? []
                )
            }

            // The legacy syntax stores only the decimal serial. Its UUID prefix
            // is a movable port alias, so it cannot choose between equal serials
            // from different vendor/product scopes. Duplicate or conflicting
            // raw observations are likewise ambiguity, even when they came only
            // from metadata and created no stable registry record.
            if hardwareScopes.count > 1 || evidence?.containsInvalidEvidence == true {
                return .ambiguous(candidateRuntimeIDs: candidateRuntimeIDs)
            }

            if !records.isEmpty {
                return resolution(for: records)
            }

            let current = displays.filter {
                $0.resolution == .unique && $0.identity?.serialNumber == serial
            }
            if !current.isEmpty {
                return resolution(forCurrentDisplays: current, absentIsUnavailable: true)
            }

            if evidence != nil {
                return .ambiguous(candidateRuntimeIDs: candidateRuntimeIDs)
            }
            return .unavailable

        case .vendorModel:
            guard let vendorID = parsed.vendorID, let productID = parsed.productID else {
                return .unresolved
            }
            // The UUID prefix of this weak legacy form is deliberately not a
            // tie-breaker. Vendor/model migration is safe only when the whole
            // current snapshot has one candidate.
            let candidates = displays.filter {
                $0.runtime.vendorID == vendorID && $0.runtime.productID == productID
            }
            guard !candidates.isEmpty else { return .unavailable }
            guard candidates.count == 1,
                  candidates[0].resolution == .unique,
                  let identity = candidates[0].identity else {
                return .ambiguous(candidateRuntimeIDs: Set(candidates.map { $0.runtime.runtimeID }))
            }
            return .resolved(
                runtimeID: candidates[0].runtime.runtimeID,
                canonicalReference: identity.canonicalID
            )

        case .runtime:
            guard let runtimeID = parsed.runtimeID else { return .unresolved }
            guard let display = display(runtimeID: runtimeID) else { return .unavailable }
            guard display.resolution == .unique, let identity = display.identity else {
                return .ambiguous(candidateRuntimeIDs: display.ambiguityCandidateRuntimeIDs)
            }
            return .resolved(runtimeID: runtimeID, canonicalReference: identity.canonicalID)

        case .bareUUID:
            guard let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) else {
                return .unresolved
            }
            let candidates = displays.filter {
                $0.runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) == alias
            }
            guard !candidates.isEmpty else { return .unavailable }
            guard candidates.count == 1,
                  candidates[0].resolution == .unique,
                  let identity = candidates[0].identity else {
                let ambiguousIDs = candidates.reduce(into: Set<UInt64>()) {
                    $0.formUnion($1.ambiguityCandidateRuntimeIDs)
                }
                return .ambiguous(candidateRuntimeIDs: ambiguousIDs)
            }
            return .resolved(
                runtimeID: candidates[0].runtime.runtimeID,
                canonicalReference: identity.canonicalID
            )

        case .malformed:
            return .unresolved
        }
    }

    /// Resolves only a current-snapshot selector. This is deliberately separate
    /// from persistent identity resolution: it permits an explicit click on an
    /// ambiguous display without teaching the registry that a UUID or runtime
    /// ID identifies that physical monitor.
    func explicitRuntimeID(for rawReference: String) -> UInt64? {
        let parsed = DisplayReference.parse(rawReference)
        switch parsed.kind {
        case .runtime:
            guard let runtimeID = parsed.runtimeID, display(runtimeID: runtimeID) != nil else {
                return nil
            }
            return runtimeID
        case .bareUUID:
            guard let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) else {
                return nil
            }
            let candidates = displays.filter {
                $0.runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) == alias
            }
            return candidates.count == 1 ? candidates[0].runtime.runtimeID : nil
        default:
            return nil
        }
    }

    private func quarantinedResolution(
        for parsed: DisplayReference
    ) -> DisplayReferenceResolution {
        switch parsed.kind {
        case .bareUUID:
            guard let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) else {
                return .unresolved
            }
            let candidates = displays.filter {
                $0.runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) == alias
            }
            guard !candidates.isEmpty else { return .unavailable }
            let ids = candidates.reduce(into: Set<UInt64>()) {
                $0.formUnion($1.ambiguityCandidateRuntimeIDs)
            }
            return .ambiguous(candidateRuntimeIDs: ids)

        case .runtime:
            guard let runtimeID = parsed.runtimeID,
                  let display = display(runtimeID: runtimeID) else {
                return .unavailable
            }
            return .ambiguous(candidateRuntimeIDs: display.ambiguityCandidateRuntimeIDs)

        // Ambiguous display rows expose only a current UUID or runtime selector.
        // Refuse inference for any other accidentally quarantined shape as well.
        case .canonical, .serial, .vendorModel:
            return .ambiguous(candidateRuntimeIDs: [])
        case .malformed:
            return .unresolved
        }
    }

    private func resolution(for records: [DisplayIdentityRecord]) -> DisplayReferenceResolution {
        var runtimeIDs = Set<UInt64>()
        var canBeUnavailable = false
        for record in records {
            if let availability = availabilityByCanonicalID[record.canonicalID] {
                runtimeIDs.formUnion(availability.runtimeIDs)
                canBeUnavailable = canBeUnavailable || availability.canBeUnavailable
            } else {
                canBeUnavailable = true
            }
        }

        if runtimeIDs.isEmpty { return .unavailable }
        if runtimeIDs.count != 1 || canBeUnavailable {
            return .ambiguous(candidateRuntimeIDs: runtimeIDs)
        }
        guard let runtimeID = runtimeIDs.first,
              let current = display(runtimeID: runtimeID),
              current.resolution == .unique,
              let identity = current.identity else {
            return .ambiguous(candidateRuntimeIDs: runtimeIDs)
        }
        return .resolved(runtimeID: runtimeID, canonicalReference: identity.canonicalID)
    }

    private func resolution(
        forCurrentDisplays current: [ReconciledDisplay],
        absentIsUnavailable: Bool
    ) -> DisplayReferenceResolution {
        guard !current.isEmpty else { return absentIsUnavailable ? .unavailable : .unresolved }
        let ids = Set(current.map { $0.runtime.runtimeID })
        guard current.count == 1, let identity = current[0].identity else {
            return .ambiguous(candidateRuntimeIDs: ids)
        }
        return .resolved(
            runtimeID: current[0].runtime.runtimeID,
            canonicalReference: identity.canonicalID
        )
    }
}

struct DisplayReferenceMigrationResult: Equatable {
    let references: [String]
    let migrations: [String: String]
}

enum DisplayReferenceMigrator {
    static func migrate(
        references: [String],
        using snapshot: DisplayReconciliationSnapshot,
        excludingInferredReferences: Set<String> = []
    ) -> DisplayReferenceMigrationResult {
        var cache: [String: String] = [:]
        for reference in Set(references) {
            if case let .resolved(_, canonicalReference) = snapshot.resolve(
                reference,
                excludingInferredReferences: excludingInferredReferences
            ),
               canonicalReference != reference {
                cache[reference] = canonicalReference
            }
        }
        return DisplayReferenceMigrationResult(
            references: references.map { cache[$0] ?? $0 },
            migrations: cache
        )
    }
}

enum DisplayAnchorSelectionIntent: Equatable {
    /// Reapply the value stored in settings. Ambiguous identity must use the
    /// configured fallback and must not be treated as a user click.
    case persistedPreference
    /// Select a particular current display. The selection can be temporary when
    /// physical identity cannot be established.
    case explicitUserSelection
}

struct DisplayAnchorDecision: Equatable {
    let preferredResolution: DisplayReferenceResolution
    let effectiveRuntimeID: UInt64?
    let usesFallback: Bool
    let isTemporaryExplicitSelection: Bool

    /// Automatic relocation is never inferred from ambiguous identity. An
    /// explicit user may still target that runtime display for this session.
    var permitsAutomaticRelocation: Bool {
        guard effectiveRuntimeID != nil else { return false }
        if case .ambiguous = preferredResolution { return false }
        return true
    }
}

enum DisplayAnchorResolver {
    static func resolve(
        preferredReference: String,
        fallbackRuntimeID: UInt64?,
        snapshot: DisplayReconciliationSnapshot,
        intent: DisplayAnchorSelectionIntent = .persistedPreference,
        excludingInferredReferences: Set<String> = []
    ) -> DisplayAnchorDecision {
        let preferred = snapshot.resolve(
            preferredReference,
            excludingInferredReferences: excludingInferredReferences
        )
        if case let .resolved(runtimeID, _) = preferred {
            return DisplayAnchorDecision(
                preferredResolution: preferred,
                effectiveRuntimeID: runtimeID,
                usesFallback: false,
                isTemporaryExplicitSelection: false
            )
        }

        if intent == .explicitUserSelection,
           let runtimeID = snapshot.explicitRuntimeID(for: preferredReference) {
            return DisplayAnchorDecision(
                preferredResolution: preferred,
                effectiveRuntimeID: runtimeID,
                usesFallback: false,
                isTemporaryExplicitSelection: true
            )
        }

        return DisplayAnchorDecision(
            preferredResolution: preferred,
            effectiveRuntimeID: fallbackRuntimeID,
            usesFallback: true,
            isTemporaryExplicitSelection: false
        )
    }
}

enum DisplayProfileMatcher {
    /// Returns an index only when exactly one enabled reference resolves to the
    /// connected, uniquely reconciled physical display.
    static func uniqueMatch(
        for runtimeID: UInt64,
        references: [String],
        enabled: [Bool],
        snapshot: DisplayReconciliationSnapshot,
        excludingInferredReferences: Set<String> = []
    ) -> Int? {
        guard references.count == enabled.count,
              snapshot.display(runtimeID: runtimeID)?.resolution == .unique else {
            return nil
        }
        let matches = references.indices.filter { index in
            guard enabled[index] else { return false }
            if case let .resolved(resolvedID, _) = snapshot.resolve(
                references[index],
                excludingInferredReferences: excludingInferredReferences
            ) {
                return resolvedID == runtimeID
            }
            return false
        }
        return matches.count == 1 ? matches[0] : nil
    }
}


struct DisplayHotPlugDecision: Equatable {
    let connectedResolution: DisplayPhysicalResolution?
    let preferredReferenceIsAmbiguous: Bool
    let autoActivateProfileIndex: Int?
    let restoresPreferredAnchor: Bool
    let permitsAutomaticRelocation: Bool

    var isAmbiguous: Bool {
        connectedResolution == .ambiguous || preferredReferenceIsAmbiguous
    }
}

enum DisplayHotPlugResolver {
    /// Computes all identity-dependent add-display behavior from the same
    /// snapshot. Callers may then apply the selected profile and side effects;
    /// no profile or relocation is permitted for an ambiguous display.
    static func displayAdded(
        runtimeID: UInt64,
        preferredReference: String,
        profileReferences: [String],
        profileAutoActivation: [Bool],
        currentAnchorIsUnique: Bool,
        autoRelocate: Bool,
        snapshot: DisplayReconciliationSnapshot,
        excludingInferredReferences: Set<String> = []
    ) -> DisplayHotPlugDecision {
        let resolution = snapshot.display(runtimeID: runtimeID)?.resolution
        let preferredResolution = snapshot.resolve(
            preferredReference,
            excludingInferredReferences: excludingInferredReferences
        )
        let preferredIsAmbiguous: Bool
        if case .ambiguous = preferredResolution {
            preferredIsAmbiguous = true
        } else {
            preferredIsAmbiguous = false
        }

        guard resolution == .unique else {
            return DisplayHotPlugDecision(
                connectedResolution: resolution,
                preferredReferenceIsAmbiguous: preferredIsAmbiguous,
                autoActivateProfileIndex: nil,
                restoresPreferredAnchor: false,
                permitsAutomaticRelocation: false
            )
        }

        let profileIndex = DisplayProfileMatcher.uniqueMatch(
            for: runtimeID,
            references: profileReferences,
            enabled: profileAutoActivation,
            snapshot: snapshot,
            excludingInferredReferences: excludingInferredReferences
        )
        let restoresPreferred: Bool
        if case let .resolved(preferredRuntimeID, _) = preferredResolution {
            restoresPreferred = preferredRuntimeID == runtimeID
        } else {
            restoresPreferred = false
        }

        return DisplayHotPlugDecision(
            connectedResolution: resolution,
            preferredReferenceIsAmbiguous: preferredIsAmbiguous,
            autoActivateProfileIndex: profileIndex,
            restoresPreferredAnchor: restoresPreferred,
            permitsAutomaticRelocation: !preferredIsAmbiguous && currentAnchorIsUnique && autoRelocate
        )
    }
}

private enum DisplayReferenceKind: Equatable {
    case canonical
    case serial
    case vendorModel
    case runtime
    case bareUUID
    case malformed
}

private struct DisplayReference {
    let kind: DisplayReferenceKind
    let uuidAlias: String?
    let serialNumber: UInt32?
    let vendorID: UInt32?
    let productID: UInt32?
    let runtimeID: UInt64?

    /// Accept exactly the UUID spelling used by the legacy persistence format.
    /// In particular, trimming or accepting arbitrary non-UUID aliases would
    /// allow malformed values and `DisplayID-*` runtime selectors to become
    /// permanent physical aliases.
    static func normalizedUUIDAlias(_ alias: String) -> String? {
        guard alias.count == 36,
              alias == alias.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: alias),
              uuid.uuidString.caseInsensitiveCompare(alias) == .orderedSame else {
            return nil
        }
        return uuid.uuidString.uppercased()
    }

    static func canPersistAsLegacyReference(_ raw: String) -> Bool {
        switch parse(raw).kind {
        case .canonical:
            return !isRuntimeDerivedCanonicalID(raw)
        case .serial, .vendorModel, .bareUUID:
            return true
        case .runtime, .malformed:
            return false
        }
    }

    static func isValidCanonicalID(_ canonicalID: String) -> Bool {
        parseCanonical(canonicalID) != nil
    }

    static func isRuntimeDerivedCanonicalID(_ canonicalID: String) -> Bool {
        let normalized = canonicalID.uppercased()
        return normalized.hasPrefix("DISPLAYID-") ||
            normalized.contains("DOCKANCHORDISPLAY-UUID-DISPLAYID-")
    }

    static func parse(_ raw: String) -> DisplayReference {
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return malformed
        }

        if raw.hasPrefix("DockAnchorDisplay-") {
            return parseCanonical(raw) ?? malformed
        }

        // DisplayID values were emitted only when CoreGraphics did not provide
        // a UUID. A legacy hardware suffix does not make the base persistent:
        // it can migrate only while that exact runtime ID is in this snapshot.
        if raw.hasPrefix("DisplayID-") {
            let remainder = raw.dropFirst("DisplayID-".count)
            let digits = remainder.prefix { $0.isNumber }
            let suffix = String(remainder.dropFirst(digits.count))
            guard !digits.isEmpty, let runtimeID = UInt64(digits) else { return malformed }

            let suffixIsValid: Bool
            if suffix.isEmpty {
                suffixIsValid = true
            } else if suffix.hasPrefix("-SN") {
                let serialDigits = suffix.dropFirst(3)
                suffixIsValid = decimalUInt32(serialDigits).map { $0 != 0 } ?? false
            } else if suffix.hasPrefix("-V"), let modelMarker = suffix.firstIndex(of: "M") {
                let vendorStart = suffix.index(suffix.startIndex, offsetBy: 2)
                let vendorDigits = suffix[vendorStart..<modelMarker]
                let modelDigits = suffix[suffix.index(after: modelMarker)...]
                if let vendor = decimalUInt32(vendorDigits), let model = decimalUInt32(modelDigits) {
                    suffixIsValid = vendor != 0 || model != 0
                } else {
                    suffixIsValid = false
                }
            } else {
                suffixIsValid = false
            }
            guard suffixIsValid else { return malformed }
            return DisplayReference(
                kind: .runtime,
                uuidAlias: nil,
                serialNumber: nil,
                vendorID: nil,
                productID: nil,
                runtimeID: runtimeID
            )
        }

        if let suffix = raw.range(of: "-SN", options: .backwards),
           suffix.upperBound < raw.endIndex {
            let base = String(raw[..<suffix.lowerBound])
            let digits = raw[suffix.upperBound...]
            if normalizedUUIDAlias(base) != nil,
               let serial = decimalUInt32(digits), serial != 0 {
                return DisplayReference(
                    kind: .serial,
                    uuidAlias: base,
                    serialNumber: serial,
                    vendorID: nil,
                    productID: nil,
                    runtimeID: nil
                )
            }
            return malformed
        }

        if let vendorMarker = raw.range(of: "-V", options: .backwards),
           let modelMarker = raw.range(of: "M", range: vendorMarker.upperBound..<raw.endIndex) {
            let base = String(raw[..<vendorMarker.lowerBound])
            let vendorDigits = raw[vendorMarker.upperBound..<modelMarker.lowerBound]
            let modelDigits = raw[modelMarker.upperBound...]
            if normalizedUUIDAlias(base) != nil,
               let vendor = decimalUInt32(vendorDigits),
               let product = decimalUInt32(modelDigits),
               vendor != 0 || product != 0 {
                return DisplayReference(
                    kind: .vendorModel,
                    uuidAlias: base,
                    serialNumber: nil,
                    vendorID: vendor,
                    productID: product,
                    runtimeID: nil
                )
            }
            return malformed
        }

        if normalizedUUIDAlias(raw) != nil {
            return DisplayReference(
                kind: .bareUUID,
                uuidAlias: raw,
                serialNumber: nil,
                vendorID: nil,
                productID: nil,
                runtimeID: nil
            )
        }

        return malformed
    }

    /// Parses only canonical IDs emitted by `DisplayReconciler`:
    ///
    /// - `DockAnchorDisplay-V<vendor>M<product>-SN<serial>`
    /// - `DockAnchorDisplay-UUID-<uuid>-V<vendor>M<product>`
    /// - `DockAnchorDisplay-V<vendor>M<product>`
    ///
    /// Prefix matching alone is intentionally insufficient. Unknown
    /// canonical-looking settings must remain malformed and unresolved.
    private static func parseCanonical(_ raw: String) -> DisplayReference? {
        let prefix = "DockAnchorDisplay-"
        guard raw.hasPrefix(prefix) else { return nil }
        let body = String(raw.dropFirst(prefix.count))

        if body.hasPrefix("UUID-") {
            let uuidAndModel = String(body.dropFirst("UUID-".count))
            guard uuidAndModel.count > 37 else { return nil }
            let alias = String(uuidAndModel.prefix(36))
            let modelSuffix = String(uuidAndModel.dropFirst(36))
            guard let normalizedAlias = normalizedUUIDAlias(alias),
                  normalizedAlias == alias,
                  modelSuffix.hasPrefix("-"),
                  let model = parseVendorModel(String(modelSuffix.dropFirst())) else {
                return nil
            }
            return DisplayReference(
                kind: .canonical,
                uuidAlias: alias,
                serialNumber: nil,
                vendorID: model.vendor,
                productID: model.product,
                runtimeID: nil
            )
        }

        if let serialMarker = body.range(of: "-SN", options: .backwards) {
            let modelText = String(body[..<serialMarker.lowerBound])
            let serialText = body[serialMarker.upperBound...]
            guard let model = parseVendorModel(modelText),
                  let serial = decimalUInt32(serialText), serial != 0,
                  String(serial) == String(serialText) else {
                return nil
            }
            return DisplayReference(
                kind: .canonical,
                uuidAlias: nil,
                serialNumber: serial,
                vendorID: model.vendor,
                productID: model.product,
                runtimeID: nil
            )
        }

        guard let model = parseVendorModel(body) else { return nil }
        return DisplayReference(
            kind: .canonical,
            uuidAlias: nil,
            serialNumber: nil,
            vendorID: model.vendor,
            productID: model.product,
            runtimeID: nil
        )
    }

    private static func parseVendorModel(
        _ text: String
    ) -> (vendor: UInt32, product: UInt32)? {
        guard text.hasPrefix("V"),
              let modelMarker = text.firstIndex(of: "M") else {
            return nil
        }
        let vendorStart = text.index(after: text.startIndex)
        let vendorText = text[vendorStart..<modelMarker]
        let productText = text[text.index(after: modelMarker)...]
        guard let vendor = decimalUInt32(vendorText),
              let product = decimalUInt32(productText),
              String(vendor) == String(vendorText),
              String(product) == String(productText),
              vendor != 0 || product != 0 else {
            return nil
        }
        return (vendor, product)
    }

    private static func decimalUInt32<S: StringProtocol>(_ text: S) -> UInt32? {
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber }) else { return nil }
        return UInt32(String(text))
    }

    private static let malformed = DisplayReference(
        kind: .malformed,
        uuidAlias: nil,
        serialNumber: nil,
        vendorID: nil,
        productID: nil,
        runtimeID: nil
    )
}

private struct MatchEdge: Hashable {
    let left: Int
    let right: Int
    let strength: Int
}

private struct MatchingPossibilities {
    let possibleRightsByLeft: [Set<Int>]
    let nilPossibleByLeft: [Bool]
    let possibleLeftsByRight: [Set<Int>]
    let rightCanBeUnused: [Bool]
}

private enum MaximumWeightMatcher {
    static func possibilities(
        leftCount: Int,
        rightCount: Int,
        edges: [MatchEdge]
    ) -> MatchingPossibilities {
        guard leftCount > 0 else {
            return MatchingPossibilities(
                possibleRightsByLeft: [],
                nilPossibleByLeft: [],
                possibleLeftsByRight: Array(repeating: [], count: rightCount),
                rightCanBeUnused: Array(repeating: true, count: rightCount)
            )
        }

        let normalizedEdges = edges.sorted {
            if $0.left != $1.left { return $0.left < $1.left }
            if $0.right != $1.right { return $0.right < $1.right }
            return $0.strength > $1.strength
        }
        let scale = max(leftCount, rightCount) + 1
        func weight(_ strength: Int) -> Int {
            switch strength {
            case 3: return scale * scale
            case 2: return scale
            default: return 1
            }
        }

        let weighted = normalizedEdges.map {
            MatchEdge(left: $0.left, right: $0.right, strength: weight($0.strength))
        }
        let global = maximumWeight(
            leftCount: leftCount,
            rightCount: rightCount,
            edges: weighted,
            excludedLeft: nil,
            excludedRight: nil
        )

        var rights = Array(repeating: Set<Int>(), count: leftCount)
        var nilPossible = Array(repeating: false, count: leftCount)
        var lefts = Array(repeating: Set<Int>(), count: rightCount)
        var rightUnused = Array(repeating: false, count: rightCount)

        for left in 0..<leftCount {
            nilPossible[left] = maximumWeight(
                leftCount: leftCount,
                rightCount: rightCount,
                edges: weighted,
                excludedLeft: left,
                excludedRight: nil
            ) == global
        }

        for right in 0..<rightCount {
            rightUnused[right] = maximumWeight(
                leftCount: leftCount,
                rightCount: rightCount,
                edges: weighted,
                excludedLeft: nil,
                excludedRight: right
            ) == global
        }

        for edge in weighted {
            let remainder = maximumWeight(
                leftCount: leftCount,
                rightCount: rightCount,
                edges: weighted,
                excludedLeft: edge.left,
                excludedRight: edge.right
            )
            if edge.strength + remainder == global {
                rights[edge.left].insert(edge.right)
                lefts[edge.right].insert(edge.left)
            }
        }

        return MatchingPossibilities(
            possibleRightsByLeft: rights,
            nilPossibleByLeft: nilPossible,
            possibleLeftsByRight: lefts,
            rightCanBeUnused: rightUnused
        )
    }

    /// Min-cost flow with one zero-cost unmatched edge per left vertex. Sending
    /// every left vertex therefore computes a maximum-weight optional matching.
    private static func maximumWeight(
        leftCount: Int,
        rightCount: Int,
        edges: [MatchEdge],
        excludedLeft: Int?,
        excludedRight: Int?
    ) -> Int {
        let source = 0
        let leftOffset = 1
        let rightOffset = leftOffset + leftCount
        let sink = rightOffset + rightCount
        let nodeCount = sink + 1

        struct FlowEdge {
            var to: Int
            var reverse: Int
            var capacity: Int
            var cost: Int
        }

        var graph = Array(repeating: [FlowEdge](), count: nodeCount)
        func addEdge(_ from: Int, _ to: Int, _ capacity: Int, _ cost: Int) {
            let forward = FlowEdge(to: to, reverse: graph[to].count, capacity: capacity, cost: cost)
            let reverse = FlowEdge(to: from, reverse: graph[from].count, capacity: 0, cost: -cost)
            graph[from].append(forward)
            graph[to].append(reverse)
        }

        for left in 0..<leftCount where left != excludedLeft {
            addEdge(source, leftOffset + left, 1, 0)
            addEdge(leftOffset + left, sink, 1, 0)
        }
        for right in 0..<rightCount where right != excludedRight {
            addEdge(rightOffset + right, sink, 1, 0)
        }
        for edge in edges
        where edge.left != excludedLeft && edge.right != excludedRight {
            addEdge(leftOffset + edge.left, rightOffset + edge.right, 1, -edge.strength)
        }

        let requiredFlow = leftCount - (excludedLeft == nil ? 0 : 1)
        var totalCost = 0
        for _ in 0..<requiredFlow {
            let infinity = Int.max / 4
            var distance = Array(repeating: infinity, count: nodeCount)
            var previousNode = Array(repeating: -1, count: nodeCount)
            var previousEdge = Array(repeating: -1, count: nodeCount)
            distance[source] = 0

            // Bellman-Ford is small (at most a few dozen vertices) and handles
            // the negative hardware-evidence edges without ordering assumptions.
            for _ in 0..<nodeCount {
                var changed = false
                for node in 0..<nodeCount where distance[node] != infinity {
                    for edgeIndex in graph[node].indices {
                        let edge = graph[node][edgeIndex]
                        guard edge.capacity > 0 else { continue }
                        let candidate = distance[node] + edge.cost
                        if candidate < distance[edge.to] {
                            distance[edge.to] = candidate
                            previousNode[edge.to] = node
                            previousEdge[edge.to] = edgeIndex
                            changed = true
                        }
                    }
                }
                if !changed { break }
            }

            guard distance[sink] != infinity else { break }
            totalCost += distance[sink]
            var node = sink
            while node != source {
                let from = previousNode[node]
                let edgeIndex = previousEdge[node]
                guard from >= 0, edgeIndex >= 0 else { break }
                let reverseIndex = graph[from][edgeIndex].reverse
                graph[from][edgeIndex].capacity -= 1
                graph[node][reverseIndex].capacity += 1
                node = from
            }
        }
        return -totalCost
    }
}

enum DisplayReconciler {
    static func reconcile(
        runtimes inputRuntimes: [DisplayRuntimeObservation],
        metadata inputMetadata: [DisplayMetadataObservation],
        priorRegistry: DisplayIdentityRegistry = DisplayIdentityRegistry()
    ) -> DisplayReconciliationSnapshot {
        // Strip every non-UUID alias at the source boundary. In particular,
        // `DisplayID-*` is a snapshot selector, never persistent identity
        // evidence. Sorting is only for deterministic storage and iteration;
        // runtime IDs and source IDs never contribute matching evidence.
        let runtimes = inputRuntimes.map { runtime in
            DisplayRuntimeObservation(
                runtimeID: runtime.runtimeID,
                uuidAlias: runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
                vendorID: runtime.vendorID,
                productID: runtime.productID,
                serialNumber: runtime.serialNumber,
                isBuiltIn: runtime.isBuiltIn
            )
        }.sorted { $0.runtimeID < $1.runtimeID }
        let metadata = inputMetadata.map { record in
            DisplayMetadataObservation(
                source: record.source,
                sourceID: record.sourceID,
                uuidAlias: record.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
                vendorID: record.vendorID,
                productID: record.productID,
                serialNumber: record.serialNumber,
                name: record.name,
                isBuiltIn: record.isBuiltIn,
                presentationPriority: record.presentationPriority
            )
        }.sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return metadataSortKey($0) < metadataSortKey($1)
        }
        let prior = DisplayIdentityRegistry(records: priorRegistry.records)

        let invalidSerialKeys = findInvalidSerialKeys(runtimes: runtimes, metadata: metadata)
        let serialEvidence = collectSerialReferenceEvidence(
            runtimes: runtimes,
            metadata: metadata,
            invalidSerialKeys: invalidSerialKeys
        )
        let metadataResult = reconcileMetadata(
            runtimes: runtimes,
            metadata: metadata,
            invalidSerialKeys: invalidSerialKeys
        )

        var effectiveSerials = Array<DisplayHardwareKey?>(repeating: nil, count: runtimes.count)
        for index in runtimes.indices {
            var evidence = Set<DisplayHardwareKey>()
            if let key = serialKey(
                vendorID: runtimes[index].vendorID,
                productID: runtimes[index].productID,
                serialNumber: runtimes[index].serialNumber
            ), !invalidSerialKeys.contains(key) {
                evidence.insert(key)
            }
            for metadataIndex in metadataResult.uniquelyAssignedMetadataByRuntime[index].values {
                let record = metadata[metadataIndex]
                if let key = serialKey(
                    vendorID: record.vendorID,
                    productID: record.productID,
                    serialNumber: record.serialNumber
                ), !invalidSerialKeys.contains(key) {
                    evidence.insert(key)
                }
            }
            if evidence.count == 1 { effectiveSerials[index] = evidence.first }
        }

        // A serial repeated by two effective runtime observations is not a
        // physical identity, even if it happened to arrive through two sources.
        let effectiveCounts = Dictionary(grouping: effectiveSerials.compactMap { $0 }, by: { $0 })
            .mapValues(\.count)
        for index in effectiveSerials.indices {
            if let key = effectiveSerials[index], effectiveCounts[key, default: 0] != 1 {
                effectiveSerials[index] = nil
            }
        }

        let identityEdges = identityMatchEdges(
            runtimes: runtimes,
            effectiveSerials: effectiveSerials,
            metadataAliases: metadataResult.aliasesByRuntime,
            priorRecords: prior.records
        )
        let identityPossibilities = MaximumWeightMatcher.possibilities(
            leftCount: runtimes.count,
            rightCount: prior.records.count,
            edges: identityEdges
        )

        var assignedPriorByRuntime = Array<Int?>(repeating: nil, count: runtimes.count)
        var resolution = Array(repeating: DisplayPhysicalResolution.ambiguous, count: runtimes.count)

        for index in runtimes.indices {
            if effectiveSerials[index] != nil {
                resolution[index] = .unique
                if identityPossibilities.possibleRightsByLeft[index].count == 1,
                   !identityPossibilities.nilPossibleByLeft[index] {
                    assignedPriorByRuntime[index] = identityPossibilities.possibleRightsByLeft[index].first
                }
            } else if identityPossibilities.possibleRightsByLeft[index].count == 1,
                      !identityPossibilities.nilPossibleByLeft[index] {
                resolution[index] = .unique
                assignedPriorByRuntime[index] = identityPossibilities.possibleRightsByLeft[index].first
            }
        }

        // Establish a weak identity only after all one-to-one prior assignments
        // have been considered and exactly one unresolved display remains in a
        // complete vendor/model group.
        var unresolvedGroups: [String: [Int]] = [:]
        for index in runtimes.indices where resolution[index] == .ambiguous {
            let runtime = runtimes[index]
            let key = modelGroupKey(vendorID: runtime.vendorID, productID: runtime.productID)
            unresolvedGroups[key, default: []].append(index)
        }
        for group in unresolvedGroups.values where group.count == 1 {
            let index = group[0]
            if identityPossibilities.possibleRightsByLeft[index].isEmpty,
               runtimes[index].vendorID != 0 || runtimes[index].productID != 0 {
                resolution[index] = .unique
            }
        }

        let registryResult = updateRegistry(
            runtimes: runtimes,
            metadataAliases: metadataResult.aliasesByRuntime,
            effectiveSerials: effectiveSerials,
            prior: prior,
            assignedPriorByRuntime: assignedPriorByRuntime,
            resolution: resolution
        )

        var ambiguityGroups: [String: Set<UInt64>] = [:]
        for index in runtimes.indices where resolution[index] == .ambiguous {
            ambiguityGroups[
                modelGroupKey(vendorID: runtimes[index].vendorID, productID: runtimes[index].productID),
                default: []
            ].insert(runtimes[index].runtimeID)
        }

        var reconciled: [ReconciledDisplay] = []
        for index in runtimes.indices {
            let identity = registryResult.identityByRuntime[index]
            let assignedMetadata = metadataResult.uniquelyAssignedMetadataByRuntime[index]
            let presentationRecords = assignedMetadata.values.map { metadata[$0] }
            let maxPriority = presentationRecords.compactMap { $0.name == nil ? nil : $0.presentationPriority }.max()
            let topNames = Set(presentationRecords.compactMap { record -> String? in
                guard record.presentationPriority == maxPriority else { return nil }
                return record.name
            })
            let friendlyName = topNames.count == 1 ? topNames.first : nil
            let builtInMetadata = presentationRecords.compactMap(\.isBuiltIn)
            let isBuiltIn = runtimes[index].isBuiltIn || (builtInMetadata.count > 0 && builtInMetadata.allSatisfy { $0 })
            let groupKey = modelGroupKey(
                vendorID: runtimes[index].vendorID,
                productID: runtimes[index].productID
            )
            let ambiguityCandidates = resolution[index] == .unique
                ? Set([runtimes[index].runtimeID])
                : ambiguityGroups[groupKey, default: Set([runtimes[index].runtimeID])]

            reconciled.append(ReconciledDisplay(
                runtime: runtimes[index],
                identity: identity,
                resolution: resolution[index],
                metadataAssignments: Dictionary(uniqueKeysWithValues: assignedMetadata.map {
                    ($0.key, metadata[$0.value].sourceID)
                }),
                friendlyName: friendlyName,
                isBuiltIn: isBuiltIn,
                ambiguityCandidateRuntimeIDs: ambiguityCandidates
            ))
        }

        var availability: [String: IdentityAvailability] = [:]
        for recordIndex in prior.records.indices {
            let oldRecord = prior.records[recordIndex]
            let finalCanonical = registryResult.replacementCanonicalIDs[oldRecord.canonicalID] ?? oldRecord.canonicalID
            var value = availability[finalCanonical] ?? IdentityAvailability(runtimeIDs: [], canBeUnavailable: false)
            value.runtimeIDs.formUnion(
                identityPossibilities.possibleLeftsByRight[recordIndex].map { runtimes[$0].runtimeID }
            )
            value.canBeUnavailable = value.canBeUnavailable || identityPossibilities.rightCanBeUnused[recordIndex]
            availability[finalCanonical] = value
        }
        for index in reconciled.indices where reconciled[index].resolution == .unique {
            guard let identity = reconciled[index].identity else { continue }
            availability[identity.canonicalID] = IdentityAvailability(
                runtimeIDs: [reconciled[index].runtime.runtimeID],
                canBeUnavailable: false
            )
        }
        for record in registryResult.registry.records where availability[record.canonicalID] == nil {
            availability[record.canonicalID] = IdentityAvailability(runtimeIDs: [], canBeUnavailable: true)
        }

        return DisplayReconciliationSnapshot(
            displays: reconciled,
            registry: registryResult.registry,
            availabilityByCanonicalID: availability,
            serialReferenceEvidence: serialEvidence
        )
    }

    private struct MetadataResult {
        var uniquelyAssignedMetadataByRuntime: [[String: Int]]
        var aliasesByRuntime: [Set<String>]
    }

    private static func reconcileMetadata(
        runtimes: [DisplayRuntimeObservation],
        metadata: [DisplayMetadataObservation],
        invalidSerialKeys: Set<DisplayHardwareKey>
    ) -> MetadataResult {
        var assignments = Array(repeating: [String: Int](), count: runtimes.count)
        var aliases = runtimes.map { runtime in
            Set(runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias).map { [$0] } ?? [])
        }
        let sourceGroups = Dictionary(grouping: metadata.indices, by: { metadata[$0].source })

        for source in sourceGroups.keys.sorted() {
            let sourceMetadata = sourceGroups[source, default: []].sorted {
                if metadata[$0].sourceID != metadata[$1].sourceID {
                    return metadata[$0].sourceID < metadata[$1].sourceID
                }
                return metadataSortKey(metadata[$0]) < metadataSortKey(metadata[$1])
            }
            var edges: [MatchEdge] = []
            for runtimeIndex in runtimes.indices {
                for localMetadataIndex in sourceMetadata.indices {
                    let metadataIndex = sourceMetadata[localMetadataIndex]
                    if let strength = metadataMatchStrength(
                        runtime: runtimes[runtimeIndex],
                        metadata: metadata[metadataIndex],
                        invalidSerialKeys: invalidSerialKeys
                    ) {
                        edges.append(MatchEdge(
                            left: runtimeIndex,
                            right: localMetadataIndex,
                            strength: strength
                        ))
                    }
                }
            }
            let possibilities = MaximumWeightMatcher.possibilities(
                leftCount: runtimes.count,
                rightCount: sourceMetadata.count,
                edges: edges
            )
            for runtimeIndex in runtimes.indices {
                guard possibilities.possibleRightsByLeft[runtimeIndex].count == 1,
                      !possibilities.nilPossibleByLeft[runtimeIndex],
                      let localIndex = possibilities.possibleRightsByLeft[runtimeIndex].first else {
                    continue
                }
                let metadataIndex = sourceMetadata[localIndex]
                assignments[runtimeIndex][source] = metadataIndex
                if let alias = metadata[metadataIndex].uuidAlias
                    .flatMap(DisplayReference.normalizedUUIDAlias) {
                    aliases[runtimeIndex].insert(alias)
                }
            }
        }
        return MetadataResult(
            uniquelyAssignedMetadataByRuntime: assignments,
            aliasesByRuntime: aliases
        )
    }

    private static func metadataMatchStrength(
        runtime: DisplayRuntimeObservation,
        metadata: DisplayMetadataObservation,
        invalidSerialKeys: Set<DisplayHardwareKey>
    ) -> Int? {
        guard modelsCompatible(
            lhsVendor: runtime.vendorID,
            lhsProduct: runtime.productID,
            rhsVendor: metadata.vendorID,
            rhsProduct: metadata.productID
        ) else { return nil }

        let runtimeSerial = serialKey(
            vendorID: runtime.vendorID,
            productID: runtime.productID,
            serialNumber: runtime.serialNumber
        ).flatMap { invalidSerialKeys.contains($0) ? nil : $0 }
        let metadataSerial = serialKey(
            vendorID: metadata.vendorID,
            productID: metadata.productID,
            serialNumber: metadata.serialNumber
        ).flatMap { invalidSerialKeys.contains($0) ? nil : $0 }

        if let runtimeSerial, let metadataSerial {
            if runtimeSerial == metadataSerial { return 3 }
            // Both sources claim a different strong serial for this candidate.
            // Neither a UUID nor presentation data may override that conflict.
            return nil
        }

        if let runtimeAlias = runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
           let metadataAlias = metadata.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
           runtimeAlias == metadataAlias {
            return 2
        }

        if sameKnownModel(
            lhsVendor: runtime.vendorID,
            lhsProduct: runtime.productID,
            rhsVendor: metadata.vendorID,
            rhsProduct: metadata.productID
        ) {
            return 1
        }
        return nil
    }

    private static func identityMatchEdges(
        runtimes: [DisplayRuntimeObservation],
        effectiveSerials: [DisplayHardwareKey?],
        metadataAliases: [Set<String>],
        priorRecords: [DisplayIdentityRecord]
    ) -> [MatchEdge] {
        var edges: [MatchEdge] = []
        for runtimeIndex in runtimes.indices {
            let runtime = runtimes[runtimeIndex]
            for recordIndex in priorRecords.indices {
                let record = priorRecords[recordIndex]
                guard modelsCompatible(
                    lhsVendor: runtime.vendorID,
                    lhsProduct: runtime.productID,
                    rhsVendor: record.vendorID,
                    rhsProduct: record.productID
                ) else { continue }

                if let currentSerial = effectiveSerials[runtimeIndex],
                   let priorSerial = record.hardwareKey {
                    if currentSerial == priorSerial {
                        edges.append(MatchEdge(left: runtimeIndex, right: recordIndex, strength: 3))
                    }
                    // A strong current serial rules out stale aliases belonging
                    // to a different stable physical identity.
                    continue
                }

                let aliasesOverlap = !metadataAliases[runtimeIndex].isDisjoint(with: record.uuidAliases)
                if aliasesOverlap {
                    edges.append(MatchEdge(left: runtimeIndex, right: recordIndex, strength: 2))
                } else if sameKnownModel(
                    lhsVendor: runtime.vendorID,
                    lhsProduct: runtime.productID,
                    rhsVendor: record.vendorID,
                    rhsProduct: record.productID
                ) {
                    edges.append(MatchEdge(left: runtimeIndex, right: recordIndex, strength: 1))
                }
            }
        }
        return edges
    }

    private struct RegistryUpdateResult {
        let registry: DisplayIdentityRegistry
        let identityByRuntime: [DisplayIdentityRecord?]
        let replacementCanonicalIDs: [String: String]
    }

    private static func updateRegistry(
        runtimes: [DisplayRuntimeObservation],
        metadataAliases: [Set<String>],
        effectiveSerials: [DisplayHardwareKey?],
        prior: DisplayIdentityRegistry,
        assignedPriorByRuntime: [Int?],
        resolution: [DisplayPhysicalResolution]
    ) -> RegistryUpdateResult {
        var records = Dictionary(uniqueKeysWithValues: prior.records.map { ($0.canonicalID, $0) })
        var canonicalByRuntime = Array<String?>(repeating: nil, count: runtimes.count)
        var replacements: [String: String] = [:]

        for index in runtimes.indices where resolution[index] == .unique {
            let runtime = runtimes[index]
            let assignedPrior = assignedPriorByRuntime[index].map { prior.records[$0] }
            let canonicalID: String
            var record: DisplayIdentityRecord

            if let serial = effectiveSerials[index] {
                canonicalID = canonicalSerialID(serial)
                let canonicalRecord = records[canonicalID]
                record = canonicalRecord ?? assignedPrior ?? DisplayIdentityRecord(
                    canonicalID: canonicalID,
                    vendorID: serial.vendorID,
                    productID: serial.productID,
                    serialNumber: serial.serialNumber
                )
                record.vendorID = serial.vendorID
                record.productID = serial.productID
                record.serialNumber = serial.serialNumber

                if let assignedPrior, assignedPrior.canonicalID != canonicalID {
                    record.uuidAliases.formUnion(assignedPrior.uuidAliases)
                    record.legacyReferences.formUnion(assignedPrior.legacyReferences)
                    record.legacyReferences.insert(assignedPrior.canonicalID)
                    records.removeValue(forKey: assignedPrior.canonicalID)
                    replacements[assignedPrior.canonicalID] = canonicalID
                }
                record.canonicalID = canonicalID
            } else if let assignedPrior {
                canonicalID = assignedPrior.canonicalID
                record = assignedPrior
                // Never clear an established serial merely because this
                // snapshot temporarily lacks serial metadata.
            } else {
                canonicalID = canonicalWeakID(runtime: runtime)
                record = records[canonicalID] ?? DisplayIdentityRecord(
                    canonicalID: canonicalID,
                    vendorID: runtime.vendorID,
                    productID: runtime.productID
                )
            }

            records[canonicalID] = record
            canonicalByRuntime[index] = canonicalID
        }

        // Assign every uniquely observed current UUID in one transaction after
        // all physical identities have been reconciled. The one-to-one snapshot
        // result is the authority here: a display resolved by elimination must
        // be able to take its current alias from a stale owner even when its
        // serial is temporarily unavailable. Applying removals before additions
        // also makes a complete port swap independent of runtime iteration order.
        // Ambiguous displays never claim aliases, and an alias observed on more
        // than one current runtime is removed rather than assigned arbitrarily.
        let aliasClaims = metadataAliases.reduce(into: [String: Int]()) { counts, aliases in
            for alias in aliases { counts[alias, default: 0] += 1 }
        }
        var canonicalClaimByAlias: [String: String] = [:]
        for index in runtimes.indices where resolution[index] == .unique {
            guard let canonicalID = canonicalByRuntime[index] else { continue }
            for alias in metadataAliases[index] where aliasClaims[alias] == 1 {
                canonicalClaimByAlias[alias] = canonicalID
            }
        }

        let multiplyClaimedAliases = Set(aliasClaims.compactMap { alias, count in
            count > 1 ? alias : nil
        })
        let aliasesToRemove = multiplyClaimedAliases.union(canonicalClaimByAlias.keys)
        var bareUUIDHistoryByAlias: [String: Set<String>] = [:]
        for recordID in records.keys.sorted() {
            guard var record = records[recordID] else { continue }
            record.uuidAliases.subtract(aliasesToRemove)

            // Bare UUID migrations duplicate alias ownership in legacy history.
            // Remove stale exact-match entries in the same transaction and carry
            // them to the uniquely reconciled current owner below.
            record.legacyReferences = Set(record.legacyReferences.filter { reference in
                let parsed = DisplayReference.parse(reference)
                guard parsed.kind == .bareUUID,
                      let alias = parsed.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
                      aliasesToRemove.contains(alias) else {
                    return true
                }
                bareUUIDHistoryByAlias[alias, default: []].insert(reference)
                return false
            })
            records[recordID] = record
        }
        for alias in canonicalClaimByAlias.keys.sorted() {
            guard let canonicalID = canonicalClaimByAlias[alias],
                  var record = records[canonicalID] else { continue }
            record.uuidAliases.insert(alias)
            record.legacyReferences.formUnion(bareUUIDHistoryByAlias[alias, default: []])
            records[canonicalID] = record
        }

        let registry = DisplayIdentityRegistry(records: Array(records.values))
        let byCanonical = Dictionary(uniqueKeysWithValues: registry.records.map { ($0.canonicalID, $0) })
        return RegistryUpdateResult(
            registry: registry,
            identityByRuntime: canonicalByRuntime.map { $0.flatMap { byCanonical[$0] } },
            replacementCanonicalIDs: replacements
        )
    }

    private static func collectSerialReferenceEvidence(
        runtimes: [DisplayRuntimeObservation],
        metadata: [DisplayMetadataObservation],
        invalidSerialKeys: Set<DisplayHardwareKey>
    ) -> [UInt32: SerialReferenceEvidence] {
        var result: [UInt32: SerialReferenceEvidence] = [:]

        func add(
            serialNumber: UInt32?,
            vendorID: UInt32,
            productID: UInt32,
            candidateRuntimeIDs: Set<UInt64>
        ) {
            guard let serialNumber, serialNumber != 0 else { return }
            let key = DisplayHardwareKey(
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber
            )
            var evidence = result[serialNumber] ?? SerialReferenceEvidence(
                hardwareScopes: [],
                candidateRuntimeIDs: [],
                containsInvalidEvidence: false
            )
            evidence.hardwareScopes.insert(key)
            evidence.candidateRuntimeIDs.formUnion(candidateRuntimeIDs)
            if (vendorID == 0 && productID == 0) || invalidSerialKeys.contains(key) {
                evidence.containsInvalidEvidence = true
            }
            result[serialNumber] = evidence
        }

        for runtime in runtimes {
            add(
                serialNumber: runtime.serialNumber,
                vendorID: runtime.vendorID,
                productID: runtime.productID,
                candidateRuntimeIDs: [runtime.runtimeID]
            )
        }

        for record in metadata {
            // Do not narrow this diagnostic evidence with a UUID. UUIDs describe
            // ports and are specifically unsafe for an unscoped legacy serial
            // after a port swap. Reconciled strong assignments still resolve via
            // the canonical/current-display paths above.
            let candidates = Set(runtimes.filter {
                modelsCompatible(
                    lhsVendor: $0.vendorID,
                    lhsProduct: $0.productID,
                    rhsVendor: record.vendorID,
                    rhsProduct: record.productID
                )
            }.map(\.runtimeID))
            add(
                serialNumber: record.serialNumber,
                vendorID: record.vendorID,
                productID: record.productID,
                candidateRuntimeIDs: candidates
            )
        }

        return result
    }

    private static func findInvalidSerialKeys(
        runtimes: [DisplayRuntimeObservation],
        metadata: [DisplayMetadataObservation]
    ) -> Set<DisplayHardwareKey> {
        var keysBySource: [String: [DisplayHardwareKey]] = [:]
        for runtime in runtimes {
            if let key = serialKey(
                vendorID: runtime.vendorID,
                productID: runtime.productID,
                serialNumber: runtime.serialNumber
            ) {
                keysBySource["runtime", default: []].append(key)
            }
        }
        for record in metadata {
            if let key = serialKey(
                vendorID: record.vendorID,
                productID: record.productID,
                serialNumber: record.serialNumber
            ) {
                keysBySource["metadata:\(record.source)", default: []].append(key)
            }
        }

        var invalid = Set<DisplayHardwareKey>()
        for keys in keysBySource.values {
            let counts = Dictionary(grouping: keys, by: { $0 }).mapValues(\.count)
            invalid.formUnion(counts.filter { $0.value > 1 }.map(\.key))
        }

        // If two source records can be attributed uniquely by an alias, or are
        // the sole records for a model in both sources, disagreement is
        // conflicting evidence rather than two identities.
        struct SerialObservation {
            let source: String
            let alias: String?
            let key: DisplayHardwareKey
        }
        var observations: [SerialObservation] = runtimes.compactMap { runtime in
            serialKey(
                vendorID: runtime.vendorID,
                productID: runtime.productID,
                serialNumber: runtime.serialNumber
            ).map {
                SerialObservation(
                    source: "runtime",
                    alias: runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
                    key: $0
                )
            }
        }
        observations.append(contentsOf: metadata.compactMap { record in
            serialKey(
                vendorID: record.vendorID,
                productID: record.productID,
                serialNumber: record.serialNumber
            ).map {
                SerialObservation(
                    source: "metadata:\(record.source)",
                    alias: record.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias),
                    key: $0
                )
            }
        })
        let modelSourceCounts = Dictionary(grouping: observations, by: {
            "\($0.source)|\($0.key.vendorID)|\($0.key.productID)"
        }).mapValues(\.count)

        for firstIndex in observations.indices {
            for secondIndex in observations.indices where secondIndex > firstIndex {
                let first = observations[firstIndex]
                let second = observations[secondIndex]
                guard first.source != second.source,
                      first.key.vendorID == second.key.vendorID,
                      first.key.productID == second.key.productID,
                      first.key.serialNumber != second.key.serialNumber else { continue }
                let sharedAlias = first.alias != nil && first.alias == second.alias
                let soleModelPair =
                    modelSourceCounts["\(first.source)|\(first.key.vendorID)|\(first.key.productID)"] == 1 &&
                    modelSourceCounts["\(second.source)|\(second.key.vendorID)|\(second.key.productID)"] == 1
                if sharedAlias || soleModelPair {
                    invalid.insert(first.key)
                    invalid.insert(second.key)
                }
            }
        }
        return invalid
    }

    private static func serialKey(
        vendorID: UInt32,
        productID: UInt32,
        serialNumber: UInt32?
    ) -> DisplayHardwareKey? {
        guard let serialNumber, serialNumber != 0,
              vendorID != 0 || productID != 0 else { return nil }
        return DisplayHardwareKey(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    private static func modelsCompatible(
        lhsVendor: UInt32,
        lhsProduct: UInt32,
        rhsVendor: UInt32,
        rhsProduct: UInt32
    ) -> Bool {
        let vendorCompatible = lhsVendor == 0 || rhsVendor == 0 || lhsVendor == rhsVendor
        let productCompatible = lhsProduct == 0 || rhsProduct == 0 || lhsProduct == rhsProduct
        return vendorCompatible && productCompatible
    }

    private static func sameKnownModel(
        lhsVendor: UInt32,
        lhsProduct: UInt32,
        rhsVendor: UInt32,
        rhsProduct: UInt32
    ) -> Bool {
        lhsVendor == rhsVendor && lhsProduct == rhsProduct &&
        (lhsVendor != 0 || lhsProduct != 0)
    }

    private static func modelGroupKey(vendorID: UInt32, productID: UInt32) -> String {
        "\(vendorID):\(productID)"
    }

    private static func canonicalSerialID(_ key: DisplayHardwareKey) -> String {
        "DockAnchorDisplay-V\(key.vendorID)M\(key.productID)-SN\(key.serialNumber)"
    }

    private static func canonicalWeakID(runtime: DisplayRuntimeObservation) -> String {
        if let alias = runtime.uuidAlias.flatMap(DisplayReference.normalizedUUIDAlias) {
            return "DockAnchorDisplay-UUID-\(alias)-V\(runtime.vendorID)M\(runtime.productID)"
        }
        return "DockAnchorDisplay-V\(runtime.vendorID)M\(runtime.productID)"
    }

    private static func metadataSortKey(_ record: DisplayMetadataObservation) -> String {
        [
            record.uuidAlias ?? "",
            String(record.vendorID),
            String(record.productID),
            String(record.serialNumber ?? 0),
            record.name ?? "",
            String(record.presentationPriority)
        ].joined(separator: "|")
    }
}

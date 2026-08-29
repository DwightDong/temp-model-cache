import Foundation
import Testing
@testable import DockAnchor

private let uuidA = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
private let uuidB = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
private let uuidC = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
private let uuidD = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"

private func runtime(
    _ id: UInt64,
    _ uuid: String?,
    vendor: UInt32 = 100,
    product: UInt32 = 10,
    serial: UInt32? = nil,
    builtIn: Bool = false
) -> DisplayRuntimeObservation {
    DisplayRuntimeObservation(
        runtimeID: id,
        uuidAlias: uuid,
        vendorID: vendor,
        productID: product,
        serialNumber: serial,
        isBuiltIn: builtIn
    )
}

private func metadata(
    _ source: String,
    _ id: String,
    _ uuid: String? = nil,
    vendor: UInt32 = 100,
    product: UInt32 = 10,
    serial: UInt32? = nil,
    name: String? = nil,
    priority: Int = 100
) -> DisplayMetadataObservation {
    DisplayMetadataObservation(
        source: source,
        sourceID: id,
        uuidAlias: uuid,
        vendorID: vendor,
        productID: product,
        serialNumber: serial,
        name: name,
        presentationPriority: priority
    )
}

private func permutations<T>(_ values: [T]) -> [[T]] {
    guard values.count > 1 else { return [values] }
    return values.indices.flatMap { index -> [[T]] in
        var remainder = values
        let value = remainder.remove(at: index)
        return permutations(remainder).map { [value] + $0 }
    }
}

private func metadataPermutations(_ records: [DisplayMetadataObservation]) -> [[DisplayMetadataObservation]] {
    let sourceGroups = Dictionary(grouping: records, by: \.source)
    let sources = sourceGroups.keys.sorted()
    var results: [[DisplayMetadataObservation]] = [[]]
    for source in sources {
        let sourcePermutations = permutations(sourceGroups[source, default: []])
        results = results.flatMap { prefix in
            sourcePermutations.map { prefix + $0 }
        }
    }
    return results
}

private func snapshotSignature(_ snapshot: DisplayReconciliationSnapshot) -> String {
    let displayLines = snapshot.displays.map { display in
        let assignments = display.metadataAssignments.keys.sorted().map {
            "\($0)=\(display.metadataAssignments[$0]!)"
        }.joined(separator: ",")
        return [
            String(display.runtime.runtimeID),
            display.identity?.canonicalID ?? "nil",
            display.resolution.rawValue,
            display.friendlyName ?? "nil",
            assignments
        ].joined(separator: "|")
    }
    let registryLines = snapshot.registry.records.map { record in
        [
            record.canonicalID,
            String(record.vendorID),
            String(record.productID),
            String(record.serialNumber ?? 0),
            record.uuidAliases.sorted().joined(separator: ","),
            record.legacyReferences.sorted().joined(separator: ",")
        ].joined(separator: "|")
    }
    return (displayLines + ["--"] + registryLines).joined(separator: "\n")
}

@discardableResult
private func reconcileEveryPermutation(
    runtimes: [DisplayRuntimeObservation],
    metadata: [DisplayMetadataObservation],
    prior: DisplayIdentityRegistry = DisplayIdentityRegistry(),
    validate: (DisplayReconciliationSnapshot) -> Void = { _ in }
) -> DisplayReconciliationSnapshot {
    let snapshots = permutations(runtimes).flatMap { runtimeOrder in
        metadataPermutations(metadata).map { metadataOrder in
            DisplayReconciler.reconcile(
                runtimes: runtimeOrder,
                metadata: metadataOrder,
                priorRegistry: prior
            )
        }
    }
    #expect(Set(snapshots.map(snapshotSignature)).count == 1)
    snapshots.forEach(validate)
    return snapshots[0]
}

private func canonicalBySerial(
    _ serial: UInt32,
    in snapshot: DisplayReconciliationSnapshot
) -> String? {
    snapshot.displays.first { $0.identity?.serialNumber == serial }?.identity?.canonicalID
}

struct DisplayIdentityReconciliationTests {
    @Test("identical models use distinct serials, not metadata order")
    func identicalModelsWithReversedMetadata() {
        let snapshot = reconcileEveryPermutation(
            runtimes: [
                runtime(41, uuidA, serial: 111),
                runtime(12, uuidB, serial: 222)
            ],
            metadata: [
                metadata("iokit", "io-b", vendor: 100, product: 10, serial: 222, name: "Monitor B"),
                metadata("iokit", "io-a", vendor: 100, product: 10, serial: 111, name: "Monitor A")
            ]
        )

        let a = snapshot.display(runtimeID: 41)
        let b = snapshot.display(runtimeID: 12)
        #expect(a?.identity?.serialNumber == 111)
        #expect(b?.identity?.serialNumber == 222)
        #expect(a?.friendlyName == "Monitor A")
        #expect(b?.friendlyName == "Monitor B")
        #expect(Set(snapshot.displays.compactMap { $0.metadataAssignments["iokit"] }).count == 2)
    }

    @Test("same-resolution presentation metadata follows hardware model")
    func sameResolutionDifferentModelsAndNames() {
        // Resolution is intentionally absent from the identity observations: it
        // is mutable presentation data and cannot break a tie.
        let snapshot = reconcileEveryPermutation(
            runtimes: [
                runtime(1, uuidA, vendor: 100, product: 10),
                runtime(2, uuidB, vendor: 200, product: 20)
            ],
            metadata: [
                metadata("profiler", "profile-b", vendor: 200, product: 20, name: "Studio 4K"),
                metadata("profiler", "profile-a", vendor: 100, product: 10, name: "Office 4K")
            ]
        )

        #expect(snapshot.display(runtimeID: 1)?.friendlyName == "Office 4K")
        #expect(snapshot.display(runtimeID: 2)?.friendlyName == "Studio 4K")
        #expect(snapshot.displays.allSatisfy { $0.resolution == .unique })
    }

    @Test("runtime IDs and collection order do not change physical identity")
    func runtimeIDChurn() {
        let first = reconcileEveryPermutation(
            runtimes: [
                runtime(1, uuidA, serial: 111),
                runtime(2, uuidB, serial: 222)
            ],
            metadata: [
                metadata("iokit", "a", uuidA, serial: 111),
                metadata("iokit", "b", uuidB, serial: 222),
                metadata("profiler", "pa", vendor: 100, product: 10, serial: 111, name: "A"),
                metadata("profiler", "pb", vendor: 100, product: 10, serial: 222, name: "B")
            ]
        )
        let selectedB = canonicalBySerial(222, in: first)!

        let second = reconcileEveryPermutation(
            runtimes: [
                runtime(900, uuidB, serial: 222),
                runtime(700, uuidA, serial: 111)
            ],
            metadata: [
                metadata("iokit", "new-b", uuidB, serial: 222),
                metadata("iokit", "new-a", uuidA, serial: 111)
            ],
            prior: first.registry
        )

        #expect(canonicalBySerial(111, in: second) == canonicalBySerial(111, in: first))
        #expect(canonicalBySerial(222, in: second) == selectedB)
        #expect(second.resolve(selectedB) == .resolved(runtimeID: 900, canonicalReference: selectedB))
    }

    @Test("serial identity outranks stale aliases after a port swap")
    func portSwap() {
        let first = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: []
        )
        let aID = canonicalBySerial(111, in: first)!
        let bID = canonicalBySerial(222, in: first)!

        let swapped = reconcileEveryPermutation(
            runtimes: [
                runtime(30, uuidB, serial: 111),
                runtime(40, uuidA, serial: 222)
            ],
            metadata: [
                metadata("iokit", "b-hardware", vendor: 100, product: 10, serial: 222),
                metadata("iokit", "a-hardware", vendor: 100, product: 10, serial: 111)
            ],
            prior: first.registry
        )

        #expect(swapped.resolve(aID) == .resolved(runtimeID: 30, canonicalReference: aID))
        #expect(swapped.resolve(bID) == .resolved(runtimeID: 40, canonicalReference: bID))
        #expect(swapped.registry.records.first { $0.canonicalID == aID }?.uuidAliases.contains(uuidB) == true)
        #expect(swapped.registry.records.first { $0.canonicalID == bID }?.uuidAliases.contains(uuidA) == true)
    }

    @Test("temporary serial loss retains an established stable identity")
    func temporarySerialLoss() {
        let established = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: []
        )
        let bID = canonicalBySerial(222, in: established)!

        let missing = reconcileEveryPermutation(
            runtimes: [runtime(10, uuidA, serial: 111), runtime(20, uuidB, serial: nil)],
            metadata: [],
            prior: established.registry
        )
        let b = missing.display(runtimeID: 20)
        #expect(b?.resolution == .unique)
        #expect(b?.identity?.canonicalID == bID)
        #expect(b?.identity?.serialNumber == 222)
        #expect(missing.resolve(bID) == .resolved(runtimeID: 20, canonicalReference: bID))
    }

    @Test("one-to-one elimination resolves one display then becomes ambiguous")
    func oneToOneEliminationAndAmbiguityTransition() {
        let established = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: []
        )
        let bID = canonicalBySerial(222, in: established)!

        let eliminated = reconcileEveryPermutation(
            runtimes: [
                runtime(10, uuidC, serial: 111),
                runtime(20, uuidD, serial: nil)
            ],
            metadata: [],
            prior: established.registry
        )
        #expect(eliminated.display(runtimeID: 20)?.identity?.canonicalID == bID)
        #expect(eliminated.resolve(bID) == .resolved(runtimeID: 20, canonicalReference: bID))

        let extraAlias = "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"
        let ambiguous = reconcileEveryPermutation(
            runtimes: [
                runtime(10, uuidC, serial: 111),
                runtime(20, uuidD, serial: nil),
                runtime(30, extraAlias, serial: nil)
            ],
            metadata: [],
            prior: established.registry
        )
        #expect(ambiguous.display(runtimeID: 10)?.resolution == .unique)
        #expect(ambiguous.display(runtimeID: 20)?.resolution == .ambiguous)
        #expect(ambiguous.display(runtimeID: 30)?.resolution == .ambiguous)
        #expect(ambiguous.resolve(bID) == .ambiguous(candidateRuntimeIDs: [20, 30]))
    }

    @Test("serialless duplicate displays are explicitly ambiguous")
    func fullyAmbiguousSeriallessDuplicates() {
        let snapshot = reconcileEveryPermutation(
            runtimes: [runtime(90, uuidA), runtime(11, uuidB)],
            metadata: [
                metadata("profiler", "one", vendor: 100, product: 10, name: "Same Model"),
                metadata("profiler", "two", vendor: 100, product: 10, name: "Same Model")
            ]
        )

        #expect(snapshot.displays.allSatisfy { $0.resolution == .ambiguous })
        #expect(snapshot.displays.allSatisfy { $0.identity == nil })
        #expect(snapshot.displays.allSatisfy { $0.metadataAssignments.isEmpty })
        #expect(snapshot.resolve(uuidA) == .ambiguous(candidateRuntimeIDs: [11, 90]))
        #expect(DisplayProfileMatcher.uniqueMatch(
            for: 90,
            references: [uuidA],
            enabled: [true],
            snapshot: snapshot
        ) == nil)
    }

    @Test("legacy references migrate only after unique reconciliation")
    func legacyReferenceMatrix() {
        let snapshot = reconcileEveryPermutation(
            runtimes: [
                runtime(10, uuidA, vendor: 100, product: 10, serial: 111),
                runtime(20, uuidB, vendor: 100, product: 10, serial: 222),
                runtime(30, uuidC, vendor: 200, product: 20, serial: nil)
            ],
            metadata: []
        )
        let aID = canonicalBySerial(111, in: snapshot)!
        let bID = canonicalBySerial(222, in: snapshot)!
        let cID = snapshot.display(runtimeID: 30)!.identity!.canonicalID
        let serialLegacy = "99999999-9999-4999-8999-999999999999-SN222"
        let duplicateModelLegacy = "88888888-8888-4888-8888-888888888888-V100M10"
        let uniqueModelLegacy = "77777777-7777-4777-8777-777777777777-V200M20"
        let malformed = "not-a-display-SNnope"
        let unknown = "unknown-display-reference"
        let references = [
            uuidA, serialLegacy, duplicateModelLegacy, uniqueModelLegacy,
            "DisplayID-20", "DisplayID-20-SN999", "DisplayID-999-SN222",
            "DisplayID-999", malformed, unknown, serialLegacy
        ]
        let migration = DisplayReferenceMigrator.migrate(references: references, using: snapshot)

        #expect(migration.references == [
            aID, bID, duplicateModelLegacy, cID,
            bID, bID, "DisplayID-999-SN222",
            "DisplayID-999", malformed, unknown, bID
        ])
        #expect(snapshot.resolve(duplicateModelLegacy) == .ambiguous(candidateRuntimeIDs: [10, 20]))
        #expect(snapshot.resolve("DisplayID-999") == .unavailable)
        #expect(snapshot.resolve(malformed) == .unresolved)
        #expect(snapshot.resolve(unknown) == .unresolved)

        let registryWithHistory = snapshot.registry.recordingLegacyReferences(migration.migrations)
        let idempotentSnapshot = snapshot.withRegistry(registryWithHistory)
        let second = DisplayReferenceMigrator.migrate(
            references: migration.references,
            using: idempotentSnapshot
        )
        #expect(second.references == migration.references)
        #expect(second.migrations.isEmpty)
        #expect(registryWithHistory.records.first { $0.canonicalID == bID }?.legacyReferences.contains(serialLegacy) == true)
        #expect(registryWithHistory.records.allSatisfy {
            !$0.legacyReferences.contains("DisplayID-20") &&
            !$0.legacyReferences.contains("DisplayID-20-SN999")
        })

        let laterDuplicate = DisplayReconciler.reconcile(
            runtimes: [
                runtime(300, uuidC, vendor: 200, product: 20),
                runtime(400, uuidD, vendor: 200, product: 20)
            ],
            metadata: [],
            priorRegistry: registryWithHistory
        )
        #expect(laterDuplicate.resolve(uniqueModelLegacy) ==
            .ambiguous(candidateRuntimeIDs: [300, 400]))
    }

    @Test("legacy profiles decode and migration preserves all profile fields")
    func preAutoActivateProfileAndFieldPreservation() throws {
        let profileID = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
        let oldReference = "99999999-9999-4999-8999-999999999999-SN222"
        let json = """
        {
          "id": "\(profileID.uuidString)",
          "name": "Legacy",
          "anchorDisplayUUID": "\(oldReference)",
          "createdAt": 12345
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DockProfile.self, from: json)
        #expect(decoded.autoActivate == false)

        let snapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(20, uuidB, serial: 222)],
            metadata: []
        )
        let migration = DisplayReferenceMigrator.migrate(
            references: [decoded.anchorDisplayUUID],
            using: snapshot
        )
        var migrated = decoded
        migrated.anchorDisplayUUID = migration.references[0]

        #expect(migrated.id == decoded.id)
        #expect(migrated.name == decoded.name)
        #expect(migrated.createdAt == decoded.createdAt)
        #expect(migrated.autoActivate == decoded.autoActivate)
        let activeProfileID: UUID? = profileID
        #expect(activeProfileID == migrated.id)
    }

    @Test("disconnect fallback preserves preference and reconnect restores it")
    func disconnectReconnectSequence() {
        let connected = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: []
        )
        let preferredB = canonicalBySerial(222, in: connected)!
        let profileAnchor = preferredB
        let activeProfileID: UUID? = UUID()
        let originalActiveProfileID = activeProfileID

        let disconnected = reconcileEveryPermutation(
            runtimes: [runtime(100, uuidA, serial: 111)],
            metadata: [],
            prior: connected.registry
        )
        let absentDecision = DisplayAnchorResolver.resolve(
            preferredReference: preferredB,
            fallbackRuntimeID: 100,
            snapshot: disconnected
        )
        #expect(absentDecision.usesFallback)
        #expect(absentDecision.effectiveRuntimeID == 100)
        #expect(absentDecision.preferredResolution == .unavailable)
        #expect(DisplayReferenceMigrator.migrate(
            references: [preferredB, profileAnchor],
            using: disconnected
        ).references == [preferredB, profileAnchor])
        #expect(activeProfileID == originalActiveProfileID)

        let reconnected = reconcileEveryPermutation(
            runtimes: [
                runtime(400, uuidD, serial: 222),
                runtime(300, uuidC, serial: 111)
            ],
            metadata: [],
            prior: disconnected.registry
        )
        let restored = DisplayAnchorResolver.resolve(
            preferredReference: preferredB,
            fallbackRuntimeID: 300,
            snapshot: reconnected
        )
        #expect(!restored.usesFallback)
        #expect(restored.effectiveRuntimeID == 400)
        #expect(profileAnchor == preferredB)
        #expect(activeProfileID != nil)
    }

    @Test("profile matching discriminates duplicate models and ignores profile ordering")
    func profileDiscriminationAndOrdering() {
        let snapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(10, uuidA, serial: 111), runtime(20, uuidB, serial: 222)],
            metadata: []
        )
        let aID = canonicalBySerial(111, in: snapshot)!
        let bID = canonicalBySerial(222, in: snapshot)!

        #expect(DisplayProfileMatcher.uniqueMatch(
            for: 20,
            references: [aID, bID],
            enabled: [true, true],
            snapshot: snapshot
        ) == 1)
        #expect(DisplayProfileMatcher.uniqueMatch(
            for: 20,
            references: [bID, aID],
            enabled: [true, true],
            snapshot: snapshot
        ) == 0)

        let ambiguous = DisplayReconciler.reconcile(
            runtimes: [runtime(100, uuidC), runtime(200, uuidD)],
            metadata: [],
            priorRegistry: snapshot.registry
        )
        #expect(DisplayProfileMatcher.uniqueMatch(
            for: 100,
            references: [aID, bID],
            enabled: [true, true],
            snapshot: ambiguous
        ) == nil)
    }

    @Test("zero, duplicate, and conflicting serials never collapse identities")
    func invalidSerialEvidence() {
        let zero = reconcileEveryPermutation(
            runtimes: [runtime(1, uuidA, serial: 0), runtime(2, uuidB, serial: 0)],
            metadata: []
        )
        #expect(zero.displays.allSatisfy { $0.resolution == .ambiguous })
        #expect(zero.registry.records.isEmpty)

        let duplicate = reconcileEveryPermutation(
            runtimes: [runtime(1, uuidA, serial: 7), runtime(2, uuidB, serial: 7)],
            metadata: [
                metadata("iokit", "one", vendor: 100, product: 10, serial: 7),
                metadata("iokit", "two", vendor: 100, product: 10, serial: 7)
            ]
        )
        #expect(duplicate.displays.allSatisfy { $0.resolution == .ambiguous })
        #expect(duplicate.registry.records.isEmpty)
        #expect(duplicate.resolve("99999999-9999-4999-8999-999999999999-SN7") ==
            .ambiguous(candidateRuntimeIDs: [1, 2]))

        let conflict = reconcileEveryPermutation(
            runtimes: [runtime(9, uuidA, serial: 111)],
            metadata: [metadata("iokit", "conflict", uuidA, serial: 222, name: "Conflicted")]
        )
        #expect(conflict.display(runtimeID: 9)?.resolution == .unique)
        #expect(conflict.display(runtimeID: 9)?.identity?.serialNumber == nil)
        #expect(conflict.registry.records.count == 1)
    }

    @Test("registry encoding and reconciliation are idempotent")
    func registryPersistenceIsDeterministicAndIdempotent() throws {
        let snapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(2, uuidB, serial: 222), runtime(1, uuidA, serial: 111)],
            metadata: []
        )
        let encoded = try JSONEncoder().encode(snapshot.registry)
        let decoded = try JSONDecoder().decode(DisplayIdentityRegistry.self, from: encoded)
        #expect(decoded == snapshot.registry)

        let repeated = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: [],
            priorRegistry: decoded
        )
        #expect(repeated.registry == snapshot.registry)
        #expect(snapshotSignature(repeated) == snapshotSignature(snapshot))
    }
    @Test("runtime selectors migrate only while present and never persist as aliases")
    func runtimeSelectorsAreSnapshotOnly() throws {
        let snapshot = reconcileEveryPermutation(
            runtimes: [runtime(77, "DisplayID-77", vendor: 300, product: 30)],
            metadata: [
                metadata(
                    "iokit",
                    "runtime-shaped-alias",
                    "DisplayID-77",
                    vendor: 300,
                    product: 30
                )
            ],
            prior: DisplayIdentityRegistry(records: [
                DisplayIdentityRecord(
                    canonicalID: "DockAnchorDisplay-V999M99",
                    vendorID: 999,
                    productID: 99,
                    uuidAliases: ["DisplayID-77"],
                    legacyReferences: ["DisplayID-77-SN9"]
                ),
                DisplayIdentityRecord(
                    canonicalID: "DockAnchorDisplay-UUID-DISPLAYID-77-V300M30",
                    vendorID: 300,
                    productID: 30,
                    uuidAliases: ["DisplayID-77"]
                )
            ])
        )
        let canonical = snapshot.display(runtimeID: 77)?.identity?.canonicalID
        #expect(canonical != nil)
        #expect(snapshot.displays[0].runtime.uuidAlias == nil)
        #expect(snapshot.registry.records.allSatisfy { record in
            record.uuidAliases.allSatisfy { !$0.hasPrefix("DisplayID-") } &&
                record.legacyReferences.allSatisfy { !$0.hasPrefix("DisplayID-") }
        })

        let forms = ["DisplayID-77", "DisplayID-77-SN999", "DisplayID-77-V300M30"]
        let migrated = DisplayReferenceMigrator.migrate(references: forms, using: snapshot)
        #expect(migrated.references == [canonical!, canonical!, canonical!])
        let withHistory = snapshot.registry.recordingLegacyReferences(migrated.migrations)
        #expect(withHistory.records.allSatisfy { record in
            forms.allSatisfy { !record.legacyReferences.contains($0) }
        })

        let next = DisplayReconciler.reconcile(
            runtimes: [runtime(88, nil, vendor: 300, product: 30)],
            metadata: [],
            priorRegistry: withHistory
        )
        for form in forms {
            #expect(next.resolve(form) == .unavailable)
        }
        #expect(next.registry.records.allSatisfy { $0.uuidAliases.isEmpty })

        let encoded = try JSONEncoder().encode(withHistory)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("DisplayID-"))
    }

    @Test("persisted ambiguous launch selection falls back without relocation")
    func persistedAmbiguityIsNotAnExplicitSelection() throws {
        let snapshot = reconcileEveryPermutation(
            runtimes: [runtime(10, uuidA), runtime(20, uuidB)],
            metadata: []
        )
        let suiteName = "DockAnchorTests.ambiguous-launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let profile = DockProfile(
            id: profileID,
            name: "Ambiguous B",
            anchorDisplayUUID: uuidB,
            createdAt: Date(timeIntervalSinceReferenceDate: 123),
            autoActivate: true
        )
        defaults.set(uuidB, forKey: "selectedDisplayUUID")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "dockProfiles")
        defaults.set(profileID.uuidString, forKey: "activeProfileID")
        let settings = AppSettings(
            userDefaults: defaults,
            manageLoginItem: false,
            mainDisplayReference: uuidA
        )
        #expect(settings.reconcileDisplayReferences(using: snapshot).isEmpty)
        #expect(settings.nonPersistentDisplayReferences == Set([uuidB]))
        #expect(settings.selectedDisplayUUID == uuidB)
        #expect(settings.profiles == [profile])
        #expect(settings.activeProfileID == profileID)

        let restored = DisplayAnchorResolver.resolve(
            preferredReference: uuidB,
            fallbackRuntimeID: 10,
            snapshot: snapshot,
            intent: .persistedPreference
        )
        #expect(restored.preferredResolution == .ambiguous(candidateRuntimeIDs: [10, 20]))
        #expect(restored.effectiveRuntimeID == 10)
        #expect(restored.usesFallback)
        #expect(!restored.isTemporaryExplicitSelection)
        #expect(!restored.permitsAutomaticRelocation)

        let explicit = DisplayAnchorResolver.resolve(
            preferredReference: uuidB,
            fallbackRuntimeID: 10,
            snapshot: snapshot,
            intent: .explicitUserSelection
        )
        #expect(explicit.effectiveRuntimeID == 20)
        #expect(!explicit.usesFallback)
        #expect(explicit.isTemporaryExplicitSelection)
        #expect(!explicit.permitsAutomaticRelocation)

        // A later port swap must not turn restoration into another explicit
        // choice merely because the persisted UUID is still present.
        let swapped = reconcileEveryPermutation(
            runtimes: [runtime(110, uuidB), runtime(120, uuidA)],
            metadata: [],
            prior: snapshot.registry
        )
        let restoredAfterSwap = DisplayAnchorResolver.resolve(
            preferredReference: uuidB,
            fallbackRuntimeID: 120,
            snapshot: swapped,
            intent: .persistedPreference
        )
        #expect(restoredAfterSwap.usesFallback)
        #expect(restoredAfterSwap.effectiveRuntimeID == 120)
        #expect(!restoredAfterSwap.permitsAutomaticRelocation)
        #expect(settings.reconcileDisplayReferences(using: swapped).isEmpty)
        #expect(settings.selectedDisplayUUID == uuidB)
        #expect(settings.profiles == [profile])
        #expect(settings.activeProfileID == profileID)
    }

    @Test("malformed UUID-based references remain byte-for-byte unresolved")
    func malformedUUIDReferencesNeverMigrate() {
        let snapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(20, uuidB, serial: 222)],
            metadata: []
        )
        let malformed = [
            "garbage-SN222",
            "garbage-V100M10",
            " \(uuidB)",
            "\(uuidB) ",
            "\(uuidB)-SN0",
            "\(uuidB)-SN222junk",
            "\(uuidB)-V100M10junk",
            "DisplayID-20-SN0",
            "DisplayID-20-V0M0",
            "DisplayID-20-V100M10-extra"
        ]
        let migration = DisplayReferenceMigrator.migrate(references: malformed, using: snapshot)
        #expect(migration.references == malformed)
        #expect(migration.migrations.isEmpty)
        for reference in malformed {
            #expect(snapshot.resolve(reference) == .unresolved)
        }

        let valid = [
            "\(uuidB)-SN222",
            "\(uuidB)-V100M10",
            "DisplayID-20-SN222",
            "DisplayID-20-V100M10"
        ]
        #expect(DisplayReferenceMigrator.migrate(references: valid, using: snapshot)
            .references.allSatisfy { $0 == snapshot.display(runtimeID: 20)?.identity?.canonicalID })
    }

    @Test("AppSettings migrates selected and persisted profile references atomically")
    func settingsAndProfileMigrationUsesProductionPersistence() throws {
        let suiteName = "DockAnchorTests.settings-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = "99999999-9999-4999-8999-999999999999-SN222"
        let malformed = "garbage-SN222"
        let activeID = UUID(uuidString: "12345678-1234-4234-8234-123456789012")!
        let secondID = UUID(uuidString: "87654321-4321-4321-8321-210987654321")!
        let malformedID = UUID(uuidString: "AAAAAAAA-1234-4234-8234-123456789012")!
        let profilesJSON = """
        [
          {
            "id": "\(activeID.uuidString)",
            "name": "Predates Auto Activation",
            "anchorDisplayUUID": "\(legacy)",
            "createdAt": 12345
          },
          {
            "id": "\(secondID.uuidString)",
            "name": "Same Legacy Value",
            "anchorDisplayUUID": "\(legacy)",
            "createdAt": 54321,
            "autoActivate": true
          },
          {
            "id": "\(malformedID.uuidString)",
            "name": "Malformed",
            "anchorDisplayUUID": "\(malformed)",
            "createdAt": 999,
            "autoActivate": true
          }
        ]
        """.data(using: .utf8)!
        defaults.set(legacy, forKey: "selectedDisplayUUID")
        defaults.set(profilesJSON, forKey: "dockProfiles")
        defaults.set(activeID.uuidString, forKey: "activeProfileID")

        let settings = AppSettings(
            userDefaults: defaults,
            manageLoginItem: false,
            mainDisplayReference: uuidA
        )
        let originalProfiles = settings.profiles
        let snapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(20, uuidB, serial: 222)],
            metadata: []
        )
        let canonical = snapshot.display(runtimeID: 20)!.identity!.canonicalID

        let migrations = settings.reconcileDisplayReferences(using: snapshot)
        #expect(migrations == [legacy: canonical])
        #expect(settings.selectedDisplayUUID == canonical)
        #expect(settings.profiles.map(\.anchorDisplayUUID) == [canonical, canonical, malformed])
        #expect(settings.activeProfileID == activeID)
        #expect(settings.profiles.map(\.id) == originalProfiles.map(\.id))
        #expect(settings.profiles.map(\.name) == originalProfiles.map(\.name))
        #expect(settings.profiles.map(\.createdAt) == originalProfiles.map(\.createdAt))
        #expect(settings.profiles.map(\.autoActivate) == [false, true, true])

        let persistedProfiles = try JSONDecoder().decode(
            [DockProfile].self,
            from: defaults.data(forKey: "dockProfiles")!
        )
        #expect(defaults.string(forKey: "selectedDisplayUUID") == canonical)
        #expect(defaults.string(forKey: "activeProfileID") == activeID.uuidString)
        #expect(persistedProfiles == settings.profiles)
        #expect(settings.reconcileDisplayReferences(using: snapshot).isEmpty)
        #expect(settings.findAutoActivateProfile(
            forRuntimeDisplayID: 20,
            snapshot: snapshot
        )?.id == secondID)
    }

    @Test("hot-plug policy blocks ambiguous profile activation and relocation")
    func hotPlugUsesSnapshotPolicyBoundary() {
        let established = DisplayReconciler.reconcile(
            runtimes: [runtime(1, uuidA, serial: 111), runtime(2, uuidB, serial: 222)],
            metadata: []
        )
        let aID = canonicalBySerial(111, in: established)!
        let bID = canonicalBySerial(222, in: established)!
        let unique = DisplayHotPlugResolver.displayAdded(
            runtimeID: 2,
            preferredReference: bID,
            profileReferences: [bID, aID],
            profileAutoActivation: [true, true],
            currentAnchorIsUnique: true,
            autoRelocate: true,
            snapshot: established
        )
        #expect(unique.autoActivateProfileIndex == 0)
        #expect(unique.restoresPreferredAnchor)
        #expect(unique.permitsAutomaticRelocation)
        #expect(!unique.isAmbiguous)

        let ambiguous = reconcileEveryPermutation(
            runtimes: [runtime(100, uuidC), runtime(200, uuidD)],
            metadata: [],
            prior: established.registry
        )
        for connectedID: UInt64 in [100, 200] {
            let decision = DisplayHotPlugResolver.displayAdded(
                runtimeID: connectedID,
                preferredReference: bID,
                profileReferences: [bID, aID],
                profileAutoActivation: [true, true],
                currentAnchorIsUnique: true,
                autoRelocate: true,
                snapshot: ambiguous
            )
            #expect(decision.isAmbiguous)
            #expect(decision.autoActivateProfileIndex == nil)
            #expect(!decision.restoresPreferredAnchor)
            #expect(!decision.permitsAutomaticRelocation)
        }
    }

    @Test("equal serial numbers remain distinct across vendor and product scopes")
    func serialIdentityIsHardwareScoped() {
        let snapshot = reconcileEveryPermutation(
            runtimes: [
                runtime(10, uuidA, vendor: 100, product: 10, serial: 7),
                runtime(20, uuidB, vendor: 200, product: 20, serial: 7)
            ],
            metadata: [
                metadata("iokit", "scope-b", uuidB, vendor: 200, product: 20, serial: 7),
                metadata("iokit", "scope-a", uuidA, vendor: 100, product: 10, serial: 7)
            ]
        )
        let aID = snapshot.display(runtimeID: 10)?.identity?.canonicalID
        let bID = snapshot.display(runtimeID: 20)?.identity?.canonicalID
        #expect(aID != nil && bID != nil && aID != bID)
        #expect(snapshot.displays.allSatisfy { $0.resolution == .unique })

        // The legacy serial shape does not contain vendor/product. Its UUID is
        // a port alias, so even a currently matching alias cannot scope serial 7.
        let references = ["\(uuidA)-SN7", "\(uuidB)-SN7",
                          "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE-SN7"]
        for reference in references {
            #expect(snapshot.resolve(reference) ==
                .ambiguous(candidateRuntimeIDs: [10, 20]))
        }
        #expect(DisplayReferenceMigrator.migrate(
            references: references,
            using: snapshot
        ).references == references)

        // Canonical scoped identities remain independently resolvable.
        #expect(snapshot.resolve(aID!) == .resolved(runtimeID: 10, canonicalReference: aID!))
        #expect(snapshot.resolve(bID!) == .resolved(runtimeID: 20, canonicalReference: bID!))
    }

    @Test("ambiguous explicit selections remain temporary after a port/topology change")
    func ambiguousExplicitSelectionCannotAcquireContinuity() throws {
        let ambiguous = reconcileEveryPermutation(
            runtimes: [runtime(10, uuidA), runtime(20, uuidB)],
            metadata: []
        )
        let suiteName = "DockAnchorTests.temporary-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(uuidA, forKey: "selectedDisplayUUID")
        let settings = AppSettings(
            userDefaults: defaults,
            manageLoginItem: false,
            mainDisplayReference: uuidA
        )

        let explicit = DisplayAnchorResolver.resolve(
            preferredReference: uuidB,
            fallbackRuntimeID: 10,
            snapshot: ambiguous,
            intent: .explicitUserSelection
        )
        #expect(explicit.isTemporaryExplicitSelection)
        #expect(explicit.effectiveRuntimeID == 20)
        settings.selectDisplay(reference: uuidB, identityResolution: .ambiguous)
        let profile = settings.createProfile(name: "Temporary B", autoActivate: true)
        settings.activeProfileID = profile.id

        // B's old UUID is now on the sole remaining same-model display. Model
        // elimination makes that display unique, but says nothing about whether
        // it is the physical display selected before the port change.
        let afterPortAndTopologyChange = DisplayReconciler.reconcile(
            runtimes: [runtime(200, uuidB)],
            metadata: [],
            priorRegistry: ambiguous.registry
        )
        #expect(afterPortAndTopologyChange.resolve(uuidB).isUniquelyResolved)
        #expect(settings.reconcileDisplayReferences(using: afterPortAndTopologyChange).isEmpty)
        #expect(settings.selectedDisplayUUID == uuidB)
        #expect(settings.profiles.first?.anchorDisplayUUID == uuidB)
        #expect(settings.activeProfileID == profile.id)

        let restored = DisplayAnchorResolver.resolve(
            preferredReference: uuidB,
            fallbackRuntimeID: 200,
            snapshot: afterPortAndTopologyChange,
            intent: .persistedPreference,
            excludingInferredReferences: settings.nonPersistentDisplayReferences
        )
        #expect(restored.preferredResolution == .ambiguous(candidateRuntimeIDs: [200]))
        #expect(restored.usesFallback)
        #expect(!restored.permitsAutomaticRelocation)
        #expect(settings.findAutoActivateProfile(
            forRuntimeDisplayID: 200,
            snapshot: afterPortAndTopologyChange
        ) == nil)
        let hotPlug = DisplayHotPlugResolver.displayAdded(
            runtimeID: 200,
            preferredReference: settings.selectedDisplayUUID,
            profileReferences: settings.profiles.map(\.anchorDisplayUUID),
            profileAutoActivation: settings.profiles.map(\.autoActivate),
            currentAnchorIsUnique: true,
            autoRelocate: true,
            snapshot: afterPortAndTopologyChange,
            excludingInferredReferences: settings.nonPersistentDisplayReferences
        )
        #expect(hotPlug.isAmbiguous)
        #expect(hotPlug.autoActivateProfileIndex == nil)
        #expect(!hotPlug.restoresPreferredAnchor)
        #expect(!hotPlug.permitsAutomaticRelocation)

        // Provenance survives relaunch; otherwise the next launch would perform
        // the unsafe migration after seeing only this one candidate.
        let reloaded = AppSettings(
            userDefaults: defaults,
            manageLoginItem: false,
            mainDisplayReference: uuidA
        )
        #expect(reloaded.nonPersistentDisplayReferences == Set([uuidB]))
        #expect(reloaded.reconcileDisplayReferences(using: afterPortAndTopologyChange).isEmpty)
        #expect(reloaded.selectedDisplayUUID == uuidB)
        #expect(reloaded.profiles.first?.anchorDisplayUUID == uuidB)
        #expect(reloaded.activeProfileID == profile.id)
    }

    @Test("a stale UUID cannot scope the same legacy serial across hardware models")
    func staleAliasDoesNotDisambiguateUnscopedSerialAfterPortSwap() {
        let established = reconcileEveryPermutation(
            runtimes: [
                runtime(10, uuidA, vendor: 100, product: 10, serial: 7),
                runtime(20, uuidB, vendor: 200, product: 20, serial: 7)
            ],
            metadata: []
        )
        let aID = established.display(runtimeID: 10)!.identity!.canonicalID
        let bID = established.display(runtimeID: 20)!.identity!.canonicalID

        let legacyA = "\(uuidA)-SN7"
        let legacyB = "\(uuidB)-SN7"
        let swapped = reconcileEveryPermutation(
            runtimes: [
                runtime(30, uuidB, vendor: 100, product: 10, serial: 7),
                runtime(40, uuidA, vendor: 200, product: 20, serial: 7)
            ],
            metadata: [
                metadata("iokit", "hardware-b", uuidA, vendor: 200, product: 20, serial: 7),
                metadata("iokit", "hardware-a", uuidB, vendor: 100, product: 10, serial: 7)
            ],
            prior: established.registry,
            validate: { candidate in
                #expect(candidate.resolve(legacyA) ==
                    .ambiguous(candidateRuntimeIDs: [30, 40]))
                #expect(candidate.resolve(legacyB) ==
                    .ambiguous(candidateRuntimeIDs: [30, 40]))
            }
        )
        #expect(swapped.resolve(legacyA) == .ambiguous(candidateRuntimeIDs: [30, 40]))
        #expect(swapped.resolve(legacyB) == .ambiguous(candidateRuntimeIDs: [30, 40]))
        #expect(DisplayReferenceMigrator.migrate(
            references: [legacyA, legacyB],
            using: swapped
        ).references == [legacyA, legacyB])
        #expect(swapped.resolve(aID) == .resolved(runtimeID: 30, canonicalReference: aID))
        #expect(swapped.resolve(bID) == .resolved(runtimeID: 40, canonicalReference: bID))
    }

    @Test("duplicate metadata-only serial evidence is ambiguous, not unavailable")
    func duplicateMetadataOnlySerialIsAmbiguous() {
        let legacy = "99999999-9999-4999-8999-999999999999-SN7"
        let snapshot = reconcileEveryPermutation(
            runtimes: [runtime(1, uuidA), runtime(2, uuidB)],
            metadata: [
                metadata("iokit", "duplicate-a", uuidA, serial: 7),
                metadata("iokit", "duplicate-b", uuidB, serial: 7)
            ],
            validate: { candidate in
                #expect(candidate.resolve(legacy) ==
                    .ambiguous(candidateRuntimeIDs: [1, 2]))
            }
        )
        #expect(snapshot.displays.allSatisfy { $0.resolution == .ambiguous })
        #expect(snapshot.registry.records.isEmpty)
        #expect(snapshot.resolve(legacy) == .ambiguous(candidateRuntimeIDs: [1, 2]))
        #expect(DisplayReferenceMigrator.migrate(
            references: [legacy],
            using: snapshot
        ).references == [legacy])
    }

    @Test("canonical identity syntax is closed and strictly validated")
    func malformedCanonicalLookingReferencesStayUnresolved() {
        let validSnapshot = DisplayReconciler.reconcile(
            runtimes: [runtime(20, uuidB, serial: 222)],
            metadata: []
        )
        let validCanonical = validSnapshot.display(runtimeID: 20)!.identity!.canonicalID
        #expect(validSnapshot.resolve(validCanonical) ==
            .resolved(runtimeID: 20, canonicalReference: validCanonical))
        #expect(validSnapshot.resolve("DockAnchorDisplay-V999M99-SN8") == .unavailable)

        let malformed = [
            "DockAnchorDisplay-garbage",
            "DockAnchorDisplay-",
            "DockAnchorDisplay-V100M10-extra",
            "DockAnchorDisplay-V100M10-SN0",
            "DockAnchorDisplay-V100M10-SN222-extra",
            "DockAnchorDisplay-V0100M10-SN222",
            "DockAnchorDisplay-V0M0",
            "DockAnchorDisplay-UUID-not-a-uuid-V100M10",
            "DockAnchorDisplay-UUID-\(uuidB.lowercased())-V100M10",
            "DockAnchorDisplay-UUID-\(uuidB)-V0M0",
            " DockAnchorDisplay-V100M10"
        ]
        let migration = DisplayReferenceMigrator.migrate(
            references: malformed,
            using: validSnapshot
        )
        #expect(migration.references == malformed)
        #expect(migration.migrations.isEmpty)
        for reference in malformed {
            #expect(validSnapshot.resolve(reference) == .unresolved)
        }

        let cleaned = DisplayIdentityRegistry(records: [
            DisplayIdentityRecord(
                canonicalID: "DockAnchorDisplay-garbage",
                vendorID: 100,
                productID: 10,
                uuidAliases: [uuidB]
            )
        ])
        #expect(cleaned.records.isEmpty)
    }

}
